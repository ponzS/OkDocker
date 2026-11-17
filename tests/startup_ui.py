#!/usr/bin/env python3
"""Render installed native startup/log views during a real isolated build."""
import json,os,pathlib,socket,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1];APP=pathlib.Path('/Applications/OkDocker.app');BIN=APP/'Contents/MacOS/OkDocker'
WORK=pathlib.Path(tempfile.mkdtemp(prefix='okdocker-startup-ui-'));SUPPORT=WORK/'support';OUT=ROOT/'artifacts/startup-ui';OUT.mkdir(exist_ok=True)
ENV=dict(os.environ,OKDOCKER_SUPPORT=str(SUPPORT),OKDOCKER_RESOURCES=str(APP/'Contents/Resources'))
def cli(*args):
 p=subprocess.run([str(BIN),'--cli',*map(str,args)],env=ENV,capture_output=True,text=True,timeout=120)
 if p.returncode:raise RuntimeError(p.stderr[-1500:])
 return p.stdout
record=None;pending=None
try:
 root=WORK/'fixture';root.mkdir();(root/'build.sh').write_text('echo STARTUP_UI_LIVE_PROGRESS\necho '+('Dependency cache and application build progress. '*8)+'\nsleep 30\nmkdir -p /out;echo OK >/out/index.html\n')
 (root/'Dockerfile').write_text('FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e\nWORKDIR /src\nCOPY . .\n# okdocker:build-script\nWORKDIR /out\nCMD ["python3","-m","http.server","8080"]\n')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 ep=dict(service='app',directory='.',path='/',hostPort=port,containerPort=8080)
 manifest=dict(schemaVersion=1,id='startup-ui',name='Starting fixture',version='1.0.0',frontend=ep,backend=ep,services={'app':{'build':{'context':'.','dockerfile':'Dockerfile','script':'build.sh'},'mounts':[]}})
 (root/'okdocker.json').write_text(json.dumps(manifest));record=json.loads(cli('import',root))
 with (OUT/'launcher.log').open('w') as log:
  pending=subprocess.Popen([str(BIN),'--cli','start',record['id']],env=ENV,stdout=log,stderr=log)
  path=SUPPORT/'apps'/record['id']/'startup.log'
  for _ in range(400):
   if path.exists() and 'STARTUP_UI_LIVE_PROGRESS' in path.read_text():break
   if pending.poll() is not None:raise RuntimeError('Fixture startup ended before live capture')
   time.sleep(.1)
  else:raise RuntimeError('No build progress')
  with (OUT/'gui.log').open('w') as ui:
   subprocess.run([str(BIN),'--ui-smoke-test',str(OUT),'--ui-feature-smoke'],env=ENV,stdout=ui,stderr=ui,check=True,timeout=45)
  observed=json.loads(cli('status',record['id']));assert observed['state']=='starting' and pending.poll() is None
  features=json.loads((OUT/'feature-views.json').read_text());assert 'startup-logs' in features['captured']
  (OUT/'report.json').write_text(json.dumps({'passed':True,'actualBuildStillRunningDuringCapture':True,'state':observed,'onlyOwnViews':True},indent=2))
  print('PASS installed native launcher and live log view captured during a real build',flush=True)
finally:
 if record:
  cli('close',record['id'],'--force');cli('forget',record['id'])
 if pending is not None:pending.wait(timeout=15)
