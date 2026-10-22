#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build --arch x86_64 --build-tests
BIN_DIR="$(swift build --arch x86_64 --show-bin-path)"
# Swift Build 使用目標名稱；舊版 SwiftPM 使用套件測試名稱。
TEST_BUNDLE="$BIN_DIR/LightboxNativePackageTests.xctest"
if [[ ! -d "$TEST_BUNDLE" ]]; then TEST_BUNDLE="$BIN_DIR/LightboxNativeTests.xctest"; fi
TEST_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TEST_BUNDLE/Contents/Info.plist")"
FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TEST_LIBRARIES="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
HOST_DIR="$(mktemp -d /tmp/LightboxIntelTests.XXXXXX)"
trap 'rm -rf "$HOST_DIR"' EXIT

# Some Xcode releases ship ARM-only SwiftPM test helpers. Load the Intel test
# bundle in an Intel process, using the generated Swift Testing entry point.
cat > "$HOST_DIR/host.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!bundle) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    int (*entry)(int, char **) = dlsym(bundle, "main");
    if (!entry) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    return entry(argc - 1, argv + 1);
}
C
xcrun clang -arch x86_64 -mmacosx-version-min=13.0 "$HOST_DIR/host.c" -o "$HOST_DIR/host"
file "$HOST_DIR/host"
DYLD_FRAMEWORK_PATH="$FRAMEWORKS${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
DYLD_LIBRARY_PATH="$TEST_LIBRARIES${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$HOST_DIR/host" "$TEST_BUNDLE/Contents/MacOS/$TEST_EXECUTABLE" \
    --testing-library swift-testing "$@"
