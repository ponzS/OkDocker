#!/usr/bin/env python3
"""Stage an allowlisted Linux build. Does not inspect keys or production data.

Default: isolated runtime fixture in OkDocker Application Support. --install: write deployment
configuration to the source project; does NOT stop/restart the host service.
"""
import argparse
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('source', type=Path)
p.add_argument('--destination', type=Path)
p.add_argument('--install', action='store_true')
p.add_argument('--android', action='store_true')
p.add_argument('--replace', action='store_true', help='explicitly replace an existing installed manifest')
p.add_argument('--port', type=int)
a = p.parse_args()
source = a.source.expanduser().resolve()
if a.install and a.destination:
    p.error('--install cannot be combined with --destination')
destination = source if a.install else (a.destination or Path.home() / 'Library/Application Support/OkDocker/Validation/Pipeline/app').expanduser().resolve()
if a.install and (destination / 'okdocker.json').exists() and not a.replace:
    p.error('okdocker.json already exists; inspect it first, then use --replace if intentional')
destination.mkdir(parents=True, exist_ok=True)
(destination / 'data').mkdir(exist_ok=True)
staging = destination / '.okdocker-build'
staging.mkdir(exist_ok=True)
for relative in ['server/src', 'server/Cargo.toml', 'server/Cargo.lock']:
    src, dst = source / relative, staging / relative
    if src.is_symlink() or not src.resolve().is_relative_to(source):
        raise SystemExit('Refusing source symlink escape: ' + relative)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst)
shutil.copy2(HERE / 'Dockerfile', staging / 'Dockerfile')
# These are runtime assets, not part of the image. Never copy apikey.md or data.
if not a.install:
    for relative in ['public', 'server/resources']:
        dst = destination / relative
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(source / relative, dst, symlinks=True)
    (destination / 'server/src').mkdir(parents=True, exist_ok=True)
if (ROOT / 'Resources/AppIcon.png').exists():
    shutil.copy2(ROOT / 'Resources/AppIcon.png', destination / '.okdocker-icon.png')
port = a.port or (17865 if a.install else 18865)
mount = str(destination) if a.install else '/workspace'
manifest = {
    'schemaVersion': 1, 'id': 'xhs-liushuixian',
    'name': '小红书流水线' if a.install else '流水线 · 容器验证',
    'icon': '.okdocker-icon.png', 'autoStart': False,
    'hostAndroidDevices': a.android,
    'frontend': {'service': 'pipeline', 'directory': 'public', 'path': '/', 'hostPort': port, 'containerPort': 17865},
    'backend': {'service': 'pipeline', 'directory': 'server', 'path': '/health', 'hostPort': port, 'containerPort': 17865},
    'services': {'pipeline': {
        'build': {'context': '.okdocker-build', 'dockerfile': 'Dockerfile'},
        'workingDirectory': mount,
        'environment': {'TZ': 'Asia/Shanghai', 'XHS_ROOT': mount,
                        'XHS_DATA_DIR': mount + '/data', 'XHS_API_KEY_FILE': mount + '/apikey.md',
                        'XHS_HOST': '0.0.0.0', 'XHS_PORT': '17865'},
        'mounts': [{'source': '.', 'target': mount, 'readOnly': False}]
    }}
}
(destination / 'okdocker.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
if a.install:
    ignore = source / '.gitignore'
    text = ignore.read_text() if ignore.exists() else ''
    if '/.okdocker-build/' not in text.splitlines():
        with ignore.open('a') as f:
            f.write('\n# OkDocker staged build sources (no data or keys)\n/.okdocker-build/\n')
print(json.dumps({'applicationDirectory': str(destination), 'port': port,
                  'android': a.android, 'productionDataCopied': False,
                  'keysCopied': False, 'hostServiceChanged': False}, ensure_ascii=False))
