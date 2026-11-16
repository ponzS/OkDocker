#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p artifacts dist Resources
if command -v go >/dev/null 2>&1; then
  (cd Resources/Android/relay && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags '-s -w' -o ../adb-relay .)
fi
test -f Resources/Android/adb-relay
swift build -c release
BIN="$(swift build -c release --show-bin-path)/OkDocker"
if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift Resources/AppIcon.png
  mkdir -p artifacts/AppIcon.iconset
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "artifacts/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size*2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "artifacts/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns artifacts/AppIcon.iconset -o Resources/AppIcon.icns
fi
APP="$ROOT/dist/OkDocker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OkDocker"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/AppIcon.png "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/Android"
cp -R Resources/Android "$APP/Contents/Resources/Android"
cp CONFIGURATION.md README.md LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/zh/docs"
cp -R zh/. "$APP/Contents/Resources/zh/"
rm -rf "$APP/Contents/Resources/docs" "$APP/Contents/Resources/examples"
cp -R docs examples "$APP/Contents/Resources/"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'dev.okdocker.app','CFBundleName':'OkDocker',
      'CFBundleDisplayName':'OkDocker','CFBundleExecutable':'OkDocker','CFBundlePackageType':'APPL',
      'CFBundleShortVersionString':'0.3.0','CFBundleVersion':'4','CFBundleIconFile':'AppIcon',
      'LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,
      'LSApplicationCategoryType':'public.app-category.developer-tools',
      'NSHumanReadableCopyright':'OkDocker contributors · MIT',
      'NSLocalNetworkUsageDescription':'OkDocker opens an approved per-app LAN gateway, connects to local container networks, and uses shared ADB.'}, f)
PY
codesign --force --sign "${OKDOCKER_SIGNING_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
