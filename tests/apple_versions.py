#!/usr/bin/env python3
"""Real version/script deployment tests; isolated roots, no production mounts or jobs."""
import json, os, pathlib, socket, subprocess, tempfile, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('OKDOCKER_BIN', ROOT / 'dist/OkDocker.app/Contents/MacOS/OkDocker'))
BASE = pathlib.Path.home() / 'Library/Application Support/OkDocker/Validation/Versions'
BASE.mkdir(parents=True, exist_ok=True)
WORK = pathlib.Path(tempfile.mkdtemp(dir=BASE)); SUPPORT = WORK / 'support'
ENV = dict(os.environ, OKDOCKER_SUPPORT=str(SUPPORT), OKDOCKER_RESOURCES=os.environ.get('OKDOCKER_RESOURCES', str(ROOT / 'Resources')))
C = '/usr/local/bin/container'
IMAGE = 'python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
records, checks = [], []
report = {'runtime': 'Apple container 1.7.1', 'binary': str(BIN), 'resources': ENV['OKDOCKER_RESOURCES'], 'work': str(WORK), 'checks': checks}

def run(args, ok=True, timeout=180, env=None):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True, env=env, timeout=timeout)
    if ok and p.returncode: raise AssertionError(f'{args[:3]}: {p.stdout[-1500:]} {p.stderr[-3500:]}')
    return p

def cli(*args, **kw): return run([BIN, '--cli', *args], env=ENV, **kw)
def c(*args): return run([C, *args]).stdout
def check(name, truth):
    if not truth: raise AssertionError(name)
    checks.append(name); print('PASS', name, flush=True)
def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
def save(root, manifest): (root / 'okdocker.json').write_text(json.dumps(manifest))
def deployments(r): return json.loads(cli('deployments', r['id']).stdout)
def active(r): return next(x for x in deployments(r) if x['selected'])
def inspect(name): return json.loads(c('inspect', name))[0]
def ready(port, path='/'):
    for _ in range(90):
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=2) as r: return r.read().decode()
        except Exception: time.sleep(.2)
    raise AssertionError('HTTP unavailable')
def payload(port): return json.loads(ready(port, '/build.json'))
def fixture(name, android=False):
    root = WORK / name; root.mkdir(); (root/'data').mkdir()
    (root/'source.txt').write_text(name + '-v1')
    (root/'build.sh').write_text('''set -eu
# This must execute in Linux, never on the Mac. File exclusions must remain intact.
test "$(uname -s)" = Linux
test ! -e do-not-package.txt
mkdir -p dist
cp source.txt dist/index.html
python3 -c 'import json,platform,uuid; print(json.dumps({"build":str(uuid.uuid4()),"system":platform.system()}))' > dist/build.json
''')
    if name == 'version-b':
        (root/'build.sh').write_text('''#!/usr/bin/env python3
import json,pathlib,platform,uuid
assert platform.system() == 'Linux'
assert not pathlib.Path('do-not-package.txt').exists()
pathlib.Path('dist').mkdir(exist_ok=True)
pathlib.Path('dist/index.html').write_text(pathlib.Path('source.txt').read_text())
pathlib.Path('dist/build.json').write_text(json.dumps({'build':str(uuid.uuid4()),'system':platform.system()}))
''')
    (root/'Dockerfile').write_text(f'''FROM {IMAGE} AS build
WORKDIR /src
COPY . .
# okdocker:build-script
FROM {IMAGE}
COPY --from=build /src/dist /app
WORKDIR /app
CMD ["python3","-m","http.server","8080","--bind","0.0.0.0"]
''')
    (root/'do-not-package.txt').write_text('PUBLIC TEST MARKER, NOT A SECRET')
    (root/'Dockerfile.dockerignore').write_text('do-not-package.txt\ndata\nokdocker.json\n')
    (root/'.dockerignore').write_text('# Specific Dockerfile ignore takes precedence\n')
    port = free_port()
    ep = dict(service='app', directory='.', path='/', hostPort=port, containerPort=8080)
    m = dict(schemaVersion=1, version='1.0.0', id=name, name=name, frontend=ep, backend=ep,
             hostAndroidDevices=android, services={'app': {'build': {'context': '.', 'dockerfile': 'Dockerfile', 'script': 'build.sh'}, 'mounts': [{'source':'data','target':'/data'}]}})
    save(root,m); r = json.loads(cli('import',root).stdout); records.append(r)
    return root,m,r,port

def adb_probe(name):
    text = c('exec', name, 'python3', '-c', 'import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect("/run/okdocker-adb.sock"); s.sendall(b"000chost:version"); print(s.recv(4).decode())')
    return text.strip() == 'OKAY'

try:
    before = json.loads(c('list','--all','--format','json'))
    root,m,a,p = fixture('version-a', android=True)
    _,_,b,pb = fixture('version-b')
    cli('start',a['id'],timeout=600); cli('start',b['id'],timeout=600)
    first = active(a); first_object = inspect(first['id']); first_build = payload(p)
    check('Python shebang runs with its declared interpreter', payload(pb)['system']=='Linux' and ready(pb)=='version-b-v1')
    check('custom build script actually runs in Linux and packages source', ready(p)=='version-a-v1' and first_build['system']=='Linux')
    check('Dockerfile-specific ignore retained with generated recipe', not run([C,'exec',first['id'],'test','-e','/app/do-not-package.txt'],ok=False).returncode == 0)
    check('source Dockerfile unchanged and script not run on Mac', '# okdocker:build-script' in (root/'Dockerfile').read_text() and not (root/'dist').exists())
    check('shared ADB transport works before release switch', adb_probe(first['id']))
    c('exec',first['id'],'sh','-c','printf mounted-data > /data/keep; printf layer-data > /root/keep')
    cli('start',a['id']); check('same running version does not rebuild', active(a)['id']==first['id'] and payload(p)==first_build)
    cli('close',a['id'],'--force'); cli('start',a['id'])
    check('same version restart preserves image and writable layer', active(a)['id']==first['id'] and payload(p)==first_build and 'layer-data' in c('exec',first['id'],'cat','/root/keep'))
    cli('lan',a['id'],'on')
    lan = json.loads(cli('lan',a['id'],'status').stdout)
    check('isolated application explicitly enables private LAN gateway', lan['enabled'] and bool(lan['addresses']))
    (root/'source.txt').write_text('version-a-v2'); m['version']='2.0.0'; save(root,m)
    cli('start',a['id'],timeout=600); second = active(a); second_build = payload(p)
    check('changed version builds and deploys fresh source without reimport', ready(p)=='version-a-v2' and second['id']!=first['id'] and second_build!=first_build)
    check('new deployment uses a distinct image reference', inspect(second['id'])['configuration']['image']!=first_object['configuration']['image'])
    check('previous container retained stopped with original creation date', inspect(first['id'])['status']['state']=='stopped' and inspect(first['id'])['configuration']['creationDate']==first_object['configuration']['creationDate'])
    check('new container does not reuse previous writable layer', run([C,'exec',second['id'],'test','-e','/root/keep'],ok=False).returncode!=0)
    check('mounted data survives version switch', (root/'data/keep').read_text()=='mounted-data' and 'mounted-data' in c('exec',second['id'],'cat','/data/keep'))
    check('other application unaffected by version switch', ready(pb)=='version-b-v1')
    lan = json.loads(cli('lan',a['id'],'status').stdout)
    with urllib.request.urlopen(f'http://{lan["addresses"][0]}:{p}/',timeout=5) as r:
        check('authorized LAN gateway follows the new container publisher', r.read().decode()=='version-a-v2')
    ports=inspect(second['id'])['configuration'].get('publishedPorts') or []
    check('ADB transport restored without exposing an ADB TCP port', adb_probe(second['id']) and all(p.get('containerPort')!=5037 for p in ports))
    # Manifest is excluded from context. Only its version changes: a new UUID proves RUN is not cached.
    m['version']='2.0.1'; save(root,m); cli('start',a['id'],timeout=600); third = active(a); third_build=payload(p)
    check('version-only update bypasses build cache', third_build!=second_build and third['id']!=second['id'])
    c('kill','--signal','KILL',third['id']); cli('start',a['id'])
    check('partially stopped selected generation resumes without rebuilding', active(a)['id']==third['id'] and payload(p)==third_build)
    # A failing script cannot take the currently running version down or change selection.
    script=(root/'build.sh').read_text(); (root/'build.sh').write_text('exit 37\n'); m['version']='3.0.0'; save(root,m)
    failed=cli('start',a['id'],ok=False,timeout=600)
    check('failed custom build keeps old deployment serving', failed.returncode!=0 and active(a)['id']==third['id'] and payload(p)==third_build)
    (root/'build.sh').write_text('sleep 4\n' + script); m['version']='4.0.0'; save(root,m)
    updating = subprocess.Popen([str(BIN),'--cli','start',a['id']],env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    time.sleep(2); m['version']='4.0.1'; save(root,m)
    updating.communicate(timeout=600)
    check('version edited during build aborts before stopping current deployment', updating.returncode!=0 and active(a)['id']==third['id'] and payload(p)==third_build)
    (root/'build.sh').write_text(script)
    # A version bump must not authorize new ports or paths.
    m['frontend']['hostPort']=m['backend']['hostPort']=free_port(); save(root,m)
    denied=cli('start',a['id'],ok=False)
    check('version bump cannot bypass port approval', denied.returncode!=0 and active(a)['id']==third['id'] and payload(p)==third_build)
    m['frontend']['hostPort']=m['backend']['hostPort']=p; m['version']='2.0.1'; save(root,m)
    # Start a retained layer only while current is stopped, proving the old data is recoverable.
    cli('close',a['id'],'--force'); cli('start',a['id']); ready(p)
    # Restore the shared socket infrastructure, then stop only the selected service.
    cli('lan',a['id'],'off')
    c('kill','--signal','KILL',third['id']); c('start',first['id'])
    check('retained old writable layer remains recoverable', ready(p)=='version-a-v1' and 'layer-data' in c('exec',first['id'],'cat','/root/keep'))
    cli('close',a['id'],'--force')
    check('force close includes retained generations, not just selected', inspect(first['id'])['status']['state']=='stopped')
    cli('start',a['id']); ready(p)
    check('restart selects latest deployment, not archive', active(a)['id']==third['id'] and payload(p)==third_build and json.loads(cli('status',a['id']).stdout)['containers']==2)
    # Downgrade is also a version difference, not an excuse to reuse a previous image.
    m['version']='1.0.0'; save(root,m); cli('start',a['id'],timeout=600)
    check('version downgrade creates another fresh deployment', active(a)['id'] not in [first['id'],second['id'],third['id']] and payload(p)!=first_build)
    (root/'Dockerfile.dockerignore').unlink(); (root/'.dockerignore').write_text('do-not-package.txt\ndata\nokdocker.json\n')
    m['version']='1.0.1'; save(root,m); cli('start',a['id'],timeout=600)
    check('context .dockerignore still applies without a specific ignore file', ready(p)=='version-a-v2')
    check('archive metadata is private', all(x.stat().st_mode & 0o777 == 0o600 for x in (SUPPORT/'apps'/a['id']/'deployments').glob('*.json')))
    # Legacy registration gains a baseline only when the original seal still matches.
    reg=json.loads((SUPPORT/'registry.json').read_text()); legacy=next(x for x in reg['apps'] if x['id']==b['id']); legacy.pop('approvalHash'); legacy.pop('manifestVersion')
    (SUPPORT/'registry.json').write_text(json.dumps(reg)); cli('start',b['id'])
    check('matching old registration safely seeds authorization baseline', next(x for x in json.loads(cli('list').stdout) if x['id']==b['id'])['approvalHash'])
    own = {x['id'] for x in records}
    untouched = [x for x in json.loads(c('list','--all','--format','json')) if x['configuration']['labels'].get('dev.okdocker.app') not in own]
    summary = lambda objects: {x['configuration']['id']: x['status']['state'] for x in objects}
    check('unrelated container identities and observed states unchanged', summary(before)==summary(untouched))
    report['passed']=True
finally:
    errors=[]
    for r in records:
        try:
            cli('close',r['id'],'--force',timeout=60); cli('forget',r['id'],timeout=90)
            check('remove cleans all generations: '+r['name'], not any(x['configuration']['labels'].get('dev.okdocker.app')==r['id'] for x in json.loads(c('list','--all','--format','json'))))
        except Exception as e: errors.append(str(e))
    report['cleanupErrors']=errors
    target=ROOT/'artifacts/version-validation/report.json'; target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(dict(passed=report.get('passed',False), checks=len(checks), cleanupErrors=errors),ensure_ascii=False),flush=True)
