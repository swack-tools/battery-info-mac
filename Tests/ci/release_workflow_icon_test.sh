#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

workflow=".github/workflows/release.yml"

if ! grep -q "SupportFiles/AppIcon.icns" "$workflow"; then
  echo "release workflow must copy SupportFiles/AppIcon.icns into the app bundle" >&2
  exit 1
fi

if ! grep -q "CFBundleIconFile" "$workflow"; then
  echo "release workflow must set CFBundleIconFile in the signed app bundle" >&2
  exit 1
fi

if ! grep -q "AppIcon" "$workflow"; then
  echo "release workflow must reference AppIcon" >&2
  exit 1
fi
