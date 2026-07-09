#!/usr/bin/env bash
set -euo pipefail

version="${VERSION:-dev}"
configuration="${CONFIGURATION:-release}"
artifact_dir="${ARTIFACT_DIR:-.build/artifacts}"
build_dir=".build/arm64-apple-macosx/${configuration}"
app_dir="${artifact_dir}/BatteryMonitor.app"
dmg_staging="${artifact_dir}/dmg_staging"
dmg_path="${artifact_dir}/BatteryMonitor.dmg"

swift build -c "$configuration" --product BatteryMonitor

rm -rf "$app_dir" "$dmg_staging" "$dmg_path"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

cp "${build_dir}/BatteryMonitor" "$app_dir/Contents/MacOS/BatteryMonitor"
cp "SupportFiles/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>BatteryMonitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.swacktools.batterymonitor</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Battery Monitor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$app_dir/Contents/MacOS/BatteryMonitor"
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$app_dir"
fi

mkdir -p "$dmg_staging"
cp -R "$app_dir" "$dmg_staging/"
ln -s /Applications "$dmg_staging/Applications"

hdiutil create \
  -volname "Battery Monitor Installer" \
  -srcfolder "$dmg_staging" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path"

shasum -a 256 "$dmg_path" > "${dmg_path}.sha256"
echo "$dmg_path"
