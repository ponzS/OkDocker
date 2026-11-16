#!/usr/bin/env python3
"""Native window/menu-bar and login policy smoke test; restores login defaults.
Close any running OkDocker UI before running. Requires the prepared default
Hello Docker registration; does not operate or stop the native pipeline.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import subprocess
import time
import urllib.request

if '--cold-runtime' in sys.argv:
    raise SystemExit('GUI cold Colima boot is disabled: shared-folder I/O failed validation. Prestart the runtime normally.')

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'dist/OkDocker.app/Contents/MacOS/OkDocker'
OUT=ROOT/'artifacts/ui'
OUT.mkdir(exist_ok=True)
def cli(*args,check=True):
    return subprocess.run([str(APP),'--cli',*args],capture_output=True,text=True,check=check,timeout=60).stdout
records=json.loads(cli('list'))
if any(r['autoStart'] for r in records):
    raise SystemExit('Existing startup preferences found; refusing to change them')
status=cli('login-status')
if '(rawValue: 1)' in status or '(rawValue: 2)' in status:
    raise SystemExit('Existing global login preference found; refusing to change it')
# Fixture lives in this app's own support directory. Desktop/Downloads access
# requires the user's macOS permission and is not bypassed by an automated test.
support=Path(os.environ.get('OKDOCKER_SUPPORT',Path.home()/'Library/Application Support/OkDocker'))
fixture=support/'UITestFixture'
(fixture/'public').mkdir(parents=True,exist_ok=True)
shutil.copy2(ROOT/'examples/hello/public/index.html',fixture/'public/index.html')
manifest=json.loads((ROOT/'examples/hello/okdocker.json').read_text())
manifest['name']='Hello · 自动启动验证'; manifest['id']='native-ui-fixture'
(fixture/'okdocker.json').write_text(json.dumps(manifest,ensure_ascii=False))
hello=json.loads(cli('import',str(fixture),'--context','colima-okdocker'))
for name in ['native-ui.json','launcher.png']:
    (OUT/name).unlink(missing_ok=True)
try:
    cli('autostart',hello['id'],'on')
    assert next(r for r in json.loads(cli('list')) if r['id']==hello['id'])['autoStart'] is True
    assert '(rawValue: 1)' in cli('login-status')
    subprocess.run(['/usr/bin/open',str(ROOT/'dist/OkDocker.app'),'--args','--ui-smoke-test',str(OUT)],check=True)
    for _ in range(480):
        if (OUT/'native-ui.json').exists(): break
        time.sleep(.25)
    else: raise AssertionError('Native UI smoke test did not finish')
    report=json.loads((OUT/'native-ui.json').read_text())
    state=json.loads(cli('status',hello['id']))
    report['coldRuntimeStartTested']=False
    report['runtimeWasPrestarted']=True
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    reachable=False
    for _ in range(20):
        try:
            with opener.open('http://127.0.0.1:18080/',timeout=2) as response:
                reachable=response.status==200 and b'OkDocker' in response.read()
            if reachable: break
        except OSError: time.sleep(.25)
    report['frontendReachableAfterGUIExit']=reachable
    report['loginStartupPolicyLaunchedContainer']=state['running']==1
    report['containersSurviveGUIExit']=state['running']==1
    for key in ['windowVisible','menuBarPresent','ownWindowCaptured','closeKeepsMenuBar','reopenWorks','loginStartupPolicyLaunchedContainer','containersSurviveGUIExit','frontendReachableAfterGUIExit']:
        assert report[key] is True,key
finally:
    cli('autostart',hello['id'],'off',check=False)
    cli('login','off',check=False)
    cli('close',hello['id'],'--force',check=False)
    cli('forget',hello['id'],check=False)
if 'report' in locals():
    report['startupPreferencesRestoredOff']=not any(r['autoStart'] for r in json.loads(cli('list')))
    report['loginItemAfterCleanup']=cli('login-status').strip()
    (OUT/'native-ui.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False,indent=2))
