set shell := ["bash", "-euo", "pipefail", "-c"]

test:
    swift test

lint:
    if command -v swiftlint >/dev/null; then swiftlint lint --config .swiftlint.yml --quiet; else echo "swiftlint not installed; skipping"; fi
    ruby -e "require 'yaml'; YAML.load_file('.github/workflows/release.yml'); YAML.load_file('project.yml'); puts 'yaml: OK'"
    plutil -lint SupportFiles/Info.plist SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist

build-dmg:
    #!/usr/bin/env bash
    version="${VERSION:-dev}"
    configuration="${CONFIGURATION:-release}"
    artifact_dir="${ARTIFACT_DIR:-.build/artifacts}"
    app_dir="${artifact_dir}/BatteryMonitor.app"
    dmg_staging="${artifact_dir}/dmg_staging"
    dmg_path="${artifact_dir}/BatteryMonitor.dmg"

    swift build -c "$configuration" --product BatteryMonitor
    swift build -c "$configuration" --product BatteryMonitorPrivilegedHelper
    build_dir="$(swift build -c "$configuration" --show-bin-path)"

    rm -rf "$app_dir" "$dmg_staging" "$dmg_path" "${dmg_path}.sha256"
    mkdir -p \
      "$app_dir/Contents/MacOS" \
      "$app_dir/Contents/Resources" \
      "$app_dir/Contents/Library/LaunchDaemons"

    cp "${build_dir}/BatteryMonitor" "$app_dir/Contents/MacOS/BatteryMonitor"
    cp "${build_dir}/BatteryMonitorPrivilegedHelper" "$app_dir/Contents/MacOS/BatteryMonitorPrivilegedHelper"
    cp SupportFiles/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
    cp SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist \
      "$app_dir/Contents/Library/LaunchDaemons/com.swacktools.batterymonitor.helper.plist"

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
      <key>CFBundleIconName</key>
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
        "$app_dir/Contents/MacOS/BatteryMonitorPrivilegedHelper"
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

run:
    swift run BatteryMonitor
