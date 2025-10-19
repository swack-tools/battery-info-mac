# Battery Monitor - Installation Guide

## Requirements
- macOS 13.0 (Ventura) or later
- Apple Silicon (M1/M2/M3/M4) Mac

## Installation

1. **Download** `BatteryMonitor.dmg` (107 KB)

2. **Open** the DMG file by double-clicking it

3. **Drag** `Battery Monitor.app` to your Applications folder
   - Or run it directly from the DMG

4. **Launch** Battery Monitor
   - Find it in Applications or use Spotlight (⌘+Space, type "Battery Monitor")
   - On first launch, you may need to allow it in System Settings → Privacy & Security

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
- **Advanced Diagnostics**: Internal resistance, gauge status, metrics
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

### App won't open
- Go to **System Settings → Privacy & Security**
- Click "Open Anyway" if prompted

### Menu bar icon not showing
- Make sure you have menu bar space available
- Try quitting and relaunching the app

### Permission issues
- The app requires no special permissions
- All battery data is read from public macOS APIs

## Version

**Battery Monitor 1.0**
- Release date: October 2025
- Build: Production optimized release (269 KB)
- Packaged size: 107 KB (DMG)

## Support

For issues or questions, please check the project repository.

---

🤖 *Built with Swift and SwiftUI*
