#!/usr/bin/env python3
"""Real Linux pipeline on Apple, new data/no Key, publishing never enabled."""
import http.cookiejar, json, os, pathlib, re, subprocess, tempfile, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
BASE=pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/ApplePipeline';BASE.mkdir(parents=True,exist_ok=True)
WORK=pathlib.Path(tempfile.mkdtemp(dir=BASE));DIRECTORY=WORK/'app';SUPPORT=WORK/'support'
ENV=dict(os.environ,OKDOCKER_SUPPORT=str(SUPPORT));BIN=ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'
PORT=19865;checks=[];record=None
class Client:
 def __init__(self,port):
  self.base=f'http://127.0.0.1:{port}'
  self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
  self.html=self.opener.open(self.base+'/',timeout=10).read().decode();self.token=re.search(r'name="csrf-token" content="([^"]+)"',self.html)[1]
 def get(self,path):return json.load(self.opener.open(self.base+path,timeout=30))
 def post(self,path,value):
  req=urllib.request.Request(self.base+path,json.dumps(value).encode(),{'Content-Type':'application/json','X-Xhs-Token':self.token,'Origin':self.base})
  return json.load(self.opener.open(req,timeout=20))
def run(args,timeout=120):
 p=subprocess.run(list(map(str,args)),capture_output=True,text=True,env=ENV,timeout=timeout)
 if p.returncode:raise AssertionError(p.stderr[-3500:]+p.stdout[-3500:])
 return p.stdout
def cli(*args):return run([BIN,'--cli',*args],timeout=1800)
def c(*args):return run(['/usr/local/bin/container',*args])
def check(name,value):
 assert value,name
 checks.append(name);print('PASS',name,flush=True)
def wait():
 last=None
 for _ in range(100):
  try:return Client(PORT)
  except Exception as e:last=e;time.sleep(.3)
 raise AssertionError(f'Pipeline frontend not ready: {type(last).__name__}: {last}')
def adb_pid():return subprocess.check_output(['/usr/sbin/lsof','-nP','-t','-iTCP:5037','-sTCP:LISTEN'],text=True).split()
host=Client(17865);before=host.get('/api/state');pids=subprocess.check_output(['/usr/sbin/lsof','-nP','-t','-iTCP:17865','-sTCP:LISTEN'],text=True).split();adb_before=adb_pid()
report={'work':str(WORK),'checks':checks,'publishingStartRequestsSent':0,'productionDataMounted':False}
run(['python3',ROOT/'integrations/xhs-liushuixian/prepare.py',ROOT.parent/'xhs-liushuixian','--destination',DIRECTORY,'--port',PORT])
try:
 record=json.loads(cli('import',DIRECTORY));cli('start',record['id']);test=wait();state=test.get('/api/state');primary=record['project']+'-pipeline'
 check('native arm64 actual pipeline',c('exec',primary,'uname','-s','-m').strip()=='Linux aarch64')
 check('real frontend and health',len(test.html)>1000 and test.get('/health') is not None)
 check('fresh database with no jobs/assets/key',not state['jobs'] and not state['assets'] and not state['config']['apiKeyConfigured'])
 check('publishing paused by default',not state['engine']['running'] and not state['engine']['active'])
 check('no Android channel by default',not state['devices'] and not state['deviceError'])
 check('Linux FFmpeg available','ffmpeg version' in c('exec',primary,'ffmpeg','-version'))
 check('approved source-only build staging',not any(p.name in ['apikey.md','pipeline.sqlite','secret.key'] for p in (DIRECTORY/'.okdocker-build').rglob('*')))
 test.post('/api/config',{'overlayText':'Apple isolated persistence check'})
 cli('close',record['id'],'--force');check('actual stopped after SIGKILL',json.loads(cli('status',record['id']))['running']==0)
 check('SQLite retained on Mac',(DIRECTORY/'data/pipeline.sqlite').exists())
 cli('start',record['id']);test=wait();state=test.get('/api/state')
 check('SQLite config survives restart',state['config']['overlayText']=='Apple isolated persistence check')
 check('restart stays paused',not state['engine']['running'])
 cli('close',record['id'],'--force');cli('forget',record['id']);record=None
 manifest=json.loads((DIRECTORY/'okdocker.json').read_text());manifest['hostAndroidDevices']=True;(DIRECTORY/'okdocker.json').write_text(json.dumps(manifest))
 # New registration is an explicit new deployment; bind data remains unchanged.
 record=json.loads(cli('import',DIRECTORY));cli('start',record['id']);test=wait();state=test.get('/api/state');primary=record['project']+'-pipeline'
 check('actual pipeline and sidecar running',json.loads(cli('status',record['id']))['running']==2)
 native=subprocess.check_output(['/opt/homebrew/bin/adb','devices'],text=True)
 authorized={line.split()[0] for line in native.splitlines()[1:] if line.strip().endswith('\tdevice')}
 visible={d['serial'] for d in state['devices'] if d['state']=='device'}
 check('Linux ADB sees authorized native phones',bool(authorized) and authorized.issubset(visible) and not state['deviceError'])
 selected=sorted(authorized)[0]
 check('Linux ADB read-only getprop through Unix chain',bool(c('exec',primary,'adb','-s',selected,'shell','getprop','ro.product.model').strip()))
 check('pipeline never enabled publishing',not test.get('/api/state')['engine']['running'])
 check('shared original adb PID unchanged',adb_pid()==adb_before)
 report.update(passed=True,authorizedDeviceCount=len(authorized))
finally:
 if record:
  if not report.get('passed'):
   detail=ROOT/'artifacts/apple-xhs-failure.log'
   detail.write_text(c('logs','-n','80',record['project']+'-pipeline'));os.chmod(detail,0o600)
  cli('close',record['id'],'--force');cli('forget',record['id'])
 after=Client(17865).get('/api/state')
 report.update(nativePIDUnchanged=subprocess.check_output(['/usr/sbin/lsof','-nP','-t','-iTCP:17865','-sTCP:LISTEN'],text=True).split()==pids,
 nativeRunningBefore=before['engine']['running'],nativeRunningAfter=after['engine']['running'],nativeKeyConfigured=after['config']['apiKeyConfigured'],sharedADBPIDUnchanged=adb_pid()==adb_before)
 out=ROOT/'artifacts/apple-xhs/report.json';out.parent.mkdir(exist_ok=True);out.write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
