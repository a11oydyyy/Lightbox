#!/usr/bin/env bash
# Install with: cp script/pre-push-privacy.sh "$(git rev-parse --git-path hooks/pre-push)"
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
exec python3 "$root/script/check_release_privacy.py" pre-push
