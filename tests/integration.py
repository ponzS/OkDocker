#!/usr/bin/env python3
"""Real Docker lifecycle/isolation tests. Uses isolated registration and fixture data."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'artifacts/validation'
REPORT.mkdir(parents=True, exist_ok=True)
OUT = Path(os.environ.get('OKDOCKER_TEST_WORK', Path.home() / 'Library/Application Support/OkDocker/Validation/Core'))
OUT.mkdir(parents=True, exist_ok=True)
APP = ROOT / 'dist/OkDocker.app/Contents/MacOS/OkDocker'
ENV = dict(os.environ, OKDOCKER_SUPPORT=str(OUT / 'support'), SECRET='must-not-interpolate')
CONTEXT = os.environ.get('OKDOCKER_TEST_CONTEXT', 'colima-okdocker')
IMAGE = 'python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
checks = []
records = []

def check(name, value):
    if not value:
        raise AssertionError(name)
    checks.append(name)
    print('PASS ' + name, flush=True)

def cli(*args, ok=True):
    p = subprocess.run([str(APP), '--cli', *map(str, args)], env=ENV, capture_output=True, text=True, timeout=180)
    if ok and p.returncode:
        raise RuntimeError(p.stderr[-4000:])
    return p

def docker(*args):
    return subprocess.check_output(['/opt/homebrew/bin/docker', '--context', CONTEXT, *args], text=True)

def http(port, path='/'):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=4) as r:
        return r.read().decode()

def wait(port):
    for _ in range(40):
        try:
            return http(port)
        except Exception:
            time.sleep(.25)
    raise AssertionError('HTTP never became reachable')

SERVER = '''import http.server,json,os,pathlib,signal
signal.signal(signal.SIGTERM, signal.SIG_IGN)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  f=pathlib.Path('/workspace/data/count')
  count=int(f.read_text()) if f.exists() else 0
  if self.path=='/increment':
   count+=1
   with f.open('w') as w: w.write(str(count));w.flush();os.fsync(w.fileno())
  data=json.dumps({'count':count,'literal':os.getenv('LITERAL'),'adb':os.getenv('ADB_SERVER_SOCKET'),'hostMarkerVisible':pathlib.Path(os.environ['HOST_MARKER']).exists(),'dockerSocket':pathlib.Path('/var/run/docker.sock').exists()}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
http.server.HTTPServer(('0.0.0.0',8080),Handler).serve_forever()
'''
try:
    marker = OUT / 'unshared-host-marker'
    marker.write_text('test fixture, not a secret')
    for index, port in enumerate([18081, 18082]):
        directory = OUT / f'app-{index}'
        (directory / 'data').mkdir(parents=True, exist_ok=True)
        (directory / 'server.py').write_text(SERVER)
        (directory / '.env').write_text('COMPOSE_FILE=/etc/passwd\nCOMPOSE_PROJECT_NAME=not-authorized\n')
        manifest = {'schemaVersion':1,'id':f'test-{index}','name':f'Test {index}', 'autoStart': True,
            'frontend':{'service':'app','directory':'.','path':'/','hostPort':port,'containerPort':8080},
            'backend':{'service':'app','directory':'.','path':'/','hostPort':port,'containerPort':8080},
            'services':{'app':{'image':IMAGE,'command':['python3','/workspace/server.py'],
                'environment':{'LITERAL':'${SECRET} a$b','HOST_MARKER':str(marker)}}}}
        (directory / 'okdocker.json').write_text(json.dumps(manifest))
        r = json.loads(cli('import', directory, '--context', CONTEXT).stdout)
        records.append(r)
        check(f'import-{index}-autostart-off-even-if-file-on', r['autoStart'] is False)
        cli('start', r['id']); wait(port)
        state = json.loads(cli('status', r['id']).stdout)
        check(f'app-{index}-actual-running', state['running'] == 1 and state['state'] == 'running')
        s = json.loads(http(port))
        check(f'app-{index}-literal-env-preserved', s['literal'] == '${SECRET} a$b')
        check(f'app-{index}-no-host-sibling-or-docker-socket', not s['hostMarkerVisible'] and not s['dockerSocket'])
        check(f'app-{index}-no-adb-injection-by-default', s['adb'] is None)
        inspect = json.loads(docker('inspect', docker('ps','-q','--filter',f'label=com.docker.compose.project={r["project"]}').strip()))[0]
        check(f'app-{index}-mount-scoped-to-own-directory', all(m['Source'] == str(directory) for m in inspect['Mounts']))
        check(f'app-{index}-ports-loopback-only', all(p['HostIp'] == '127.0.0.1' for ports in inspect['NetworkSettings']['Ports'].values() if ports for p in ports))
    first = records[0]
    old = json.loads(http(18081))['count']
    check('write-persistent-data', json.loads(http(18081, '/increment'))['count'] == old + 1)
    started = time.monotonic(); cli('close', first['id'], '--force'); elapsed = time.monotonic()-started
    stopped = json.loads(cli('status', first['id']).stdout)
    check('force-stop-observed-stopped', stopped['running'] == 0 and stopped['state'] == 'stopped')
    inspect = json.loads(docker('inspect', docker('ps','-aq','--filter',f'label=com.docker.compose.project={first["project"]}').strip()))[0]
    check('force-stop-is-SIGKILL-not-graceful', inspect['State']['ExitCode'] == 137 and elapsed < 8)
    check('other-project-still-running', bool(http(18082)))
    cli('start', first['id']); wait(18081)
    check('data-survives-force-stop-and-restart', json.loads(http(18081))['count'] == old + 1)
    cli('autostart', first['id'], 'off')
    check('autostart-off-persisted', not next(r for r in json.loads(cli('list').stdout) if r['id']==first['id'])['autoStart'])
    manifest_file = Path(first['root']) / 'okdocker.json'
    original = manifest_file.read_bytes(); changed = json.loads(original); changed['hostAndroidDevices'] = True
    manifest_file.write_text(json.dumps(changed))
    check('changed-permission-requires-reimport', cli('start', first['id'], ok=False).returncode != 0)
    cli('close', first['id'], '--force')
    check('can-force-stop-despite-changed-manifest', json.loads(cli('status', first['id']).stdout)['running'] == 0)
    manifest_file.write_bytes(original)
    slow = OUT / 'slow-build'
    slow.mkdir(exist_ok=True)
    (slow / 'Dockerfile').write_text('FROM '+IMAGE+'\nRUN sleep 30 && echo '+str(time.time_ns())+'\nCMD ["python3", "-m", "http.server", "8080"]\n')
    manifest = json.loads(original); manifest['id']='slow-build'; manifest['name']='Slow build cancellation'
    manifest['frontend']['hostPort']=18083; manifest['backend']['hostPort']=18083
    manifest['services']={'app':{'build':{'context':'.','dockerfile':'Dockerfile'},'mounts':[]}}
    (slow/'okdocker.json').write_text(json.dumps(manifest))
    record=json.loads(cli('import',slow,'--context',CONTEXT).stdout); records.append(record)
    with (OUT/'cancelled-start.log').open('w') as log:
        process=subprocess.Popen([str(APP),'--cli','start',record['id']],env=ENV,stdout=log,stderr=log)
        for _ in range(100):
            if (OUT/'support/apps'/record['id']/'compose.json').exists(): break
            time.sleep(.1)
        time.sleep(1)
        cli('close',record['id'],'--force')
        process.wait(timeout=10)
        check('force-close-cancels-in-flight-build',process.returncode!=0)
        time.sleep(.5)
        check('cancelled-build-cannot-start-later',json.loads(cli('status',record['id']).stdout)['running']==0)
    with (OUT/'orphaned-start.log').open('w') as log:
        process=subprocess.Popen([str(APP),'--cli','start',record['id']],env=ENV,stdout=log,stderr=log)
        pattern='(^|/)docker-compose .*--project-name '+record['project']+' .* (build|up -d)'
        for _ in range(120):
            if subprocess.run(['/usr/bin/pgrep','-f',pattern],capture_output=True).returncode==0: break
            time.sleep(.1)
        else: raise AssertionError('No in-flight scoped Compose up client observed')
        process.kill(); process.wait(timeout=5)
        cli('close',record['id'],'--force')
        check('force-close-revokes-orphaned-compose-client',subprocess.run(['/usr/bin/pgrep','-f',pattern],capture_output=True).returncode!=0)
        check('orphaned-start-leaves-no-running-containers',json.loads(cli('status',record['id']).stdout)['running']==0)
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        listener.bind(('0.0.0.0',0)); listener.listen(1)
        directory=OUT/'port-conflict'; directory.mkdir(exist_ok=True)
        manifest=json.loads(original); manifest['id']='port-conflict';manifest['name']='Wildcard port conflict'
        manifest['frontend']['hostPort']=listener.getsockname()[1];manifest['backend']['hostPort']=listener.getsockname()[1]
        (directory/'okdocker.json').write_text(json.dumps(manifest))
        conflict=json.loads(cli('import',directory,'--context',CONTEXT).stdout);records.append(conflict)
        check('wildcard-host-listener-refuses-start',cli('start',conflict['id'],ok=False).returncode!=0)
        check('port-conflict-creates-no-containers',docker('ps','-aq','--filter','label=com.docker.compose.project='+conflict['project']).strip()=='')
finally:
    for r in records:
        cli('close', r['id'], '--force', ok=False)
        cli('forget', r['id'], ok=False)
    (REPORT / 'report.json').write_text(json.dumps({'passed':checks,'count':len(checks),'productionServiceTouched':False}, indent=2))
print(json.dumps({'passed':len(checks),'report':str(REPORT/'report.json')}, indent=2))
