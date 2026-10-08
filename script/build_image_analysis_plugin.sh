#!/usr/bin/env bash
# Produce an optional plugin package. Never install it into the native app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/script/build_toolchain.sh"
lightbox_configure_toolchain "$ROOT_DIR"
swift build --product LightboxImageAnalysisPlugin -c release "${LIGHTBOX_SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build --product LightboxImageAnalysisPlugin -c release "${LIGHTBOX_SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/lightbox-analysis.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
PACKAGE="$STAGING/图片分析.lightboxplugin"
APP="$PACKAGE/图片分析.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LightboxImageAnalysisPlugin" "$APP/Contents/MacOS/LightboxImageAnalysisPlugin"
cp "$ROOT_DIR/Sources/LightboxNative/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
python3 - "$PACKAGE" <<'PY'
import json, plistlib, sys
from pathlib import Path
package = Path(sys.argv[1])
identifier = 'io.github.a11oydyyy.Lightbox.ImageAnalysis'
manifest = dict(apiVersion=1, identifier=identifier, name='图片分析', version='1.0.0', application='图片分析.app', symbol='sparkles')
(package/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
info = dict(CFBundleExecutable='LightboxImageAnalysisPlugin', CFBundleIdentifier=identifier,
            CFBundleName='图片分析', CFBundleShortVersionString='1.0.0', CFBundleVersion='1',
            CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', LSMinimumSystemVersion='27.0',
            NSPrincipalClass='NSApplication', NSHighResolutionCapable=True,
            CFBundleDocumentTypes=[dict(CFBundleTypeName='Images', LSItemContentTypes=['public.image'],
                                       CFBundleTypeRole='Viewer', LSHandlerRank='None')])
with (package/'图片分析.app/Contents/Info.plist').open('wb') as output: plistlib.dump(info, output)
PY
codesign --force --sign "${LIGHTBOX_CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
OUTPUT="$ROOT_DIR/dist/Plugins/图片分析.lightboxplugin"
mkdir -p "$ROOT_DIR/dist/Plugins"
rm -rf "$OUTPUT"
ditto "$PACKAGE" "$OUTPUT"
# Verify the delivered copy too: iCloud may add Finder display metadata.
for attempt in 1 2 3; do
    if xattr -p com.apple.FinderInfo "$OUTPUT/图片分析.app" >/dev/null 2>&1; then
        xattr -d com.apple.FinderInfo "$OUTPUT/图片分析.app"
    fi
    if codesign --verify --deep --strict "$OUTPUT/图片分析.app"; then
        break
    fi
    if [[ "$attempt" == 3 ]] || ! xattr -p com.apple.FinderInfo "$OUTPUT/图片分析.app" >/dev/null 2>&1; then
        exit 1
    fi
done
# Zip excludes Finder/resource metadata so distribution remains stable in iCloud.
ARCHIVE="$OUTPUT.zip"
rm -f "$ARCHIVE"
ditto -c -k --norsrc --keepParent "$OUTPUT" "$ARCHIVE"
printf '%s\n%s\n' "$OUTPUT" "$ARCHIVE"
