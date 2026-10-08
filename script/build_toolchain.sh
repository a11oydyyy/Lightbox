#!/usr/bin/env bash
# Shared SDK selection and Mach-O validation for application bundles.

lightbox_configure_toolchain() {
  local root_dir="$1"
  local package_args=(--package-path "$root_dir")
  if [[ -n "${LIGHTBOX_BUILD_CACHE_DIR:-}" ]]; then
    package_args+=(--scratch-path "$LIGHTBOX_BUILD_CACHE_DIR")
  fi
  LIGHTBOX_SDK="${LIGHTBOX_BUILD_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
  if [[ ! -d "$LIGHTBOX_SDK" ]]; then
    printf 'macOS SDK not found: %s\n' "$LIGHTBOX_SDK" >&2
    return 1
  fi
  LIGHTBOX_SDK_VERSION="$(python3 - "$LIGHTBOX_SDK/SDKSettings.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)['Version'])
PY
)"
  LIGHTBOX_DEPLOYMENT_VERSION="$(swift package "${package_args[@]}" dump-package | python3 -c '
import json, sys
print(next(p["version"] for p in json.load(sys.stdin)["platforms"] if p["platformName"] == "macos"))
')"
  # Swift Build in CLT 27 stamps the deployment target into the SDK field.
  # Supply both real values to the linker so AppKit enables current SDK behavior.
  LIGHTBOX_SWIFT_BUILD_ARGS=(
    "${package_args[@]}" --sdk "$LIGHTBOX_SDK"
    -Xlinker -platform_version -Xlinker macos
    -Xlinker "$LIGHTBOX_DEPLOYMENT_VERSION" -Xlinker "$LIGHTBOX_SDK_VERSION"
  )
}

lightbox_verify_build_version() {
  python3 - "$1" "$LIGHTBOX_DEPLOYMENT_VERSION" "$LIGHTBOX_SDK_VERSION" <<'PY'
import re, subprocess, sys

binary, minimum, sdk = sys.argv[1:]
output = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
def version(value):
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))
minimums = re.findall(r'^\s*minos\s+([0-9.]+)\s*$', output, re.M)
sdks = re.findall(r'^\s*sdk\s+([0-9.]+)\s*$', output, re.M)
if (not sdks or len(minimums) != len(sdks)
        or any(version(value) != version(minimum) for value in minimums)
        or any(version(value) != version(sdk) for value in sdks)):
    sys.exit(f'Unexpected deployment/SDK version in {binary}:\n{output}')
print(f'Verified {len(sdks)} architecture(s): minimum macOS {minimum}, SDK {sdk}')
PY
}
