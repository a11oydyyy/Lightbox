#!/usr/bin/env bash
# Rebuild the app icon from script/icon/: silhouette (gen.py) -> shading (restyle.py) -> iconset -> icns.
# Usage: script/build_app_icon.sh [output.icns]   (default: Sources/LightboxNative/Resources/AppIcon.icns)
# BLENDER overrides the Blender binary; ICON_WORK_DIR keeps the intermediate images there.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$ROOT_DIR/script/icon"
OUTPUT="${1:-$ROOT_DIR/Sources/LightboxNative/Resources/AppIcon.icns}"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

if [[ ! -x "$BLENDER" ]]; then
    printf 'Blender not found at %s (set BLENDER).\n' "$BLENDER" >&2
    exit 1
fi

if [[ -n "${ICON_WORK_DIR:-}" ]]; then
    WORK="$ICON_WORK_DIR"
    mkdir -p "$WORK"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi

run_blender() {
    local script="$1"; shift
    "$BLENDER" -b --factory-startup --python-exit-code 1 -P "$ICON_DIR/$script" -- "$@" >"$WORK/${script%.py}.log" 2>&1 || {
        printf '%s failed:\n' "$script" >&2
        tail -20 "$WORK/${script%.py}.log" >&2
        exit 1
    }
}

run_blender gen.py "$WORK/silhouette.png"
run_blender restyle.py "$WORK/silhouette.png" "$WORK/icon_1024.png"
rm -rf "$WORK/AppIcon.iconset"
run_blender iconset.py "$WORK/icon_1024.png" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUTPUT"
printf 'Wrote %s\n' "$OUTPUT"
