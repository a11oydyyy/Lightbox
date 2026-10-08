#!/usr/bin/env bash
# Update the fixed macOS test app without replacing the installed Lightbox.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VARIANT="${LIGHTBOX_LOCAL_VARIANT:-macos27}"
BUNDLE_ID="io.github.a11oydyyy.Lightbox.local"
APP_NAME="Lightbox Local"
if [[ -n "$VARIANT" ]]; then
    if [[ ! "$VARIANT" =~ ^[a-zA-Z0-9-]+$ ]]; then
        printf 'Local variant must contain only letters, digits, or hyphens.\n' >&2
        exit 1
    fi
    BUNDLE_ID="$BUNDLE_ID.$VARIANT"
    APP_NAME="$APP_NAME ($VARIANT)"
fi
SIGNING_IDENTITY="${LIGHTBOX_CODESIGN_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    # Resolve an exact certificate name or fingerprint before touching the app.
    # A missing identity must not silently fall back to a different app identity.
    SIGNING_IDENTITY="$(python3 - "$SIGNING_IDENTITY" <<'PY'
import re, subprocess, sys
requested = sys.argv[1]
identities = subprocess.run(
    ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
    check=True, capture_output=True, text=True,
).stdout
matches = []
for fingerprint, name in re.findall(r'\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\n]+)"', identities):
    if requested == name or requested.casefold() == fingerprint.casefold():
        matches.append(fingerprint)
if len(matches) != 1:
    sys.exit('未找到唯一有效的代码签名身份，请指定证书完整名称或指纹。')
print(matches[0])
PY
)"
fi
source "$ROOT_DIR/script/build_toolchain.sh"
lightbox_configure_toolchain "$ROOT_DIR"
swift build --product LightboxNative -c release "${LIGHTBOX_SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build --product LightboxNative -c release "${LIGHTBOX_SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
lightbox_verify_build_version "$BIN_DIR/LightboxNative"
APP="$ROOT_DIR/dist/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LightboxNative" "$APP/Contents/MacOS/LightboxLocalNative"
cp "$ROOT_DIR/Sources/LightboxNative/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ -d "$BIN_DIR/LightboxNative_LightboxNative.bundle" ]]; then
    ditto "$BIN_DIR/LightboxNative_LightboxNative.bundle" "$APP/Contents/Resources/LightboxNative_LightboxNative.bundle"
fi
python3 - "$APP" "$BUNDLE_ID" "$APP_NAME" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
info={
 'CFBundleExecutable':'LightboxLocalNative',
 'CFBundleIdentifier':sys.argv[2],
 'CFBundleName':sys.argv[3],
 'CFBundleDisplayName':sys.argv[3],
 'CFBundleShortVersionString':'2.0.8-local.1',
 'CFBundleVersion':'122',
 'CFBundleIconFile':'AppIcon',
 'CFBundlePackageType':'APPL',
 'LSMinimumSystemVersion':'15.0',
 'NSHighResolutionCapable':True,
 'NSPrincipalClass':'NSApplication',
 'NSAppleEventsUsageDescription':'Lightbox asks Finder to restore images from the system Trash.',
 'UTExportedTypeDeclarations':[{
  'UTTypeIdentifier':'io.github.a11oydyyy.lightbox.plugin-package',
  'UTTypeDescription':'Lightbox Plugin',
  'UTTypeConformsTo':['com.apple.package'],
  'UTTypeTagSpecification':{'public.filename-extension':['lightboxplugin']},
 },{
  'UTTypeIdentifier':'io.github.a11oydyyy.lightbox.internal-asset-drag',
  'UTTypeDescription':'Lightbox Internal Asset Drag',
  'UTTypeConformsTo':['public.data'],
 }],
}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_ARGUMENTS+=(--options runtime --timestamp=none)
fi
# iCloud can attach FinderInfo to a generated bundle while it is being signed.
# Remove only that display metadata; retain provenance and access attributes.
for attempt in 1 2 3; do
    if xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
        xattr -d com.apple.FinderInfo "$APP"
    fi
    if codesign "${SIGNING_ARGUMENTS[@]}" "$APP" && codesign --verify --strict "$APP"; then
        break
    fi
    if [[ "$attempt" == 3 ]] || ! xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
        exit 1
    fi
done
printf '%s\n' "$APP"
