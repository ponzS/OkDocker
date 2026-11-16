#!/usr/bin/env python3
"""Cancel real pending builds and orphan CLI clients, never the shared builder."""
import json, os, pathlib, socket, subprocess, tempfile, time, hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=pathlib.Path(os.environ.get('OKDOCKER_BIN',ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'))
BASE=pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/AppleCancellation';BASE.mkdir(parents=True,exist_ok=True)
WORK=pathlib.Path(tempfile.mkdtemp(dir=BASE));SUPPORT=WORK/'support';ENV=dict(os.environ,OKDOCKER_SUPPORT=str(SUPPORT));records=[];checks=[];launchers=[]
def cli(*args,check=True):
 p=subprocess.run([str(BIN),'--cli',*map(str,args)],env=ENV,text=True,capture_output=True,timeout=70)
 if check and p.returncode:raise AssertionError(p.stderr)
 return p

def check(name,value):
 assert value,name
 checks.append(name);print('PASS',name,flush=True)

def clients(r):
 p=subprocess.run(['/bin/ps','-axo','pid=,command='],capture_output=True,text=True,check=True)
 marker='--tag okdocker.local/'+r['project']+'/'
 return [int(s.strip().split(None,1)[0]) for s in p.stdout.splitlines() if marker in s and ('/usr/local/bin/container build ' in s or '/container/plugins/build/bin/build ' in s)]

def fixture(name):
 root=WORK/name;root.mkdir()
 (root/'Dockerfile').write_text('FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e\nRUN sleep 45; echo '+name+'-'+WORK.name+'\nCMD ["python3","-m","http.server","8080"]\n')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 endpoint={'service':'app','directory':'.','path':'/','hostPort':port,'containerPort':8080}
 manifest={'schemaVersion':1,'id':name,'name':name,'frontend':endpoint,'backend':endpoint,'services':{'app':{'build':{'context':'.','dockerfile':'Dockerfile'},'mounts':[]}}}
 (root/'okdocker.json').write_text(json.dumps(manifest));r=json.loads(cli('import',root).stdout);records.append(r)
 log=open(root/'launcher.log','w');p=subprocess.Popen([str(BIN),'--cli','start',r['id']],env=ENV,stdout=log,stderr=log,start_new_session=True);launchers.append(p)
 for _ in range(200):
  if p.poll() is not None:raise AssertionError('Build launcher ended unexpectedly')
  if clients(r):
   time.sleep(.3)
   return r,p
  time.sleep(.1)
 raise AssertionError('Did not observe a real pending build')

report={'work':str(WORK),'checks':checks}
try:
 a,p=fixture('pending-live')
 cli('close',a['id'],'--force');p.wait(timeout=12)
 check('live launcher cancelled with nonzero result',p.returncode!=0)
 check('live owned build client revoked',not clients(a))
 check('live cancelled app has no running containers',json.loads(cli('status',a['id']).stdout)['running']==0)
 b,p=fixture('pending-orphan');p.kill();p.wait(timeout=5)
 check('orphan client exists after launcher death',bool(clients(b)))
 cli('close',b['id'],'--force')
 check('scoped orphan build client revoked',not clients(b))
 check('orphan app has no running containers',json.loads(cli('status',b['id']).stdout)['running']==0)
 time.sleep(48)
 check('neither cancelled build starts app later',all(json.loads(cli('status',r['id']).stdout)['running']==0 for r in records))
 report['passed']=True
finally:
 for p in launchers:
  if p.poll() is None:p.kill();p.wait(timeout=5)
 errors=[]
 for r in records:
  try:cli('close',r['id'],'--force');cli('forget',r['id'])
  except Exception as e:errors.append(str(e))
 report['cleanupErrors']=errors
 out=ROOT/'artifacts/apple-cancellation/report.json';out.parent.mkdir(exist_ok=True);out.write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False,indent=2))
