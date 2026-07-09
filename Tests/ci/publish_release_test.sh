#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script_path="$repo_root/scripts/publish_release.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

notes_file="$tmpdir/release-notes.md"
printf 'upgrade for OSx 27\n' > "$notes_file"

gh_log="$tmpdir/gh.log"
cat > "$tmpdir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"

if [[ "$1" == "release" && "$2" == "view" ]]; then
  if [[ "${RELEASE_EXISTS:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi

exit 0
EOF
chmod +x "$tmpdir/gh"

run_case() {
  local mode="$1"
  : > "$gh_log"

  RELEASE_EXISTS="$mode" \
  GH_LOG="$gh_log" \
  GH_BIN="$tmpdir/gh" \
  TAG="v1.1.0" \
  RELEASE_TITLE="Battery Monitor 1.1.0" \
  RELEASE_TARGET="abc123" \
  RELEASE_NOTES_FILE="$notes_file" \
  "$script_path" \
    BatteryMonitor.dmg \
    BatteryMonitor.dmg.sha256 \
    BatteryMonitorCLI.tar.gz \
    BatteryMonitorCLI.tar.gz.sha256
}

run_case 0
if ! grep -q '^release create v1.1.0 --title Battery Monitor 1.1.0 --notes-file .* --latest --target abc123 ' "$gh_log"; then
  echo "expected create path for a missing release"
  cat "$gh_log"
  exit 1
fi

run_case 1
if ! grep -q '^release edit v1.1.0 --title Battery Monitor 1.1.0 --notes-file .* --latest --target abc123$' "$gh_log"; then
  echo "expected edit path for an existing release"
  cat "$gh_log"
  exit 1
fi

if ! grep -q '^release upload v1.1.0 --clobber BatteryMonitor.dmg ' "$gh_log"; then
  echo "expected upload path for an existing release"
  cat "$gh_log"
  exit 1
fi

if grep -q '^release create v1.1.0 ' "$gh_log"; then
  echo "did not expect create path when release already exists"
  cat "$gh_log"
  exit 1
fi

echo "publish_release_test.sh: PASS"
