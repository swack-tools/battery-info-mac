# Battery Monitor for macOS

Battery Monitor is a native Swift battery and power diagnostics tool for
macOS. It ships as both a menu bar app and a command-line tool.

[![Platform][badge-platform]]()
[![Swift][badge-swift]]()
[![License][badge-license]]()

[badge-platform]: https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg
[badge-swift]: https://img.shields.io/badge/swift-5.9%2B-orange.svg
[badge-license]: https://img.shields.io/badge/license-MIT-blue.svg

## Highlights

- Menu bar battery percentage, charging state, and detailed SwiftUI popover.
- CLI output for scripting, diagnostics, and support reports.
- Battery health, cycle count, design capacity, full-charge capacity, nominal
  capacity, estimated cycles to 80%, pack reserve, manufacture data, chemistry,
  gas gauge firmware, and lifetime temperature statistics.
- Compatibility with both older top-level `AppleSmartBattery` properties and
  newer nested `AppleSmartBatteryPack/BatteryData` layouts seen on macOS 26 and
  macOS 27.
- USB-C Power Delivery diagnostics, charger capabilities, active contract data,
  adapter input power, and port controller details.
- Optional sudo-powered component power metrics through `powermetrics`.
- Signed and notarized DMG releases plus a signed CLI archive.

## Requirements

- macOS 13.0 Ventura or later.
- Swift 5.9 or later for source builds.
- Xcode or Xcode Command Line Tools.
- Apple Silicon is the primary tested target. Intel Macs may build and run, but
  some Apple Silicon and USB-C Power Delivery metrics may not exist there.

## Installation

### DMG

Download the latest `BatteryMonitor.dmg` from
[GitHub Releases](https://github.com/swack-tools/battery-info-mac/releases).
The release DMG is signed, notarized, and includes an Applications symlink for
drag-and-drop installation.

### Homebrew

```bash
brew tap swack-tools/tap
brew install --cask battery-monitor
```

### Build From Source

```bash
git clone https://github.com/swack-tools/battery-info-mac.git
cd battery-info-mac
swift build -c release
```

## Usage

Run the CLI:

```bash
swift run BatteryMonitorCLI
```

Run the menu bar app from a release build:

```bash
swift build -c release --product BatteryMonitor
open .build/arm64-apple-macosx/release/BatteryMonitor
```

Some component power metrics require elevated privileges:

```bash
sudo .build/arm64-apple-macosx/release/BatteryMonitorCLI
```

## Development

This repository uses `just` for common developer tasks:

```bash
just test       # Swift tests plus CI helper tests
just lint       # SwiftLint plus shell syntax checks
just build-dmg  # Build a local DMG in .build/artifacts
just run        # Run the CLI
```

The local `build-dmg` recipe creates an unsigned DMG by default. Set
`SIGN_IDENTITY` to sign the app bundle locally:

```bash
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" just build-dmg
```

## Release Pipeline

Releases are built by `.github/workflows/release.yml` on macOS runners.

The workflow:

1. Builds `BatteryMonitor` and `BatteryMonitorCLI` in release mode.
2. Creates a `.app` bundle with the tag version in `Info.plist`.
3. Signs the app and CLI with the Developer ID certificate from repository
   secrets.
4. Builds `BatteryMonitor.dmg`.
5. Submits the DMG to Apple notarization, staples the ticket, and validates it.
6. Packages the signed CLI as `BatteryMonitorCLI.tar.gz`.
7. Generates SHA-256 checksum files.
8. Creates the GitHub release, or updates an existing release and uploads assets
   with clobber semantics.

Manual rebuilds are supported from GitHub Actions with a `tag` input such as
`v1.1.0`. This is useful when the release already exists but the assets need to
be rebuilt and uploaded again.

## Project Layout

```text
Sources/BatteryMonitor/       Menu bar app
Sources/BatteryMonitorCLI/    Command-line tool
Tests/                        Swift and CI helper tests
scripts/                      Release and local build helpers
SupportFiles/                 App metadata and assets
python/power_info.py          Original Python reference implementation
```

## Data Sources

Battery Monitor reads from:

- IOKit and IORegistry: `AppleSmartBattery`, `AppleSmartBatteryPack`,
  `AppleTypeCPortController`, `IODisplayConnect`.
- `system_profiler`: battery firmware, charger details, hardware model.
- `pmset`: power settings, assertions, power source history, scheduled events.
- `powermetrics`: component power and thermal pressure when run with sudo.

## Known Limits

- The app reports current state only; it does not keep a time-series history.
- Some IORegistry keys are model and macOS-version dependent.
- CPU/GPU/ANE/DRAM power metrics require sudo and may vary by hardware.
- Release artifacts are built for Apple Silicon on GitHub-hosted macOS runners.

## License

MIT
