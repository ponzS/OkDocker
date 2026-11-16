#!/usr/bin/env python3
"""Install a verified local build atomically, preserving the previous bundle.

Separate from build-app.sh: packaging must not silently replace a user's installed
app or restart its UI. This explicit command does that; it never starts/stops VMs,
changes login preferences, clears quarantine, or requests elevated privileges.
"""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, shutil, subprocess, time, uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--no-open',action='store_true')
a=p.parse_args()
source=ROOT/'dist/OkDocker.app'
base=pathlib.Path('/Applications') if os.access('/Applications',os.W_OK) else pathlib.Path.home()/'Applications'
base.mkdir(parents=True,exist_ok=True);target=base/'OkDocker.app'
def info(bundle):
 with (bundle/'Contents/Info.plist').open('rb') as f:return plistlib.load(f)
def verify(bundle):subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(bundle)],check=True)
version=info(source)['CFBundleShortVersionString'];verify(source)
if info(source)['CFBundleIdentifier']!='dev.okdocker.app':raise SystemExit('Unexpected source bundle identifier')
if target.is_symlink():raise SystemExit('Installed path is a symlink; refusing implicit overwrite')
if target.exists() and info(target)['CFBundleIdentifier']!='dev.okdocker.app':raise SystemExit('Target belongs to another application')
# NSRunningApplication terminates only GUI instances; no AX permission, shell
# hooks, bridge helpers, container processes or shared runtimes are targeted.
js='''ObjC.import('AppKit');var apps=$.NSRunningApplication.runningApplicationsWithBundleIdentifier('dev.okdocker.app');
for(var i=0;i<apps.count;i++){var app=apps.objectAtIndex(i);if(ObjC.unwrap(app.bundleURL.path)===TARGET){if(!app.terminate)throw new Error('Quit declined');}}'''.replace('TARGET',json.dumps(str(target)))
subprocess.run(['/usr/bin/osascript','-l','JavaScript','-e',js],check=True)
time.sleep(.5)
processes=subprocess.check_output(['/bin/ps','-axo','comm='],text=True).splitlines()
if str(target/'Contents/MacOS/OkDocker') in [s.strip() for s in processes]:raise SystemExit('Please quit the installed OkDocker before updating')
backup=None
if target.exists():
 stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
 backup=ROOT/'artifacts/install-backup'/f"OkDocker-{info(target)['CFBundleShortVersionString']}-{stamp}.app"
 backup.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['/usr/bin/ditto',str(target),str(backup)],check=True)
stage=base/('.OkDocker-install-'+uuid.uuid4().hex+'.app');previous=base/('.OkDocker-previous-'+uuid.uuid4().hex+'.app')
try:
 subprocess.run(['/usr/bin/ditto',str(source),str(stage)],check=True);verify(stage)
 if target.exists():os.rename(target,previous)
 try:
  os.rename(stage,target);verify(target)
 except Exception:
  if target.exists():shutil.rmtree(target)
  if previous.exists():os.rename(previous,target)
  raise
finally:
 if stage.exists():shutil.rmtree(stage)
 if previous.exists():shutil.rmtree(previous)
subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(target)],check=True)
if not a.no_open:subprocess.run(['/usr/bin/open',str(target)],check=True)
report={'installedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'application':str(target),'version':version,'previousBundleBackup':str(backup) if backup else None,
 'signatureVerified':True,'executableMatchesBuild':hashlib.sha256((source/'Contents/MacOS/OkDocker').read_bytes()).digest()==hashlib.sha256((target/'Contents/MacOS/OkDocker').read_bytes()).digest(),
 'launchRequested':not a.no_open,'loginPreferencesChanged':False,'containersStartedByInstaller':False}
(ROOT/'artifacts/apple-install.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False,indent=2))
