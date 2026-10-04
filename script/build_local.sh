#!/usr/bin/env bash
# Build an isolated local app without stopping or replacing the installed Lightbox.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
SDK="${LIGHTBOX_BUILD_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK" ]]; then SDK="$(xcrun --show-sdk-path)"; fi
swift build -c release --sdk "$SDK"
BIN_DIR="$(swift build -c release --sdk "$SDK" --show-bin-path)"
APP="$ROOT_DIR/dist/Lightbox Local.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LightboxNative" "$APP/Contents/MacOS/LightboxLocalNative"
cp "$ROOT_DIR/Sources/LightboxNative/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ -d "$BIN_DIR/LightboxNative_LightboxNative.bundle" ]]; then
    ditto "$BIN_DIR/LightboxNative_LightboxNative.bundle" "$APP/Contents/Resources/LightboxNative_LightboxNative.bundle"
fi
python3 - "$APP" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
info={
 'CFBundleExecutable':'LightboxLocalNative',
 'CFBundleIdentifier':'io.github.a11oydyyy.Lightbox.local',
 'CFBundleName':'Lightbox Local',
 'CFBundleDisplayName':'Lightbox Local',
 'CFBundleShortVersionString':'2.0.6-local.2',
 'CFBundleVersion':'120',
 'CFBundleIconFile':'AppIcon',
 'CFBundlePackageType':'APPL',
 'LSMinimumSystemVersion':'15.0',
 'NSHighResolutionCapable':True,
 'NSPrincipalClass':'NSApplication',
 'NSAppleEventsUsageDescription':'Lightbox asks Finder to restore images from the system Trash.',
 'UTExportedTypeDeclarations':[{
  'UTTypeIdentifier':'io.github.a11oydyyy.lightbox.internal-asset-drag',
  'UTTypeDescription':'Lightbox Internal Asset Drag',
  'UTTypeConformsTo':['public.data'],
 }],
}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
codesign --force --sign - --identifier io.github.a11oydyyy.Lightbox.local "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
