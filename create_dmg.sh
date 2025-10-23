#!/bin/bash

# Create installer DMG for Battery Monitor
# This script mirrors the GitHub Actions workflow for local testing

set -e

APP_BUNDLE=".build/debug/Battery Monitor.app"
DMG_NAME="BatteryMonitor.dmg"
STAGING_DIR="dmg_staging"
VOLUME_NAME="Battery Monitor Installer"

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE"
    echo "Run './create_app_bundle.sh' first."
    exit 1
fi

echo "Creating installer DMG..."

# Clean up any previous staging directory
rm -rf "$STAGING_DIR"
rm -f "$DMG_NAME" temp.dmg

# Create staging directory with proper installer layout
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"

# Create symlink to Applications folder for easy drag-and-drop install
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating temporary DMG..."

# Create temporary DMG
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  temp.dmg

# Mount the temporary DMG
echo "Mounting DMG to configure layout..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen temp.dmg | \
            awk '/^\/dev/ {print $3}')

# Set custom icon positions and window settings
echo "Configuring Finder window layout..."
osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {400, 100, 900, 450}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    set position of item "Battery Monitor.app" of container window to {125, 150}
    set position of item "Applications" of container window to {375, 150}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
EOF

# Sync and unmount
echo "Finalizing DMG..."
sync
hdiutil detach "$MOUNT_DIR"

# Convert to compressed read-only DMG
hdiutil convert temp.dmg \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_NAME"

# Clean up
rm -f temp.dmg
rm -rf "$STAGING_DIR"

# Create checksum
shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256"

# Show results
ls -lh "$DMG_NAME"
echo ""
echo "✓ DMG installer created: $DMG_NAME"
echo "✓ Checksum created: ${DMG_NAME}.sha256"
echo ""
echo "The DMG contains:"
echo "  - Battery Monitor.app"
echo "  - Applications folder symlink (for easy installation)"
echo ""
echo "To test: open $DMG_NAME"
