#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build --arch x86_64 --build-tests
BIN_DIR="$(swift build --arch x86_64 --show-bin-path)"
FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
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
    "$HOST_DIR/host" "$BIN_DIR/LightboxNativePackageTests.xctest/Contents/MacOS/LightboxNativePackageTests" \
    --testing-library swift-testing "$@"
