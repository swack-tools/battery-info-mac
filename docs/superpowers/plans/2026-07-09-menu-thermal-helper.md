# Menu Thermal Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Battery Monitor a menu-bar-only app with a bundled root LaunchDaemon helper that collects privileged thermal, power, and throttling telemetry for the UI.

**Architecture:** The menu bar app remains a user-session GUI process. A separate `BatteryMonitorPrivilegedHelper` executable is bundled with the app and registered as a root LaunchDaemon; it writes sanitized telemetry JSON to `/Library/Application Support/BatteryMonitor/privileged-telemetry.json`. The app reads that cache and merges it with non-root IOKit battery data.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, IOKit, ServiceManagement, launchd plist, `powermetrics`, `pmset`, XCTest, GitHub Actions.

---

## File Structure

- Modify `Package.swift`: remove `BatteryMonitorCLI`, add `BatteryMonitorShared`, add `BatteryMonitorPrivilegedHelper`, move tests to depend on `BatteryMonitor` and `BatteryMonitorShared`.
- Delete `Sources/BatteryMonitorCLI/` and `Sources/BatteryMonitor/main_cli.swift`.
- Delete `python/power_info.py`.
- Delete `scripts/build_dmg.sh`, `scripts/publish_release.sh`, and `Tests/ci/*.sh`; replace their coverage with XCTest project-structure tests.
- Create `Sources/BatteryMonitorShared/ThermalTelemetry.swift`: shared Codable telemetry models, thermal color/state mapping, and parsers for `pmset`/`powermetrics`.
- Create `Sources/BatteryMonitorPrivilegedHelper/main.swift`: root helper loop that collects `powermetrics` and `pmset` output and writes telemetry JSON atomically.
- Create `SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist`: LaunchDaemon definition for the helper.
- Modify `Sources/BatteryMonitor/BatteryDisplayInfo.swift`: add thermal readings, throttling status, privileged helper status, and merge cached helper telemetry.
- Modify `Sources/BatteryMonitor/BatteryDetailView.swift`: add a General Thermals section and a helper status/install section.
- Create `Sources/BatteryMonitor/PrivilegedHelperManager.swift`: register/unregister the LaunchDaemon with `SMAppService` when available and read helper status.
- Modify `project.yml`, `BatteryMonitor.xcodeproj/project.pbxproj`, `.github/workflows/release.yml`, `Justfile`, `README.md`, and `RELEASE.md` for menu-only packaging.

### Task 1: Project Structure and Red Tests

**Files:**
- Create: `Tests/BatteryMonitorTests/ProjectStructureTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Write failing project-structure tests**

```swift
import XCTest

final class ProjectStructureTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageIsMenuAppOnlyWithPrivilegedHelper() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"))
        XCTAssertTrue(package.contains("BatteryMonitorPrivilegedHelper"))
        XCTAssertTrue(package.contains("BatteryMonitorShared"))
        XCTAssertFalse(package.contains("BatteryMonitorCLI"))
    }

    func testCliAndScriptSurfacesAreRemoved() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Sources/BatteryMonitorCLI").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Sources/BatteryMonitor/main_cli.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("python/power_info.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("scripts").path))
    }

    func testReleaseWorkflowDoesNotPublishCliArtifact() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"))
        XCTAssertFalse(workflow.contains("BatteryMonitorCLI"))
        XCTAssertFalse(workflow.contains("scripts/publish_release.sh"))
    }

    func testLaunchDaemonPlistIsBundled() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist").path))
    }
}
```

- [ ] **Step 2: Run red test**

Run: `swift test --filter ProjectStructureTests`

Expected: fails because the CLI target, scripts, Python file, and missing helper target/plist still exist.

### Task 2: Shared Thermal Models and Parsers

**Files:**
- Create: `Sources/BatteryMonitorShared/ThermalTelemetry.swift`
- Create: `Tests/BatteryMonitorTests/ThermalTelemetryTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Write failing telemetry parser tests**

```swift
import XCTest
@testable import BatteryMonitorShared

final class ThermalTelemetryTests: XCTestCase {
    func testPmsetParserMapsNoWarningsToNominalZeroThrottle() {
        let output = """
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        Note: No CPU power status has been recorded
        """
        let status = PMSetThermalParser.parse(output)
        XCTAssertEqual(status.level, "Nominal")
        XCTAssertEqual(status.percentage, 0)
        XCTAssertEqual(status.source, "pmset")
    }

    func testPowermetricsParserExtractsPowerAndThermalPressure() {
        let output = """
        CPU Power: 1234 mW
        GPU Power: 456 mW
        ANE Power: 78 mW
        DRAM Power: 910 mW
        Thermal pressure: moderate
        SFI Class 2: 37% forced idle
        CPU Power limit: 68%
        """
        let snapshot = PowermetricsThermalParser.parse(output, generatedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(snapshot.componentPowers.first { $0.name == "CPU" }?.watts, 1.234, accuracy: 0.001)
        XCTAssertEqual(snapshot.componentPowers.first { $0.name == "GPU" }?.watts, 0.456, accuracy: 0.001)
        XCTAssertEqual(snapshot.throttling.percentage, 68)
        XCTAssertEqual(snapshot.throttling.level, "Moderate")
    }

    func testTemperatureColorBandsAreComponentAware() {
        XCTAssertEqual(ThermalBand.band(for: 39, component: "Battery"), .green)
        XCTAssertEqual(ThermalBand.band(for: 44, component: "Battery"), .orange)
        XCTAssertEqual(ThermalBand.band(for: 46, component: "Battery"), .red)
        XCTAssertEqual(ThermalBand.band(for: 75, component: "CPU"), .orange)
        XCTAssertEqual(ThermalBand.band(for: 91, component: "GPU"), .red)
    }
}
```

- [ ] **Step 2: Run red test**

Run: `swift test --filter ThermalTelemetryTests`

Expected: fails because `BatteryMonitorShared`, `PMSetThermalParser`, `PowermetricsThermalParser`, and `ThermalBand` do not exist.

### Task 3: Remove CLI and Script Surfaces

**Files:**
- Modify: `Package.swift`
- Delete: `Sources/BatteryMonitorCLI/`
- Delete: `Sources/BatteryMonitor/main_cli.swift`
- Delete: `python/power_info.py`
- Delete: `scripts/build_dmg.sh`
- Delete: `scripts/publish_release.sh`
- Delete: `Tests/ci/*.sh`
- Modify: `Justfile`

- [ ] **Step 1: Implement minimal package restructure**

`Package.swift` must keep only menu app, shared library, helper, and tests:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BatteryMonitor", targets: ["BatteryMonitor"]),
        .executable(name: "BatteryMonitorPrivilegedHelper", targets: ["BatteryMonitorPrivilegedHelper"])
    ],
    targets: [
        .target(name: "BatteryMonitorShared"),
        .executableTarget(
            name: "BatteryMonitor",
            dependencies: ["BatteryMonitorShared"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "BatteryMonitorPrivilegedHelper",
            dependencies: ["BatteryMonitorShared"]
        ),
        .testTarget(
            name: "BatteryMonitorTests",
            dependencies: ["BatteryMonitor", "BatteryMonitorShared"]
        )
    ]
)
```

- [ ] **Step 2: Run structure test**

Run: `swift test --filter ProjectStructureTests`

Expected: passes after deleting the CLI/script files and adding helper/plist placeholders.

### Task 4: Privileged Helper Collection

**Files:**
- Create: `Sources/BatteryMonitorPrivilegedHelper/main.swift`
- Create: `SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist`
- Modify: `Sources/BatteryMonitorShared/ThermalTelemetry.swift`

- [ ] **Step 1: Implement helper**

The helper must:
- exit with code `1` if not root unless invoked with `--test-fixture`
- run `powermetrics --samplers cpu_power,gpu_power,ane_power,thermal,sfi --show-plimits -n 1 -i 1000`
- run `pmset -g therm`
- write `ThermalSnapshot` JSON to `/Library/Application Support/BatteryMonitor/privileged-telemetry.json`
- support `--once --output <path>` for tests and manual verification

- [ ] **Step 2: Run helper build**

Run: `swift build -c release --product BatteryMonitorPrivilegedHelper`

Expected: helper builds.

### Task 5: Menu App Integration and UI

**Files:**
- Create: `Sources/BatteryMonitor/PrivilegedHelperManager.swift`
- Modify: `Sources/BatteryMonitor/BatteryDisplayInfo.swift`
- Modify: `Sources/BatteryMonitor/BatteryDetailView.swift`
- Modify: `Sources/BatteryMonitor/BatteryMenuBarApp.swift` if login/helper controls need menu actions.

- [ ] **Step 1: Integrate cached telemetry**

`BatteryDisplayInfo.fetch()` must read the helper cache if present, add battery thermal readings, and expose:
- `thermalReadings`
- `throttlingStatus`
- `componentPowers`
- `privilegedTelemetryStatus`

- [ ] **Step 2: Add UI**

Add `ThermalsSection` above Power Breakdown. It must show:
- thermal rows with green/orange/red values
- a throttling row with percentage
- helper status and an install/open-settings action when privileged telemetry is unavailable

- [ ] **Step 3: Run app build**

Run: `swift build -c release --product BatteryMonitor`

Expected: menu app builds.

### Task 6: Packaging and Release Workflow

**Files:**
- Modify: `Justfile`
- Modify: `.github/workflows/release.yml`
- Modify: `project.yml`
- Regenerate: `BatteryMonitor.xcodeproj/project.pbxproj`
- Modify: `README.md`
- Modify: `RELEASE.md`

- [ ] **Step 1: Build menu app and helper only**

Release workflow and `just build-dmg` must build:
- `BatteryMonitor`
- `BatteryMonitorPrivilegedHelper`

They must package:
- `BatteryMonitor.app`
- `Contents/MacOS/BatteryMonitorPrivilegedHelper`
- `Contents/Library/LaunchDaemons/com.swacktools.batterymonitor.helper.plist`
- `BatteryMonitor.dmg`
- `BatteryMonitor.dmg.sha256`

They must not package CLI assets.

- [ ] **Step 2: Verify release workflow syntax**

Run: `ruby -e "require 'yaml'; YAML.load_file('.github/workflows/release.yml'); puts 'release workflow yaml: OK'"`

Expected: prints `release workflow yaml: OK`.

### Task 7: Full Verification and PR

**Files:**
- All changed files.

- [ ] **Step 1: Run local verification**

Run:

```bash
just test
just lint
VERSION=dev just build-dmg
swift build -c release --product BatteryMonitor
swift build -c release --product BatteryMonitorPrivilegedHelper
```

Expected: commands exit `0`; known SwiftLint warnings are either fixed or explicitly reported.

- [ ] **Step 2: Verify bundled artifacts**

Run:

```bash
plutil -p .build/artifacts/BatteryMonitor.app/Contents/Info.plist
test -x .build/artifacts/BatteryMonitor.app/Contents/MacOS/BatteryMonitorPrivilegedHelper
test -f .build/artifacts/BatteryMonitor.app/Contents/Library/LaunchDaemons/com.swacktools.batterymonitor.helper.plist
```

Expected: app bundle contains the menu app, helper, icon, and LaunchDaemon plist.

- [ ] **Step 3: Commit, push, and open PR as xbmc4lyfe**

Use:

```bash
git config user.name xbmc4lyfe
git config user.email 273732874+xbmc4lyfe@users.noreply.github.com
git config user.signingkey /Users/allen/.ssh/id_ed25519_xbmc4lyfe.pub
```

Push to `https://github.com/xbmc4lyfe/battery-info-mac.git` and open the upstream PR with `--head xbmc4lyfe:<branch>`.

---

## Self-Review

- Spec coverage: the plan removes CLI/script surfaces, keeps the menu app user-session-only, adds a root helper LaunchDaemon, adds thermal/throttling models, adds UI, and updates release packaging.
- Placeholder scan: no `TBD`, `TODO`, or unspecified implementation tasks remain.
- Type consistency: telemetry types are owned by `BatteryMonitorShared` and used by helper, app, and tests.
