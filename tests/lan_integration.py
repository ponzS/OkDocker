#!/usr/bin/env python3
"""Real isolated LAN forwarding. No production app start/stop or business requests."""
import hashlib,json,os,pathlib,socket,subprocess,tempfile,time,urllib.request,threading,http.server
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'
BASE=pathlib.Path.home()/'Library/Application Support/OkDocker/Validation/LAN';BASE.mkdir(parents=True,exist_ok=True)
WORK=pathlib.Path(tempfile.mkdtemp(dir=BASE));ENV=dict(os.environ,OKDOCKER_SUPPORT=str(WORK/'support'),OKDOCKER_RESOURCES=str(ROOT/'dist/OkDocker.app/Contents/Resources'))
records=[];checks=[];foreign=None;gui=None
REPORT={'work':str(WORK),'checks':checks,'productionRequestsSent':0}
def run(args,ok=True,timeout=90,env=None):
 p=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=timeout,env=env)
 if ok and p.returncode:raise AssertionError(p.stderr[-1800:]+p.stdout[-1800:])
 return p
def cli(*args,**kw):return run([BIN,'--cli',*args],env=ENV,**kw)
def c(*args):return run(['/usr/local/bin/container',*args]).stdout
def check(name,value):
 if not value:raise AssertionError(name)
 checks.append(name);print('PASS',name,flush=True)
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def request(host,p,path='/',body=None):
 op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 with op.open(urllib.request.Request(f'http://{host}:{p}{path}',data=body),timeout=6) as r:return r.read()
def inaccessible(host,p):
 try:request(host,p);return False
 except Exception:return True
def wait_local(p):
 for _ in range(80):
  try:return request('127.0.0.1',p)
  except Exception:time.sleep(.15)
 raise AssertionError('Local endpoint not ready')
def fixture(name):
 app=WORK/name;app.mkdir();p1,p2=port(),port()
 (app/'server.py').write_text('''import http.server,hashlib
class H(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def do_GET(self):
  if self.path=='/upgrade':
   self.send_response(101);self.send_header('Upgrade','okdocker-echo');self.send_header('Connection','Upgrade');self.end_headers();self.wfile.flush()
   while True:
    data=self.rfile.read(4)
    if not data:break
    self.wfile.write(data);self.wfile.flush()
   return
  data=(b'LAN-FIXTURE' if self.path!='q' else b'bad') if self.path!='/large' else b'abcdef01'*131072
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  data=self.rfile.read(int(self.headers['Content-Length']));data=hashlib.sha256(data).hexdigest().encode()
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
http.server.ThreadingHTTPServer(('0.0.0.0',8080),H).serve_forever()
''')
 endpoint={'service':'app','directory':'.','path':'/','containerPort':8080,'hostPort':p1}
 m={'schemaVersion':1,'id':name,'name':name,'frontend':endpoint,'backend':dict(endpoint,hostPort=p2),'services':{'app':{'image':'python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e','command':['python3','/workspace/server.py']}}}
 (app/'okdocker.json').write_text(json.dumps(m));r=json.loads(cli('import',app).stdout);records.append(r)
 cli('start',r['id']);wait_local(p1);return r,app,m,p1,p2
try:
 a,app,m,p1,p2=fixture('lan-one');b,_,_,p3,_=fixture('lan-two')
 host=run(['/usr/sbin/ipconfig','getifaddr','en0']).stdout.strip();REPORT['hostAddress']=host
 check('LAN permission defaults off',not a.get('lanAccess',False) and not json.loads(cli('lan',a['id'],'status').stdout)['enabled'])
 check('no LAN listener before approval',inaccessible(host,p1))
 before=json.loads(c('inspect',a['project']+'-app'))[0];boot=c('exec',a['project']+'-app','cat','/proc/sys/kernel/random/boot_id')
 cli('lan',a['id'],'on');status=json.loads(cli('lan',a['id'],'status').stdout)
 check('actual private Mac address published',host in status['addresses'] and not status['error'])
 check('LAN frontend HTTP content',request(host,p1)==b'LAN-FIXTURE')
 check('separate backend port forwarded',request(host,p2)==b'LAN-FIXTURE')
 check('local HTTP preserved',request('127.0.0.1',p1)==b'LAN-FIXTURE')
 check('refused live removal preserves LAN access',cli('forget',a['id'],ok=False).returncode!=0 and request(host,p1)==b'LAN-FIXTURE')
 after=json.loads(c('inspect',a['project']+'-app'))[0]
 check('no container reconfiguration or VM restart',before['configuration']==after['configuration'] and boot==c('exec',a['project']+'-app','cat','/proc/sys/kernel/random/boot_id'))
 check('actual container remains loopback only',all(p['hostAddress']=='127.0.0.1' for p in after['configuration']['publishedPorts']))
 check('one app permission cannot open another',inaccessible(host,p3) and request('127.0.0.1',p3)==b'LAN-FIXTURE')
 check('large complete response transport',request(host,p1,'/large')==b'abcdef01'*131072)
 data=bytes(range(256))*4096
 check('large complete upload transport',request(host,p1,'/',data).decode()==hashlib.sha256(data).hexdigest())
 with socket.create_connection((host,p1),timeout=6) as s:
  s.sendall(b'GET /upgrade HTTP/1.1\r\nHost: fixture\r\nConnection: Upgrade\r\nUpgrade: okdocker-echo\r\n\r\n');buf=b''
  while b'\r\n\r\n' not in buf:buf+=s.recv(1024)
  s.sendall(b'ping');check('HTTP Upgrade duplex transport',s.recv(4)==b'ping')
  cli('lan',a['id'],'off')
  try:closed=not s.recv(4)
  except OSError:closed=True
 check('disable disconnects existing connections',closed)
 check('disable closes LAN but not local service',inaccessible(host,p1) and request('127.0.0.1',p1)==b'LAN-FIXTURE')
 cli('lan',a['id'],'on')
 ui=WORK/'ui';gui=subprocess.Popen([str(BIN),'--ui-smoke-test',str(ui),'--ui-feature-smoke'],env=ENV,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 gui.wait(timeout=45);check('native GUI smoke completed',json.loads((ui/'native-ui.json').read_text())['windowVisible'])
 check('UI exit preserves approved LAN endpoint',request(host,p1)==b'LAN-FIXTURE')
 check('actual rules and LAN settings views captured',set(json.loads((ui/'feature-views.json').read_text())['captured'])=={'rules','app-settings'})
 (WORK/'support/apps'/a['id']/'lan-ready.json').unlink(missing_ok=True)
 cli('lan',a['id'],'off');check('revokes helper even with missing readiness receipt',inaccessible(host,p1))
 cli('lan',a['id'],'on')
 # Optional true phone -> Wi-Fi -> Mac HTTP check, no input, pairing or settings changes.
 devices=run(['/opt/homebrew/bin/adb','devices']).stdout.splitlines()[1:];phone_success=False
 REPORT['authorizedPhonesAvailable']=sum(len(row.split())==2 and row.split()[1]=='device' for row in devices)
 for line in devices:
  fields=line.split()
  if len(fields)!=2 or fields[1]!='device':continue
  for target_host in status['addresses']:
   command=f"printf 'GET / HTTP/1.0\\r\\nHost: fixture\\r\\nConnection: close\\r\\n\\r\\n' | toybox nc -q 5 -w 3 -W 5 {target_host} {p1}"
   try:
    response=run(['/opt/homebrew/bin/adb','-s',fields[0],'shell',command],ok=False,timeout=8)
    if 'LAN-FIXTURE' in response.stdout:
     phone_success=True;REPORT['phoneLANAddressVerified']=target_host;break
   except subprocess.TimeoutExpired:pass
  if phone_success:break
 REPORT['realPhoneLANReadOnlyHTTP']=phone_success
 if phone_success:check('real authorized phone LAN HTTP GET',True)
 cli('close',a['id'],'--force')
 check('force close revokes LAN helper',inaccessible(host,p1) and not json.loads(cli('lan',a['id'],'status').stdout)['addresses'])
 check('force close does not affect unrelated app',request('127.0.0.1',p3)==b'LAN-FIXTURE')
 cli('start',a['id']);wait_local(p1)
 check('restart restores explicit LAN permission',request(host,p1)==b'LAN-FIXTURE')
 changed=dict(m,name='Changed');(app/'okdocker.json').write_text(json.dumps(changed));cli('lan',a['id'],'off')
 check('can revoke LAN after manifest changes',inaccessible(host,p1) and not json.loads(cli('lan',a['id'],'status').stdout)['enabled'])
 (app/'okdocker.json').write_text(json.dumps(m));cli('lan',a['id'],'on')
 c('stop','--signal','KILL',a['project']+'-app')
 class Foreign(http.server.BaseHTTPRequestHandler):
  def do_GET(self):self.send_response(200);self.end_headers();self.wfile.write(b'FOREIGN-SECRET')
  def log_message(self,*args):pass
 foreign=http.server.ThreadingHTTPServer(('127.0.0.1',p1),Foreign);threading.Thread(target=foreign.serve_forever,daemon=True).start()
 check('loopback port reuse cannot expose unrelated service',inaccessible(host,p1))
 check('foreign service itself remains untouched',request('127.0.0.1',p1)==b'FOREIGN-SECRET')
 check('copied rules source is complete and generic','schemaVersion' in cli('rules').stdout and '小红书' not in cli('rules').stdout)
 REPORT['passed']=True
except Exception as e:REPORT['passed']=False;REPORT['error']=repr(e);raise
finally:
 if foreign:foreign.shutdown();foreign.server_close()
 if gui and gui.poll() is None:gui.terminate();gui.wait(timeout=5)
 errors=[]
 for r in records:
  for action in [('lan',r['id'],'off'),('close',r['id'],'--force'),('forget',r['id'])]:
   p=cli(*action,ok=False)
   if p.returncode:errors.append(p.stderr[-500:])
 REPORT['cleanupErrors']=errors
 dest=ROOT/'artifacts/lan-validation';dest.mkdir(parents=True,exist_ok=True);(dest/'report.json').write_text(json.dumps(REPORT,ensure_ascii=False,indent=2))
 print(json.dumps(REPORT,ensure_ascii=False,indent=2),flush=True)
