#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

appicon_json="SupportFiles/Assets.xcassets/AppIcon.appiconset/Contents.json"
icns_path="SupportFiles/AppIcon.icns"
build_script="scripts/build_dmg.sh"

python3 - "$appicon_json" <<'PY'
import json
import sys
from pathlib import Path

catalog_path = Path(sys.argv[1])
catalog = json.loads(catalog_path.read_text())
images = catalog.get("images", [])
missing = [
    f"{image.get('idiom')} {image.get('size')}@{image.get('scale')}"
    for image in images
    if not image.get("filename")
]

if missing:
    print("AppIcon catalog entries missing filenames:", ", ".join(missing), file=sys.stderr)
    sys.exit(1)

for image in images:
    icon_path = catalog_path.parent / image["filename"]
    if not icon_path.is_file():
        print(f"Missing icon file: {icon_path}", file=sys.stderr)
        sys.exit(1)
PY

if [[ ! -f "$icns_path" ]]; then
  echo "Missing app icon resource: $icns_path" >&2
  exit 1
fi

if ! grep -q "CFBundleIconFile" "$build_script"; then
  echo "build_dmg.sh must set CFBundleIconFile" >&2
  exit 1
fi

if ! grep -q "AppIcon.icns" "$build_script"; then
  echo "build_dmg.sh must copy AppIcon.icns into the app bundle" >&2
  exit 1
fi
