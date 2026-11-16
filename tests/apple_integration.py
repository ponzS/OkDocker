#!/usr/bin/env python3
"""Real Apple container tests. Isolated roots; never imports/starts production."""
import json, os, pathlib, socket, subprocess, tempfile, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('OKDOCKER_BIN', ROOT / '.build/debug/OkDocker'))
CONTAINER = '/usr/local/bin/container'
BASE = pathlib.Path.home() / 'Library/Application Support/OkDocker/Validation/Apple'
BASE.mkdir(parents=True, exist_ok=True)
WORK = pathlib.Path(tempfile.mkdtemp(prefix='run-', dir=BASE))
SUPPORT = WORK / 'support'
ENV = dict(os.environ, OKDOCKER_SUPPORT=str(SUPPORT), OKDOCKER_RESOURCES=str(ROOT / 'Resources'),
           DOCKER_HOST='tcp://127.0.0.1:1', DOCKER_CONTEXT='not-an-engine',
           CONTAINER_APP_ROOT='/nonexistent-untrusted-container-root', CONTAINER_DEFAULT_PLATFORM='linux/amd64')
checks = []
records = []

def run(args, *, ok=True, timeout=120, env=None):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True, env=env, timeout=timeout)
    if ok and p.returncode:
        raise AssertionError(f'{args[:3]} failed ({p.returncode}): {p.stdout[-2500:]} {p.stderr[-2500:]}')
    return p

def cli(*args, ok=True, timeout=120):
    return run([BIN, '--cli', *args], ok=ok, timeout=timeout, env=ENV)

def check(name, truth):
    if not truth: raise AssertionError(name)
    checks.append(name)
    print('PASS', name, flush=True)

def c(*args):
    return run([CONTAINER, *args]).stdout

def inspect(record):
    return json.loads(c('inspect', record['project'] + '-app'))[0]

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def http(p, path='/'):
    with urllib.request.urlopen(f'http://127.0.0.1:{p}{path}', timeout=3) as r: return r.read().decode()

def ready(p):
    last = None
    for _ in range(80):
        try: return http(p)
        except Exception as e: last = e; time.sleep(.2)
    raise AssertionError(f'HTTP never became ready: {last}')

def fixture(name, p):
    root = WORK / name
    root.mkdir()
    (root / 'index.html').write_text('APPLE ' + name)
    (root / 'server.py').write_text('''import http.server,os,signal
signal.signal(signal.SIGTERM,signal.SIG_IGN)
class H(http.server.SimpleHTTPRequestHandler):
 def do_GET(self):
  if self.path=='/env':
   self.send_response(200);self.end_headers();self.wfile.write(os.environ['LITERAL'].encode());return
  super().do_GET()
http.server.HTTPServer(('0.0.0.0',8080),H).serve_forever()
''')
    m = {'schemaVersion': 1, 'id': name, 'name': name, 'autoStart': True, 'hostAndroidDevices': False,
         'frontend': {'service': 'app', 'directory': '.', 'path': '/', 'hostPort': p, 'containerPort': 8080},
         'backend': {'service': 'app', 'directory': '.', 'path': '/index.html', 'hostPort': p, 'containerPort': 8080},
         'services': {'app': {'image': 'python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e',
                              'command': ['python3', '/workspace/server.py'], 'workingDirectory': '/workspace',
                              'environment': {'LITERAL': '${HOME}; $(touch BAD) $SECRET'}}}}
    (root / 'okdocker.json').write_text(json.dumps(m))
    (root / '.env').write_text('COMPOSE_FILE=/Users/SHOULD-NOT-READ\nCONTAINER_DEFAULT_PLATFORM=linux/amd64\n')
    r = json.loads(cli('import', root).stdout); records.append(r)
    return root, m, r

report = {'runtime': 'Apple container 1.7.1', 'work': str(WORK), 'checks': checks}
try:
    check('official engine and untrusted endpoint variables ignored', cli('engine').stdout.strip() == '1.7.1')
    p1, p2 = port(), port()
    root1, m1, a = fixture('apple-one', p1)
    root2, m2, b = fixture('apple-two', p2)
    check('import defaults to Apple without Docker context', a['context'] == b['context'] == 'apple-container')
    check('manifest cannot enable startup', not a['autoStart'] and not b['autoStart'])
    cli('start', a['id'], timeout=240)
    check('actual mounted frontend content', 'APPLE apple-one' in ready(p1))
    cli('start', b['id'], timeout=240)
    check('second independent app frontend', 'APPLE apple-two' in ready(p2))
    actual = inspect(a); conf = actual['configuration']
    check('native Linux arm64, no Rosetta', conf['platform']['architecture'] == 'arm64' and not conf['rosetta'] and 'aarch64' in c('exec', a['project']+'-app','uname','-m'))
    check('one approved application mount only', len(conf['mounts']) == 1 and conf['mounts'][0]['source'] == str(root1))
    check('loopback-only actual published ports', all(x['hostAddress'] == '127.0.0.1' for x in conf['publishedPorts']))
    check('literal environment and malicious .env immunity', http(p1, '/env') == '${HOME}; $(touch BAD) $SECRET' and not (root1/'BAD').exists())
    check('private per-app network', conf['networks'][0]['network'] == a['project'] and inspect(b)['configuration']['networks'][0]['network'] == b['project'])
    check('no host SSH socket or hardware/virtualization forwarding', not conf['ssh'] and not conf['virtualization'] and not conf['publishedSockets'])
    check('Android off injects no transport', not any(e.startswith('ADB_SERVER_SOCKET=') for e in conf['initProcess']['environment']))
    outside = WORK / 'outside-marker'; outside.write_text('NOT AUTHORIZED')
    check('outside file and Docker socket absent in guest', run([CONTAINER,'exec',a['project']+'-app','sh','-c',f'test ! -e "{outside}" && test ! -e /var/run/docker.sock']).returncode == 0)
    c('exec', a['project']+'-app', 'sh', '-c', 'printf retained > /workspace/data.txt; printf root-retained > /root/retained.txt')
    check('real guest writes reach host', (root1/'data.txt').read_text() == 'retained')
    c('kill', '--signal', 'TERM', a['project']+'-app'); time.sleep(.3)
    check('fixture truly ignores graceful TERM', 'APPLE apple-one' in http(p1))
    t = time.monotonic(); cli('close', a['id'], '--force')
    check('force stop actual stopped state', json.loads(cli('status',a['id']).stdout)['running'] == 0)
    check('force stop bounded, not graceful indefinite wait', time.monotonic()-t < 15)
    check('unrelated project remains available', 'APPLE apple-two' in http(p2))
    check('force stop retains mounted data', (root1/'data.txt').read_text() == 'retained')
    old_creation = actual['configuration']['creationDate']
    cli('start', a['id']); ready(p1)
    check('restart reuses container writable layer', 'root-retained' in c('exec',a['project']+'-app','cat','/root/retained.txt') and inspect(a)['configuration']['creationDate'] == old_creation)
    check('restart retains mounted data', http(p1,'/data.txt') == 'retained')
    m1['hostAndroidDevices'] = True; (root1/'okdocker.json').write_text(json.dumps(m1))
    check('unapproved permission change rejected', cli('start',a['id'],ok=False).returncode != 0)
    cli('close',a['id'],'--force')
    check('changed manifest can still be force-stopped', json.loads(cli('status',a['id']).stdout)['running']==0)
    m1['hostAndroidDevices'] = False; (root1/'okdocker.json').write_text(json.dumps(m1))
    # Config change must never silently wipe the root filesystem.
    m1['name'] = 'renamed'; (root1/'okdocker.json').write_text(json.dumps(m1)); cli('import',root1)
    check('changed approved config refuses silent writable-layer deletion', cli('start',a['id'],ok=False).returncode != 0 and inspect(a)['configuration']['creationDate'] == old_creation)
    # A wildcard listener must block BEFORE any application container is created.
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('0.0.0.0',0));listener.listen()
        _, _, w = fixture('apple-wildcard', listener.getsockname()[1])
        check('wildcard port occupied fails start', cli('start',w['id'],ok=False).returncode != 0)
        all_ids = [i['configuration']['id'] for i in json.loads(c('list','--all','--format','json'))]
        check('occupied port creates no app containers', not any(i.startswith(w['project']+'-') for i in all_ids))
    # Legacy migration is explicit and registration-only even with absent context.
    registry = json.loads((SUPPORT/'registry.json').read_text())
    old = dict(w, context='okdocker-test-missing-context', autoStart=True)
    registry['apps'][-1] = old; registry['context'] = old['context'];registry['schemaVersion']=1
    (SUPPORT/'registry.json').write_text(json.dumps(registry))
    listed = json.loads(cli('list').stdout)
    check('one-time default migration backed up', (SUPPORT/'registry-before-apple.json').exists() and json.loads((SUPPORT/'registry.json').read_text())['context']=='apple-container')
    check('legacy backend retained and startup paused', listed[-1]['context']==old['context'] and not listed[-1]['autoStart'])
    check('legacy migration requires explicit confirmation', cli('migrate',w['id'],ok=False).returncode != 0)
    cli('migrate',w['id'],'--confirm-old-stopped')
    check('explicit migration changes registration only', json.loads(cli('list').stdout)[-1]['context']=='apple-container' and json.loads(cli('status',w['id']).stdout)['containers']==0)
    report['passed']=True
finally:
    errors=[]
    for r in records:
        try:
            # All test records now use Apple; this never addresses a production ID.
            cli('close',r['id'],'--force',timeout=45)
            cli('forget',r['id'],timeout=45)
        except Exception as e: errors.append(str(e))
    report['cleanupErrors']=errors
    target=ROOT/'artifacts/apple-validation/report.json';target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps({'passed':report.get('passed',False),'checks':len(checks),'cleanupErrors':errors},ensure_ascii=False),flush=True)
