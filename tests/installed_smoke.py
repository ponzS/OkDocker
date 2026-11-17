#!/usr/bin/env python3
"""Installed bundle + native UI/autostart version update, isolated app registry only.

Does not stop the runtime or alter SMAppService, user app policies or production files.
Captures only the fixture's own OkDocker views, not the desktop or phone screens.
"""
import hashlib, json, os, pathlib, plistlib, shutil, socket, subprocess, tempfile, time, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = pathlib.Path(os.environ.get('OKDOCKER_APP', '/Applications/OkDocker.app'))
BIN = APP/'Contents/MacOS/OkDocker'
OUT = ROOT/'artifacts/version-installed'; OUT.mkdir(parents=True, exist_ok=True)
BASE = pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/Installed'
BASE.mkdir(parents=True, exist_ok=True)
WORK = pathlib.Path(tempfile.mkdtemp(dir=BASE)); SUPPORT = WORK/'support'
ENV = dict(os.environ, OKDOCKER_SUPPORT=str(SUPPORT), OKDOCKER_RESOURCES=str(APP/'Contents/Resources'))
checks, records = [], []
report = dict(application=str(APP), work=str(WORK), checks=checks, actualAccountLoginTested=False, coldRuntimeTested=False)
gui = None

def run(args, env=None, timeout=120):
    p = subprocess.run(list(map(str,args)), capture_output=True, text=True, env=env, timeout=timeout)
    if p.returncode: raise AssertionError(p.stderr[-2500:]+p.stdout[-2500:])
    return p.stdout

def cli(*args): return run([BIN,'--cli',*args], env=ENV, timeout=180)
def check(name, value):
    if not value: raise AssertionError(name)
    checks.append(name); print('PASS',name,flush=True)
def ready(port):
    op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(80):
        try:
            with op.open(f'http://127.0.0.1:{port}/',timeout=2) as r: return r.read().decode()
        except Exception: time.sleep(.2)
    raise AssertionError('Installed fixture HTTP unavailable')
def user_registry():
    path=pathlib.Path.home()/'Library/Application Support/OkDocker/registry.json'
    return json.loads(path.read_text()) if path.exists() else None
def native_gui(tag):
    global gui
    out=OUT/tag; out.mkdir(exist_ok=True)
    for name in ['native-ui.json','feature-views.json']: (out/name).unlink(missing_ok=True)
    with (out/'ui.log').open('w') as log:
        gui=subprocess.Popen([str(BIN),'--ui-smoke-test',str(out),'--ui-feature-smoke'],env=ENV,stdout=log,stderr=log)
        gui.wait(timeout=180)
    assert gui.returncode==0
    state=json.loads((out/'native-ui.json').read_text())
    check(tag+': native window/menu/close/reopen',all(state[k] for k in ['windowVisible','menuBarPresent','ownWindowCaptured','closeKeepsMenuBar','reopenWorks']))
    check(tag+': own rules, app settings and live log view rendered',set(json.loads((out/'feature-views.json').read_text())['captured'])=={'rules','app-settings','startup-logs'})

before=user_registry(); login_before=cli('login-status').strip()
try:
    run(['/usr/bin/codesign','--verify','--deep','--strict',APP])
    metadata=plistlib.loads((APP/'Contents/Info.plist').read_bytes())
    check('installed version 0.3.2 and signature verified',metadata['CFBundleShortVersionString']=='0.3.2')
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    check('installed executable equals final packaged build',digest(BIN)==digest(ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'))
    check('installed bundled rules equal source and contain new fields',digest(APP/'Contents/Resources/CONFIGURATION.md')==digest(ROOT/'CONFIGURATION.md') and all(x in cli('rules') for x in ['build.script','version','shebang']))
    fixture=WORK/'fixture'; shutil.copytree(APP/'Contents/Resources/examples/scripted-web',fixture)
    with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    manifest=json.loads((fixture/'okdocker.json').read_text()); manifest['frontend']['hostPort']=manifest['backend']['hostPort']=port
    manifest['name']='Installed UI fixture'
    (fixture/'okdocker.json').write_text(json.dumps(manifest))
    record=json.loads(cli('import',fixture)); records.append(record)
    # Isolated policy only: never register/change the global system login item.
    registry=json.loads((SUPPORT/'registry.json').read_text());registry['apps'][0]['autoStart']=True
    (SUPPORT/'registry.json').write_text(json.dumps(registry));os.chmod(SUPPORT/'registry.json',0o600)
    native_gui('first-start')
    check('installed GUI starts the real scripted Linux application', 'Hello from a custom build script' in ready(port))
    first=next(x for x in json.loads(cli('deployments',record['id'])) if x['selected'])
    manifest['version']='1.0.1'; (fixture/'okdocker.json').write_text(json.dumps(manifest))
    (fixture/'public/index.html').write_text('<h1>INSTALLED-UI-UPDATED</h1>')
    native_gui('version-update')
    second=next(x for x in json.loads(cli('deployments',record['id'])) if x['selected'])
    check('installed GUI checks new version even when the old service is running',ready(port)=='<h1>INSTALLED-UI-UPDATED</h1>' and second['id']!=first['id'] and second['version']=='1.0.1')
    check('GUI exit preserves new application service',json.loads(cli('status',record['id']))['running']==1)
    check('user application registry and permissions unchanged',user_registry()==before)
    check('global login preference unchanged',cli('login-status').strip()==login_before)
    report['passed']=True
finally:
    if gui is not None and gui.poll() is None:
        gui.terminate(); gui.wait(timeout=15)
    errors=[]
    for r in records:
        try: cli('autostart',r['id'],'off');cli('close',r['id'],'--force');cli('forget',r['id'])
        except Exception as e: errors.append(str(e))
    report['cleanupErrors']=errors
    (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(dict(passed=report.get('passed',False),checks=len(checks),cleanupErrors=errors),ensure_ascii=False),flush=True)
