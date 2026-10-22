#!/usr/bin/env bash
# Records which source a build came from, so a test report can name the exact
# binary it tested.
#
#   script/build_provenance.sh             print the values for the working tree
#   script/build_provenance.sh --check APP compare APP's recorded source with the working tree
#
# The source digest covers every tracked or untracked (not ignored) file under
# Sources/ plus Package.swift and Package.resolved, as they are on disk, so
# uncommitted changes are part of it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source_digest() {
    git ls-files -z --cached --others --exclude-standard -- Sources Package.swift Package.resolved |
        python3 -c '
import hashlib, os, sys
paths = sorted(p for p in sys.stdin.buffer.read().decode().split("\0") if p and os.path.isfile(p))
digest = hashlib.sha256()
for path in paths:
    digest.update(path.encode() + b"\0")
    with open(path, "rb") as f:
        digest.update(hashlib.sha256(f.read()).digest())
print(digest.hexdigest())
'
}

commit="$(git rev-parse --short=12 HEAD)"
if [[ -n "$(git status --porcelain -- Sources Package.swift Package.resolved)" ]]; then dirty=true; else dirty=false; fi
digest="$(source_digest)"

if [[ "${1:-}" == "--check" ]]; then
    plist="${2:?usage: build_provenance.sh --check App.app}/Contents/Info.plist"
    recorded="$(/usr/libexec/PlistBuddy -c 'Print :LightboxSourceDigest' "$plist" 2>/dev/null || true)"
    printf 'app:          %s (commit %s, uncommitted changes: %s, built %s)\n' "$recorded" \
        "$(/usr/libexec/PlistBuddy -c 'Print :LightboxGitCommit' "$plist" 2>/dev/null || echo '?')" \
        "$(/usr/libexec/PlistBuddy -c 'Print :LightboxGitDirty' "$plist" 2>/dev/null || echo '?')" \
        "$(/usr/libexec/PlistBuddy -c 'Print :LightboxBuildDate' "$plist" 2>/dev/null || echo '?')"
    printf 'working tree: %s (commit %s, uncommitted changes: %s)\n' "$digest" "$commit" "$dirty"
    if [[ "$recorded" == "$digest" ]]; then echo "match"; else echo "different"; exit 1; fi
    exit 0
fi

printf 'LIGHTBOX_GIT_COMMIT=%s\n' "$commit"
printf 'LIGHTBOX_GIT_DIRTY=%s\n' "$dirty"
printf 'LIGHTBOX_SOURCE_DIGEST=%s\n' "$digest"
printf 'LIGHTBOX_BUILD_DATE=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
