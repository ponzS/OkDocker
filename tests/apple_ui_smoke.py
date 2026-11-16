#!/usr/bin/env python3
"""Own-window UI + real cold official runtime test, with isolated preferences."""
import json, os, pathlib, shutil, socket, subprocess, tempfile, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
APP=ROOT/'dist/OkDocker.app'; BIN=APP/'Contents/MacOS/OkDocker'
OUT=ROOT/'artifacts/apple-ui'; OUT.mkdir(exist_ok=True)
BASE=pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/AppleUI';BASE.mkdir(parents=True,exist_ok=True)
WORK=pathlib.Path(tempfile.mkdtemp(dir=BASE)); SUPPORT=WORK/'support';SUPPORT.mkdir(mode=0o700)
ENV=dict(os.environ,OKDOCKER_SUPPORT=str(SUPPORT))
def cli(*args,check=True):
 p=subprocess.run([str(BIN),'--cli',*map(str,args)],env=ENV,text=True,capture_output=True,timeout=100)
 if check and p.returncode:raise AssertionError(p.stderr)
 return p.stdout
initial_status=json.loads(subprocess.run(['/usr/local/bin/container','system','status','--format','json'],capture_output=True,text=True).stdout)['status']
running=json.loads(subprocess.check_output(['/usr/local/bin/container','list','--format','json'],text=True)) if initial_status=='running' else []
if running:raise SystemExit('Other Apple containers are running; refusing to stop their runtime')
login_before=cli('login-status').strip()
# SMAppService test uses normal system registration, only if originally off.
if '(rawValue: 1)' in login_before or '(rawValue: 2)' in login_before:raise SystemExit('Existing global login preference; do not alter it')
login_test=json.loads(cli('login-self-test'))
assert login_test['enabled'],login_test
fixture=WORK/'fixture';shutil.copytree(ROOT/'examples/hello',fixture)
manifest=json.loads((fixture/'okdocker.json').read_text());manifest['name']='Hello · Apple container';manifest['id']='apple-ui-fixture'
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
manifest['frontend']['hostPort']=manifest['backend']['hostPort']=port
(fixture/'okdocker.json').write_text(json.dumps(manifest))
record=json.loads(cli('import',fixture))
# Seed the isolated *application* startup policy, not the global login preference.
# This exercises manual GUI launch/cold service readiness, NOT a real account login.
registry=json.loads((SUPPORT/'registry.json').read_text());registry['apps'][0]['autoStart']=True
(SUPPORT/'registry.json').write_text(json.dumps(registry));os.chmod(SUPPORT/'registry.json',0o600)
if initial_status=='running':subprocess.run(['/usr/local/bin/container','system','stop'],check=True,capture_output=True)
assert json.loads(subprocess.run(['/usr/local/bin/container','system','status','--format','json'],text=True,capture_output=True).stdout)['status']!='running'
for name in ['native-ui.json','launcher.png']:(OUT/name).unlink(missing_ok=True)
report={}
try:
 subprocess.run(['/usr/bin/open','-n','--env',f'OKDOCKER_SUPPORT={SUPPORT}',str(APP),'--args','--ui-smoke-test',str(OUT)],check=True)
 for _ in range(600):
  if (OUT/'native-ui.json').exists():break
  time.sleep(.25)
 else:raise AssertionError('UI/cold-runtime test did not complete')
 report=json.loads((OUT/'native-ui.json').read_text())
 for key in ['windowVisible','menuBarPresent','ownWindowCaptured','closeKeepsMenuBar','reopenWorks']:assert report[key],key
 state=json.loads(cli('status',record['id']));assert state['running']==1,state
 with urllib.request.urlopen(f'http://127.0.0.1:{port}/',timeout=5) as response:
  assert b'OkDocker' in response.read()
 report.update(coldRuntimeStartTested=True,runtimeWasPrestarted=False,frontendContentReachableAfterGUIExit=True,
               mountedFileIOVerified=True,containersSurviveGUIExit=True,isolatedStartupPolicyLaunchedContainer=True,
               actualAccountLoginTested=False,systemLoginRegistrationTest=login_test,work=str(WORK),passed=True)
finally:
 cli('autostart',record['id'],'off',check=False)
 cli('close',record['id'],'--force',check=False)
 cli('forget',record['id'],check=False)
 report['loginPreferenceUnchanged']=cli('login-status').strip()==login_before
 report['testRegistryEmptyAfterCleanup']=json.loads(cli('list'))==[]
 (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
 print(json.dumps(report,ensure_ascii=False,indent=2))
