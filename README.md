# Battery Monitor for macOS

Battery Monitor is a native Swift menu bar app for macOS battery, power, USB-C,
and thermal diagnostics.

[![Platform][badge-platform]]()
[![Swift][badge-swift]]()
[![License][badge-license]]()

[badge-platform]: https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg
[badge-swift]: https://img.shields.io/badge/swift-5.9%2B-orange.svg
[badge-license]: https://img.shields.io/badge/license-MIT-blue.svg

## Highlights

- Menu bar battery percentage, charging state, and detailed SwiftUI popover.
- Battery health, cycle count, design capacity, full-charge capacity, nominal
  capacity, estimated cycles to 80%, pack reserve, manufacture data, chemistry,
  gas gauge firmware, and lifetime temperature statistics.
- Compatibility with older top-level `AppleSmartBattery` properties and newer
  nested `AppleSmartBatteryPack/BatteryData` layouts seen on macOS 26 and 27.
- USB-C Power Delivery diagnostics, charger capabilities, active contract data,
  adapter input power, and port controller details.
- General Thermals section with battery temperatures, system thermal pressure,
  component power telemetry, and a throttling percentage.
- Optional root LaunchDaemon helper for privileged `powermetrics` data without
  running the menu bar UI as root.
- Signed and notarized DMG releases.

## Requirements

- macOS 13.0 Ventura or later.
- Swift 5.9 or later for source builds.
- Xcode or Xcode Command Line Tools.
- Apple Silicon is the primary tested target. Intel Macs may build and run, but
  some Apple Silicon, USB-C Power Delivery, and `powermetrics` samplers may not
  exist there.

## Installation

### DMG

Download the latest `BatteryMonitor.dmg` from
[GitHub Releases](https://github.com/swack-tools/battery-info-mac/releases).
The release DMG is signed, notarized, and includes an Applications symlink for
drag-and-drop installation.

After launching the app, use the visible Root Helper toggle to persist the
privileged helper as a root LaunchDaemon. macOS may require admin approval in
System Settings before the LaunchDaemon starts.

### Homebrew

```bash
brew tap swack-tools/tap
brew install --cask battery-monitor
```

### Build From Source

```bash
git clone https://github.com/swack-tools/battery-info-mac.git
cd battery-info-mac
swift build -c release --product BatteryMonitor
swift build -c release --product BatteryMonitorPrivilegedHelper
```

## Usage

Run the menu bar app from source:

```bash
swift run BatteryMonitor
```

Build a local DMG:

```bash
VERSION=dev just build-dmg
open .build/artifacts/BatteryMonitor.dmg
```

The menu bar app runs in the user session. The Root Helper toggle registers or
unregisters a separate root LaunchDaemon that writes sanitized telemetry JSON to:

```text
/Library/Application Support/BatteryMonitor/privileged-telemetry.json
```

## Thermal Data

Battery Monitor collects thermal data from:

- IOKit battery data: current, virtual, lifetime minimum, lifetime average, and
  lifetime maximum battery temperatures when exposed by macOS.
- `pmset -g therm`: non-root thermal, performance, and CPU power warning state.
- Root helper `powermetrics`: CPU/GPU/ANE/DRAM power, thermal pressure, SFI
  forced idle percentages, and supported CPU power-limit percentages.

Temperature bands:

- Battery: green below 40 C, orange from 40 C to below 45 C, red at 45 C or above.
- CPU/GPU/ANE/DRAM: green below 70 C, orange from 70 C to below 90 C, red at 90 C or above.
- Storage: green below 50 C, orange from 50 C to below 70 C, red at 70 C or above.

Throttling is shown as a percentage with nominal, light, moderate, or heavy
status. The helper prefers explicit power-limit percentages, then SFI forced
idle percentages, then thermal-pressure-derived estimates.

## Development

This repository uses `just` for common developer tasks:

```bash
just test       # Swift tests
just lint       # SwiftLint when installed, YAML parse, plist lint
just build-dmg  # Build a local DMG in .build/artifacts
just run        # Run the menu bar app
```

The local `build-dmg` recipe creates an unsigned DMG by default. Set
`SIGN_IDENTITY` to sign the app bundle locally:

```bash
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" just build-dmg
```

## Release Pipeline

Releases are built by `.github/workflows/release.yml` on macOS runners.

The workflow:

1. Builds `BatteryMonitor` and `BatteryMonitorPrivilegedHelper` in release mode.
2. Creates `BatteryMonitor.app` with the helper and LaunchDaemon plist bundled.
3. Signs the helper, main executable, and app bundle with the Developer ID
   certificate from repository secrets.
4. Builds `BatteryMonitor.dmg`.
5. Submits the DMG to Apple notarization, staples the ticket, and validates it.
6. Generates a SHA-256 checksum.
7. Creates the GitHub release, or updates an existing release and uploads DMG
   assets with clobber semantics.

Manual rebuilds are supported from GitHub Actions with a `tag` input such as
`v1.1.0`. This is useful when the release already exists but the assets need to
be rebuilt and uploaded again.

## Project Layout

```text
Sources/BatteryMonitor/                  Menu bar app
Sources/BatteryMonitorShared/            Shared telemetry models and parsers
Sources/BatteryMonitorPrivilegedHelper/  Root helper executable
SupportFiles/                            App metadata, icons, entitlements
SupportFiles/LaunchDaemons/              Bundled LaunchDaemon plist
Tests/BatteryMonitorTests/               Swift tests
```

## Data Sources

Battery Monitor reads from:

- IOKit and IORegistry: `AppleSmartBattery`, `AppleSmartBatteryPack`,
  `AppleTypeCPortController`, `IODisplayConnect`.
- `system_profiler`: battery firmware, charger details, hardware model.
- `pmset`: power settings, assertions, power source history, scheduled events,
  and thermal warning state.
- `powermetrics`: privileged component power, thermal pressure, power limits,
  and SFI forced-idle data through the root helper.

## Known Limits

- The app reports current state only; it does not keep a time-series history.
- Some IORegistry keys are model and macOS-version dependent.
- The privileged helper requires admin approval and works best when the app is
  installed in `/Applications`.
- `powermetrics` sampler availability varies by hardware and macOS version.
- Release artifacts are built for Apple Silicon on GitHub-hosted macOS runners.

## License

MIT
