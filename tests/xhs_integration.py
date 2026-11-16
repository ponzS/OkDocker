#!/usr/bin/env python3
"""Exercise the actual Linux pipeline with fresh SQLite; never starts publishing.
Host service stays running on 17865. Test instance uses 18865 and no real Key.
"""
import http.cookiejar
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'artifacts/xhs-validation'
REPORT.mkdir(parents=True,exist_ok=True)
OUT = Path(os.environ.get('OKDOCKER_XHS_TEST_WORK',Path.home()/'Library/Application Support/OkDocker/Validation/Pipeline'))
DIRECTORY = OUT / 'app'
APP = ROOT / 'dist/OkDocker.app/Contents/MacOS/OkDocker'
ENV = dict(os.environ, OKDOCKER_SUPPORT=str(OUT/'support'))
CONTEXT = 'colima-okdocker'
checks = []
record = None

class Client:
    def __init__(self, port):
        self.base = f'http://127.0.0.1:{port}'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.refresh()
    def refresh(self):
        html = self.opener.open(self.base + '/', timeout=20).read().decode()
        self.token = re.search(r'name="csrf-token" content="([^"]+)"', html)[1]
        self.html = html
    def get(self, path):
        return json.load(self.opener.open(self.base + path, timeout=30))
    def post(self, path, value):
        request = urllib.request.Request(self.base + path, json.dumps(value).encode(),
             {'Content-Type':'application/json','X-Xhs-Token':self.token,'Origin':self.base})
        return json.load(self.opener.open(request, timeout=30))

def check(name, condition):
    if not condition: raise AssertionError(name)
    checks.append(name); print('PASS '+name, flush=True)

def cli(*args):
    p = subprocess.run([str(APP),'--cli',*map(str,args)],env=ENV,capture_output=True,text=True,timeout=600)
    if p.returncode: raise RuntimeError(p.stderr[-4000:])
    return p.stdout

def docker(*args):
    return subprocess.check_output(['/opt/homebrew/bin/docker','--context',CONTEXT,*args],text=True,timeout=45)

def wait():
    for _ in range(100):
        try: return Client(18865)
        except Exception: time.sleep(.3)
    raise AssertionError('Pipeline HTTP failed to start')

def primary_id():
    return docker('ps','-q','--filter',f'label=com.docker.compose.project={record["project"]}','--filter','label=com.docker.compose.service=pipeline').strip()

def adb_pid():
    # Match the shared server socket, not transient adb client subprocesses
    # spawned by the still-running native pipeline.
    return subprocess.check_output(['/usr/sbin/lsof','-nP','-iTCP:5037','-sTCP:LISTEN','-t'],text=True).split()

manifest = json.loads((DIRECTORY/'okdocker.json').read_text())
manifest['hostAndroidDevices'] = False
(DIRECTORY/'okdocker.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
host = Client(17865)
before = host.get('/api/state')
host_pid = json.loads((ROOT/'artifacts/key-path-restart/new-process.json').read_text())['pid']
server_pids = adb_pid()
try:
    record = json.loads(cli('import',DIRECTORY,'--context',CONTEXT))
    check('import-default-autostart-off', record['autoStart'] is False)
    cli('start',record['id']); test = wait(); state = test.get('/api/state')
    check('linux-front-end-served', 'csrf-token' in test.html and len(test.html)>1000)
    check('linux-health', test.get('/health') is not None)
    check('fresh-data-no-real-key', len(state['jobs'])==0 and len(state['assets'])==0 and not state['config']['apiKeyConfigured'])
    check('publishing-paused-by-default', state['engine']['running'] is False and not state['engine']['active'])
    check('android-not-opened-by-default', not state['devices'] and not state['deviceError'])
    check('actual-linux-arm64-process', docker('exec',primary_id(),'uname','-s','-m').strip()=='Linux aarch64')
    check('linux-ffmpeg-available', 'ffmpeg version' in docker('exec',primary_id(),'ffmpeg','-version'))
    test.post('/api/config',{'overlayText':'OkDocker isolated persistence check'})
    cli('close',record['id'],'--force')
    check('all-containers-force-stopped', json.loads(cli('status',record['id']))['running']==0)
    check('sqlite-files-retained', (DIRECTORY/'data/pipeline.sqlite').exists())
    cli('start',record['id']); test = wait(); state = test.get('/api/state')
    check('sqlite-setting-survives-SIGKILL-restart', state['config']['overlayText']=='OkDocker isolated persistence check')
    check('restart-still-paused', state['engine']['running'] is False)
    cli('close',record['id'],'--force')
    manifest = json.loads((DIRECTORY/'okdocker.json').read_text()); manifest['hostAndroidDevices']=True
    (DIRECTORY/'okdocker.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    record=json.loads(cli('import',DIRECTORY,'--context',CONTEXT))
    cli('start',record['id']); test=wait(); state=test.get('/api/state')
    check('android-sidecar-actual-running', json.loads(cli('status',record['id']))['running']==2)
    if state['deviceError']:
        raise AssertionError('ADB bridge reported: '+state['deviceError'])
    native = subprocess.check_output(['/opt/homebrew/bin/adb','devices'],text=True)
    authorized = {line.split()[0] for line in native.splitlines()[1:] if line.strip().endswith('\tdevice')}
    visible = {d['serial'] for d in state['devices'] if d['state']=='device'}
    check('authorized-android-devices-visible', bool(authorized) and authorized.issubset(visible))
    selected=sorted(authorized)[0]
    model=docker('exec',primary_id(),'adb','-s',selected,'shell','getprop','ro.product.model').strip()
    check('read-only-device-shell-through-bridge', bool(model))
    screenshot = subprocess.check_output(['/opt/homebrew/bin/docker','--context',CONTEXT,'exec',primary_id(),'adb','-s',selected,'exec-out','screencap','-p'],timeout=45)
    # Some phones emit linker/display warnings before PNG, as handled by
    # devices::png in the actual service. Verify complete binary framing.
    check('binary-screenshot-transport-through-bridge', screenshot.find(b'\x89PNG\r\n\x1a\n') >= 0 and screenshot.endswith(b'IEND\xaeB`\x82') and len(screenshot)>1000)
    del screenshot  # No phone screen image is saved or printed.
    check('native-tools-still-see-phones', selected in subprocess.check_output(['/opt/homebrew/bin/adb','devices'],text=True))
    # Never issue kill-server, even for testing: send directly to the bridge guard.
    ready=json.loads((OUT/'support/apps'/record['id']/'bridge-ready.json').read_text())
    def guard_request(token):
        with socket.create_connection(('127.0.0.1',ready['port']),timeout=3) as s:
            s.sendall((token+'\n0009host:kill').encode())
            try: return s.recv(4096)
            except ConnectionResetError: return b''
    check('wrong-token-rejected', guard_request('0'*64)==b'')
    check('shared-ADB-stop-command-rejected', guard_request(ready['token']).startswith(b'FAIL'))
    check('ADB-server-PID-unchanged', adb_pid()==server_pids)
    check('test-publishing-never-enabled', test.get('/api/state')['engine']['running'] is False)
finally:
    if record:
        try: cli('close',record['id'],'--force')
        except Exception as e: print('Cleanup error: '+str(e),flush=True)
    host=Client(17865); after=host.get('/api/state')
    os.kill(host_pid,0)
    report={'passed':checks,'count':len(checks),'hostMode':'native','hostPID':host_pid,
      'hostRunningBefore':before['engine']['running'],'hostRunningAfter':after['engine']['running'],
      'hostKeyConfigured':after['config']['apiKeyConfigured'],'productionDataMounted':False,
      'productionServiceInterrupted':False,'publishingStartRequestsSent':0,
      'authorizedDeviceCount':len(authorized) if 'authorized' in locals() else None,
      'testContainersRunning':json.loads(cli('status',record['id']))['running'] if record else 0,
      'hostADBServerPIDBefore':server_pids,'hostADBServerPIDAfter':adb_pid()}
    (REPORT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False,indent=2))
