#!/usr/bin/env python3
"""Isolated ADB lifecycle regression. Never starts a registered user app.

Only host:version/devices-l are sent to shared ADB; no phone shell/UI actions.
Use OKDOCKER_BIN to test an installed or candidate bundle.
"""
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('OKDOCKER_BIN', ROOT / 'dist/OkDocker.app/Contents/MacOS/OkDocker'))
C = '/usr/local/bin/container'
BASE = pathlib.Path.home() / 'Library/Application Support/OkDocker/Validation/AppleAndroid'
BASE.mkdir(parents=True, exist_ok=True)
WORK = pathlib.Path(tempfile.mkdtemp(dir=BASE))
APP, SUPPORT = WORK / 'app', WORK / 'support'
APP.mkdir()
OLD_BIN = os.environ.get('OKDOCKER_OLD_BIN')
RELAY_TEST_BIN = os.environ.get('OKDOCKER_RELAY_TEST_BIN')
if RELAY_TEST_BIN:
    shutil.copy2(RELAY_TEST_BIN, APP / 'relay-tests')
ENV = dict(os.environ, OKDOCKER_SUPPORT=str(SUPPORT))
IMAGE = 'python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
checks, cleanup_errors = [], []
record = None


def run(args, *, timeout=90, check=True):
    p = subprocess.run(list(map(str, args)), env=ENV, text=True, capture_output=True, timeout=timeout)
    if check and p.returncode:
        raise AssertionError(p.stderr[-2500:] + p.stdout[-2500:])
    return p


def cli(*args, **kwargs):
    return run([BIN, '--cli', *args], **kwargs)


def c(*args, **kwargs):
    return run([C, *args], **kwargs)


def check(name, value):
    assert value, name
    checks.append(name)
    print('PASS', name, flush=True)


def snapshot():
    return {r['configuration']['id']: r.get('status', {}).get('state')
            for r in json.loads(c('list', '--all', '--format', 'json').stdout)}


def adb_pid():
    return run(['/usr/sbin/lsof', '-nP', '-t', '-iTCP:5037', '-sTCP:LISTEN'], check=False).stdout.split()


def native_devices():
    # Read the smart-socket protocol directly: this does not start/stop ADB.
    with socket.create_connection(('127.0.0.1', 5037), timeout=5) as s:
        s.sendall(b'000ehost:devices-l')
        def exact(n):
            out = b''
            while len(out) < n:
                chunk = s.recv(n - len(out))
                if not chunk:
                    raise AssertionError('short native ADB response')
                out += chunk
            return out
        assert exact(4) == b'OKAY'
        return {line.split()[0] for line in exact(int(exact(4), 16)).decode().splitlines() if line.strip()}


PROBE = '''import json,socket
s=socket.socket(socket.AF_UNIX);s.settimeout(6);s.connect('/run/okdocker-adb.sock')
def exact(n):
 b=b''
 while len(b)<n:
  p=s.recv(n-len(b))
  if not p:raise RuntimeError('short relay response')
  b+=p
 return b
s.sendall(b'000ehost:devices-l')
assert exact(4)==b'OKAY'
print(json.dumps([line.split()[0] for line in exact(int(exact(4),16)).decode().splitlines() if line.strip()]))
'''

# This workload deliberately queries ADB immediately on process start. The old
# relay exec race was hidden by HTTP-only fixtures or delayed, manual probes.
(APP / 'server.py').write_text('''import os,signal,socket,time
from pathlib import Path
s=socket.socket(socket.AF_UNIX);s.settimeout(5)
s.connect('/run/okdocker-adb.sock');s.sendall(b'000chost:version')
assert s.recv(4)==b'OKAY'
s.close()
Path('/workspace/started').write_text('ready')
def stop(*_):
 Path('/workspace/terminated').write_text('TERM forwarded')
 raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
while True:time.sleep(1)
''')
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
endpoint = dict(service='app', directory='.', path='/', hostPort=port, containerPort=8080)
manifest = dict(schemaVersion=1, id='android-lifecycle', name='Android lifecycle fixture',
                frontend=endpoint, backend=endpoint, hostAndroidDevices=True,
                services={'app': dict(image=IMAGE, command=['/usr/local/bin/python3', '/workspace/server.py'])})
(APP / 'okdocker.json').write_text(json.dumps(manifest))
before, before_pid = snapshot(), adb_pid()
report = dict(work=str(WORK), checks=checks, phoneActions='host:version and host:devices-l only', cleanupErrors=cleanup_errors)
try:
    record = json.loads(cli('import', APP).stdout)
    main = record['project'] + '-app'
    if OLD_BIN:
        # Create an old container with a workload that does not initially
        # require ADB. Preserve its layer while upgrading only the manager.
        workload = (APP / 'server.py').read_text()
        (APP / 'server.py').write_text('import time\nwhile True:time.sleep(1)\n')
        run([OLD_BIN, '--cli', 'start', record['id']])
        original = json.loads(c('inspect', main).stdout)[0]['configuration']
        c('exec', main, 'sh', '-c', 'printf kept >/root/upgrade-marker')
        cli('close', record['id'], '--force')
        (APP / 'server.py').write_text(workload)
        (APP / 'started').unlink(missing_ok=True)
        cli('start', record['id'])
        upgraded = json.loads(c('inspect', main).stdout)[0]['configuration']
        check('old container upgraded without replacement', original['id'] == upgraded['id'] and original['creationDate'] == upgraded['creationDate'])
        check('old container starts with repaired relay', (APP / 'started').exists())
        check('old container writable layer retained', c('exec', main, 'cat', '/root/upgrade-marker').stdout == 'kept')
        cli('close', record['id'], '--force')

    def devices():
        return set(json.loads(c('exec', main, 'python3', '-c', PROBE).stdout))

    def started():
        for _ in range(60):
            if (APP / 'started').exists():
                return True
            time.sleep(.1)
        return False

    for iteration in range(4):
        (APP / 'started').unlink(missing_ok=True)
        cli('start', record['id'])
        check(f'app starts with ADB ready, cycle {iteration}', started())
        check(f'phones match native ADB, cycle {iteration}', devices() == native_devices())
        check(f'only one app VM, cycle {iteration}', json.loads(cli('status', record['id']).stdout)['running'] == 1)
        if iteration == 0:
            if RELAY_TEST_BIN:
                tests = c('exec', main, '/workspace/relay-tests', '-test.v', timeout=90)
                print(tests.stdout, flush=True)
                check('relay protocol and supervisor tests pass inside Linux VM', 'PASS' in tests.stdout)
            c('exec', main, 'sh', '-c', 'printf preserved >/root/layer-marker')
        check(f'writable layer preserved, cycle {iteration}', c('exec', main, 'cat', '/root/layer-marker').stdout == 'preserved')
        cli('close', record['id'], '--force')
        check(f'actual stopped, cycle {iteration}', json.loads(cli('status', record['id']).stdout)['running'] == 0)

    cli('start', record['id'])
    ready_path = SUPPORT / 'apps' / record['id'] / 'bridge-ready.json'
    old_ready = json.loads(ready_path.read_text())
    os.kill(old_ready['pid'], signal.SIGTERM)
    time.sleep(.5)
    # A start on an already running app must repair only its host bridge/config,
    # rather than returning early on VM state or restarting the workload.
    old_boot = c('exec', main, 'cat', '/proc/sys/kernel/random/boot_id').stdout
    identity = """import os,json
for pid in os.listdir('/proc'):
 if pid.isdigit():
  try:
   command=open('/proc/'+pid+'/cmdline','rb').read()
   if command==b'/usr/local/bin/python3\\x00/workspace/server.py\\x00':
    print(json.dumps([pid,open('/proc/'+pid+'/stat').read().split()[21]]));break
  except (FileNotFoundError,ProcessLookupError):pass
else:raise RuntimeError('workload is missing')
"""
    old_process = c('exec', main, 'python3', '-c', identity).stdout
    cli('start', record['id'])
    new_ready = json.loads(ready_path.read_text())
    check('host bridge recreated on running-app start', new_ready['pid'] != old_ready['pid'])
    check('rotated token reloaded without workload restart', devices() == native_devices())
    check('VM unchanged after bridge repair', old_boot == c('exec', main, 'cat', '/proc/sys/kernel/random/boot_id').stdout)
    check('application process unchanged after bridge repair', old_process == c('exec', main, 'python3', '-c', identity).stdout)

    def guard(token):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(3)
            s.connect(new_ready['socket'])
            s.sendall((token + '\n0009host:kill').encode())
            try:
                return s.recv(4096)
            except ConnectionResetError:
                return b''

    check('wrong token rejected', guard('0' * 64) == b'')
    check('shared ADB shutdown rejected', guard(new_ready['token']).startswith(b'FAIL'))
    check('private socket only', 'port' not in new_ready and os.stat(new_ready['socket']).st_mode & 0o777 == 0o600)
    c('stop', '--time', '5', main)
    check('SIGTERM forwarded to application', (APP / 'terminated').read_text() == 'TERM forwarded')
    check('application VM actually stopped', json.loads(cli('status', record['id']).stdout)['running'] == 0)
    report['passed'] = True
finally:
    if record:
        for args in [('close', record['id'], '--force'), ('forget', record['id'])]:
            try:
                cli(*args)
            except Exception as error:
                cleanup_errors.append(str(error))
    report.update(adbServerPIDUnchanged=before_pid == adb_pid(), otherContainersUnchanged=before == snapshot())
    output = ROOT / 'artifacts/android-lifecycle/report.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)
assert report['adbServerPIDUnchanged'] and report['otherContainersUnchanged'] and not cleanup_errors
