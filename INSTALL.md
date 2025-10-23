# Battery Monitor - Installation Guide

## Requirements
- macOS 13.0 (Ventura) or later
- Apple Silicon (M1/M2/M3/M4) Mac

## Installation

1. **Download** `BatteryMonitor.dmg` (~200 KB)

2. **Open** the DMG file by double-clicking it

3. **Drag** `Battery Monitor.app` to your Applications folder
   - Or run it directly from the DMG

4. **Launch** Battery Monitor

   **IMPORTANT:** Since this app is not notarized by Apple, macOS will
   block it on first launch. You'll see an error saying the app is
   "damaged" or "from an unidentified developer."

   **To open the app, use ONE of these methods:**

   ### Method 1: Right-Click to Open (Recommended)

   - Right-click (or Control-click) on `Battery Monitor.app` in
     Applications
   - Select **Open** from the menu
   - Click **Open** in the dialog that appears
   - You only need to do this once; after that, it will open normally

   ### Method 2: Remove Quarantine Attribute (Advanced)

   - Open Terminal
   - Run: `xattr -cr /Applications/BatteryMonitor.app`
   - Then launch the app normally

   ### Method 3: System Settings

   - Try to open the app normally (it will be blocked)
   - Go to **System Settings → Privacy & Security**
   - Scroll down and click **Open Anyway** next to the Battery Monitor
     message
   - Click **Open** in the confirmation dialog

5. **Menu Bar Icon**
   - The battery percentage will appear in your menu bar
   - **Left-click**: View detailed battery information
   - **Right-click**: Quick menu (Refresh, Quit)

## Features

### Menu Bar
- 🔋 Real-time battery percentage display
- ⚡ Charging indicator
- 🔌 Plugged-in indicator

### Detailed View (Popover)
- **System Information**: Mac model, chip, RAM, CPU cores
- **Battery Status**: Percentage, charging state, time remaining
- **Battery Health**: Condition, health %, cycles, capacity, temperature
- **Capacity Analysis**: Design vs actual capacity comparison
- **Cell Diagnostics**: Cell voltages, disconnect counts
- **Battery Information**: Manufacturer, model, serial, chemistry
- **Charger Information**: Wattage, type, voltage, current
- **USB-C Power Delivery**: PD spec, roles, PDOs, capabilities
- **Advanced Diagnostics**: Internal resistance, gauge status,
  metrics
- **Display**: Brightness and power consumption
- **USB Ports**: Wake/sleep current
- **Power Management**: Low power mode, hibernation, scheduled events

### Features
- ✨ **Dark mode support** - Automatically adapts to system appearance
- 🎨 **Color-coded values** - Health, temperature, and status indicators
- 📊 **Collapsible sections** - Organize information efficiently
- ⚡ **Instant loading** - Pre-cached data for immediate display
- 🔄 **Auto-refresh** - Updates every 30 seconds
- 🎯 **Full-width headers** - Click anywhere to expand/collapse

## Uninstallation

1. **Quit** Battery Monitor (Right-click menu bar icon → Quit)
2. **Delete** from Applications folder
3. No configuration files to clean up

## Troubleshooting

### "Battery Monitor is damaged and can't be opened" error

This is a normal macOS security feature (Gatekeeper) because the app
is not notarized by Apple.

**Solution:**
- Use **Method 1** from the installation steps above
  (Right-click → Open)
- Or use Terminal: `xattr -cr /Applications/BatteryMonitor.app`

This is safe - the app is open source and built from verified GitHub
Actions.

### "App is from an unidentified developer" warning

This is expected. The app is not signed with an Apple Developer ID
certificate.

**Solution:**
- Right-click the app and choose **Open**
- Click **Open** in the security dialog
- The app will open normally after this first time

### App won't open (other reasons)
- Go to **System Settings → Privacy & Security**
- Look for a message about Battery Monitor
- Click **Open Anyway** if prompted

### Menu bar icon not showing
- Make sure you have menu bar space available
- Try quitting and relaunching the app
- Check if the icon is hidden in the menu bar overflow (»)

### Permission issues
- The app requires no special permissions for basic features
- All battery data is read from public macOS APIs
- No sudo or administrator access needed

## Version

**Battery Monitor 1.0**
- Release date: October 2025
- Build: Production optimized release (269 KB)
- Packaged size: 107 KB (DMG)

## Support

For issues or questions, please check the project repository.

---

🤖 *Built with Swift and SwiftUI*

