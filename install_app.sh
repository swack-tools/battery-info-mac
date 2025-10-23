#!/bin/bash

# Install Battery Monitor to Applications folder

set -e

APP_BUNDLE=".build/debug/Battery Monitor.app"
DEST="/Applications/Battery Monitor.app"

# Check if bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found. Run './create_app_bundle.sh' first."
    exit 1
fi

# Kill running instance if any
killall "Battery Monitor" 2>/dev/null || true

# Remove old version if exists
if [ -d "$DEST" ]; then
    echo "Removing old version..."
    rm -rf "$DEST"
fi

# Copy to Applications
echo "Installing to /Applications..."
cp -r "$APP_BUNDLE" "$DEST"

echo "✓ Battery Monitor installed to /Applications"
echo "  Launch from Applications or Spotlight"
echo "  Launch at Login will now work properly!"
