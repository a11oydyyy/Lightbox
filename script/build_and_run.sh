#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LightboxNative"
APP_BUNDLE_NAME="Lightbox"
BUNDLE_ID="io.github.a11oydyyy.Lightbox"
MIN_SYSTEM_VERSION="15.0"
VERSION="1.3.4"
BUILD_NUMBER="99"
BUILD_ARCH_ARGS=()

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME.app"
INSTALL_APP_BUNDLE="/Applications/$APP_BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Sources/LightboxNative/Resources/AppIcon.icns"
PACKAGE_ZIP="$DIST_DIR/Lightbox-v$VERSION.zip"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

configure_compatibility_app() {
  APP_BUNDLE_NAME="Lightbox 13"
  BUNDLE_ID="io.github.a11oydyyy.Lightbox13"
  MIN_SYSTEM_VERSION="13.0"
  BUILD_ARCH_ARGS=(--arch arm64 --arch x86_64)
  APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME.app"
  INSTALL_APP_BUNDLE="/Applications/$APP_BUNDLE_NAME.app"
  APP_CONTENTS="$APP_BUNDLE/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_RESOURCES="$APP_CONTENTS/Resources"
  APP_BINARY="$APP_MACOS/$APP_NAME"
  INFO_PLIST="$APP_CONTENTS/Info.plist"
  PACKAGE_ZIP="$DIST_DIR/Lightbox-Intel-x86-v$VERSION.zip"
}

build_bundle() {
  local configuration="${1:-debug}"
  local stop_running="${2:-true}"
  local build_args=()

  if [ "$configuration" = "release" ]; then
    build_args=(-c release)
  fi

  if [ "${#BUILD_ARCH_ARGS[@]}" -gt 0 ]; then
    build_args+=("${BUILD_ARCH_ARGS[@]}")
  fi

  if [ "$stop_running" = "true" ]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  fi

  if [ "${#build_args[@]}" -gt 0 ]; then
    swift build "${build_args[@]}"
    BUILD_BINARY="$(swift build "${build_args[@]}" --show-bin-path)/$APP_NAME"
  else
    swift build
    BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  mkdir -p "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  if [ -f "$APP_ICON" ]; then
    cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleName</key>
  <string>Lightbox</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Lightbox asks Finder to restore images from the system Trash.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

sign_app_bundle() {
  local bundle="${1:-$APP_BUNDLE}"
  /usr/bin/xattr -cr "$bundle" >/dev/null 2>&1 || true
  /usr/bin/codesign --remove-signature "$bundle" >/dev/null 2>&1 || true
  /usr/bin/codesign --force --sign "${LIGHTBOX_CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$bundle"
  /usr/bin/xattr -cr "$bundle" >/dev/null 2>&1 || true
}

install_app_bundle() {
  sign_app_bundle "$APP_BUNDLE"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  rm -rf "$INSTALL_APP_BUNDLE"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_APP_BUNDLE"
  sign_app_bundle "$INSTALL_APP_BUNDLE"
  "$LSREGISTER" -f "$INSTALL_APP_BUNDLE" >/dev/null 2>&1 || true
  rm -rf "$APP_BUNDLE"
}

open_app() {
  install_app_bundle
  /usr/bin/open -n "$INSTALL_APP_BUNDLE"
}

package_app() {
  build_bundle release false
  sign_app_bundle "$APP_BUNDLE"
  rm -f "$PACKAGE_ZIP"
  (cd "$DIST_DIR" && /usr/bin/ditto -c -k --norsrc --keepParent "$APP_BUNDLE_NAME.app" "$PACKAGE_ZIP")
  rm -rf "$APP_BUNDLE"
  echo "$PACKAGE_ZIP"
}

case "$MODE" in
  run)
    build_bundle release
    open_app
    ;;
  run13)
    configure_compatibility_app
    build_bundle release
    open_app
    ;;
  --package|package)
    package_app
    ;;
  package13|--package13)
    configure_compatibility_app
    package_app
    ;;
  --debug|debug)
    build_bundle debug
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_bundle release
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_bundle release
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --diagnose|diagnose)
    build_bundle release
    open_app
    echo "Streaming Lightbox diagnostics. Reproduce the issue now." >&2
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --recent-logs|recent-logs)
    SINCE="${2:-10m}"
    /usr/bin/log show --last "$SINCE" --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --performance-logs|performance-logs|perf-logs)
    SINCE="${2:-10m}"
    /usr/bin/log show --last "$SINCE" --info --style compact --predicate "subsystem == \"$BUNDLE_ID\" && (category == \"ImageDecode\" || category == \"DirectoryScan\" || category == \"LibraryLoading\" || category == \"Index\")"
    ;;
  --verify|verify)
    build_bundle release
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|run13|package|package13|--debug|--logs|--telemetry|--diagnose|--recent-logs [10m]|--performance-logs [10m]|--verify]" >&2
    exit 2
    ;;
esac
