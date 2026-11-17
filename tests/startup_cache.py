#!/usr/bin/env python3
"""Real Linux build cache, cross-process startup status and live log checks.
Isolated registry/fixtures; no phones, LAN permissions or production requests.
"""
import json,os,pathlib,socket,subprocess,tempfile,time,urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=pathlib.Path(os.environ.get('OKDOCKER_BIN',ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'))
BASE=pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/StartupCache';BASE.mkdir(parents=True,exist_ok=True)
WORK=pathlib.Path(tempfile.mkdtemp(dir=BASE));SUPPORT=WORK/'support';ENV=dict(os.environ,OKDOCKER_SUPPORT=str(SUPPORT))
OUT=ROOT/'artifacts/startup-cache';OUT.mkdir(parents=True,exist_ok=True)
checks=[];record=None;pending=None

def cli(*args,check=True):
 p=subprocess.run([str(BIN),'--cli',*map(str,args)],capture_output=True,text=True,env=ENV,timeout=180)
 if check and p.returncode:raise AssertionError(p.stderr[-2000:])
 return p

def check(name,value):
 assert value,name;checks.append(name);print('PASS',name,flush=True)

def read(port,path):
 c=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 for _ in range(80):
  try:return c.open(f'http://127.0.0.1:{port}/{path}',timeout=2).read().decode()
  except OSError:time.sleep(.2)
 raise AssertionError('Fixture not reachable')

def start_and_observe():
 global pending
 pending=subprocess.Popen([str(BIN),'--cli','start',record['id']],env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 log=SUPPORT/'apps'/record['id']/'startup.log'
 live=False;state=None
 for _ in range(600):
  if pending.poll() is not None:break
  text=log.read_text(errors='replace') if log.exists() else ''
  phase=SUPPORT/'apps'/record['id']/'startup-phase.json'
  current=json.loads(phase.read_text()).get('pid') if phase.exists() else None
  if current==pending.pid and 'BUILD_LIVE_OUTPUT' in text:
   state=json.loads(cli('status',record['id']).stdout)
   live=pending.poll() is None;break
  time.sleep(.1)
 check('build output visible before command completion',live)
 check('another CLI sees startup while containers may be stopped',state and state['state']=='starting' and state.get('healthy') is None)
 output,error=pending.communicate(timeout=180);assert pending.returncode==0,error[-2000:]
 check('startup log is private',log.stat().st_mode&0o777==0o600)
 return log.read_text(errors='replace')

report={'work':str(WORK),'checks':checks}
try:
 root=WORK/'app';root.mkdir();(root/'source.txt').write_text('SOURCE_ONE')
 (root/'build.sh').write_text('# fixture '+WORK.name+'\nset -eu\necho BUILD_LIVE_OUTPUT\nsleep 4\nmkdir -p /out\ncp source.txt /out/index.html\ncp /dependency-id /out/dependency-id\npython3 -c "import uuid;print(uuid.uuid4())" > /out/build-id\n')
 (root/'Dockerfile').write_text('FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e\nRUN python3 -c "import uuid;print(uuid.uuid4())" > /dependency-id\nWORKDIR /src\nCOPY . .\n# okdocker:build-script\nWORKDIR /out\nCMD ["python3","-m","http.server","8080","--bind","0.0.0.0"]\n')
 (root/'Dockerfile.dockerignore').write_text('okdocker.json\n')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 ep={'service':'app','directory':'.','path':'/','hostPort':port,'containerPort':8080}
 manifest={'schemaVersion':1,'id':'startup-cache','name':'Startup cache fixture','version':'1.0.0','frontend':ep,'backend':ep,'services':{'app':{'build':{'context':'.','dockerfile':'Dockerfile','script':'build.sh'},'mounts':[]}}}
 (root/'okdocker.json').write_text(json.dumps(manifest));record=json.loads(cli('import',root).stdout)
 start_and_observe();first_dep=read(port,'dependency-id');first_build=read(port,'build-id');assert read(port,'')=='SOURCE_ONE'
 (root/'source.txt').write_text('SOURCE_TWO');manifest['version']='1.0.1';(root/'okdocker.json').write_text(json.dumps(manifest))
 log=start_and_observe();second_build=read(port,'build-id')
 check('source update produces new application output',read(port,'')=='SOURCE_TWO' and second_build!=first_build)
 check('dependency build reused across source update',read(port,'dependency-id')==first_dep and 'CACHED' in log)
 manifest['version']='1.0.2';(root/'okdocker.json').write_text(json.dumps(manifest));start_and_observe()
 check('version-only update reruns build script with dependency cache intact',read(port,'build-id')!=second_build and read(port,'dependency-id')==first_dep)
 before=read(port,'build-id');manifest['version']='1.0.3';(root/'okdocker.json').write_text(json.dumps(manifest));(root/'build.sh').write_text('echo BUILD_FAILED_OUTPUT;exit 37\n')
 result=cli('start',record['id'],check=False)
 log=SUPPORT/'apps'/record['id']/'startup.log'
 check('failed build preserves streamed diagnostics and old service',result.returncode!=0 and 'BUILD_FAILED_OUTPUT' in log.read_text() and read(port,'build-id')==before)
 check('released start lock cannot leave a stale starting state',json.loads(cli('status',record['id']).stdout)['state']!='starting')
 report['passed']=True
finally:
 if pending is not None and pending.poll() is None:pending.terminate();pending.wait(timeout=10)
 if record:
  cli('close',record['id'],'--force',check=False);cli('forget',record['id'],check=False)
 (OUT/'report.json').write_text(json.dumps(report,indent=2))
