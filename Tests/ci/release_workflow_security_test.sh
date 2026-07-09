#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

workflow=".github/workflows/release.yml"
failed=0

while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+) ]]; then
    action_ref="${BASH_REMATCH[1]}"
    if [[ ! "$action_ref" =~ @[0-9a-fA-F]{40}$ ]]; then
      echo "workflow action must be pinned to a full commit SHA: $action_ref" >&2
      failed=1
    fi
  fi
done < "$workflow"

if grep -Eq 'runs-on:[[:space:]]*macos-latest' "$workflow"; then
  echo "release workflow must pin the macOS runner instead of macos-latest" >&2
  failed=1
fi

if grep -Eq 'xcode-version:[[:space:]]*latest-stable' "$workflow"; then
  echo "release workflow must pin the Xcode version instead of latest-stable" >&2
  failed=1
fi

if awk '
  /^jobs:/ { in_jobs = 1 }
  /^permissions:/ && !in_jobs { found_global_permissions = 1 }
  END { exit found_global_permissions ? 0 : 1 }
' "$workflow"; then
  echo "release workflow must scope write permissions to the release job" >&2
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "release_workflow_security_test.sh: PASS"
