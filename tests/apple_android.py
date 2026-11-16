#!/usr/bin/env python3
"""Shared ADB on a project-private Apple network; read-only phone commands only."""
import json, os, pathlib, socket, subprocess, tempfile, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'
BASE=pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/AppleAndroid';BASE.mkdir(parents=True,exist_ok=True)
WORK=pathlib.Path(tempfile.mkdtemp(dir=BASE));APP=WORK/'app';APP.mkdir();SUPPORT=WORK/'support'
ENV=dict(os.environ,OKDOCKER_SUPPORT=str(SUPPORT))
checks=[];record=None

def run(args,timeout=120,check=True):
 p=subprocess.run(list(map(str,args)),env=ENV,text=True,capture_output=True,timeout=timeout)
 if check and p.returncode:raise AssertionError(p.stderr[-3000:]+p.stdout[-3000:])
 return p.stdout

def cli(*args):return run([BIN,'--cli',*args],timeout=900)
def c(*args):return run(['/usr/local/bin/container',*args])
def check(name,value):
 assert value,name
 checks.append(name);print('PASS',name,flush=True)
def adb_pid():return subprocess.check_output(['/usr/sbin/lsof','-nP','-t','-iTCP:5037','-sTCP:LISTEN'],text=True).split()
def http_native():
 with urllib.request.urlopen('http://127.0.0.1:17865/health',timeout=4) as r:return r.status==200
before_pid=adb_pid();before_host=http_native()
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
endpoint={'service':'app','directory':'.','path':'/','hostPort':port,'containerPort':8080}
manifest={'schemaVersion':1,'id':'apple-android','name':'Apple ADB test','frontend':endpoint,'backend':endpoint,'hostAndroidDevices':True,
 'services':{'app':{'image':'python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e',
 'command':['python3','-m','http.server','8080'],'workingDirectory':'/workspace'}}}
(APP/'index.html').write_text('APPLE ADB FIXTURE');(APP/'okdocker.json').write_text(json.dumps(manifest))
report={'work':str(WORK),'checks':checks,'phoneActions':'devices-l and read-only getprop only','publishingRequestsSent':0}
try:
 record=json.loads(cli('import',APP));cli('start',record['id'])
 check('backend and sidecar both actually running',json.loads(cli('status',record['id']))['running']==2)
 main=record['project']+'-app'
 # Speak ADB's documented smart-socket protocol without installing tools in the fixture.
 script='''import socket,os,json
addr=os.environ['ADB_SERVER_SOCKET']
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(8);s.connect(addr.removeprefix('localfilesystem:'))
def exact(n):
 b=b''
 while len(b)<n:
  p=s.recv(n-len(b))
  if not p:raise RuntimeError('short frame')
  b+=p
 return b
def request(q):
 q=q.encode();s.sendall(('%04x'%len(q)).encode()+q);assert exact(4)==b'OKAY'
request('host:devices-l');out=exact(int(exact(4),16)).decode();print(json.dumps(out))
'''
 devices=json.loads(c('exec',main,'python3','-c',script))
 authorized={line.split()[0] for line in subprocess.check_output(['/opt/homebrew/bin/adb','devices'],text=True).splitlines()[1:] if line.strip().endswith('\tdevice')}
 visible={line.split()[0] for line in devices.splitlines() if len(line.split())>1 and line.split()[1]=='device'}
 check('authorized phones visible over private bridge',bool(authorized) and authorized.issubset(visible))
 selected=sorted(authorized)[0]
 prop_script=script[:script.index("request('host:devices-l')")]+f'''request('host:transport:{selected}');request('shell:getprop ro.product.model')
b=b''
while True:
 p=s.recv(4096)
 if not p:break
 b+=p
print(json.dumps(bool(b.strip())))
'''
 check('read-only phone property through guest transport',json.loads(c('exec',main,'python3','-c',prop_script)) is True)
 ready=json.loads((SUPPORT/'apps'/record['id']/'bridge-ready.json').read_text())
 check('private Unix socket, no network listener',bool(ready['socket']) and 'port' not in ready and (os.stat(ready['socket']).st_mode & 0o777)==0o600)
 def guard(token):
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
   s.settimeout(3);s.connect(ready['socket'])
   s.sendall((token+'\n0009host:kill').encode())
   try:return s.recv(4096)
   except ConnectionResetError:return b''
 check('wrong token rejected',guard('0'*64)==b'')
 check('shared adb shutdown request blocked',guard(ready['token']).startswith(b'FAIL'))
 check('shared original adb server unchanged',adb_pid()==before_pid)
 cli('close',record['id'],'--force')
 check('all project containers stopped',json.loads(cli('status',record['id']))['running']==0)
 check('closing app does not stop shared adb',adb_pid()==before_pid)
 cli('start',record['id'])
 check('Android-enabled app restarts without wiping backend',json.loads(cli('status',record['id']))['running']==2)
 check('transport works after restart',bool(json.loads(c('exec',main,'python3','-c',script))))
 report.update(passed=True,authorizedDeviceCount=len(authorized))
finally:
 if record:
  cli('close',record['id'],'--force');cli('forget',record['id'])
 report.update(nativeServiceStillAvailable=before_host and http_native(),adbServerPIDUnchanged=before_pid==adb_pid())
 out=ROOT/'artifacts/apple-android/report.json';out.parent.mkdir(exist_ok=True);out.write_text(json.dumps(report,ensure_ascii=False,indent=2))
 print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
