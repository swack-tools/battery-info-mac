# Native Thermal Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the standalone C-backed thermal probe with native Swift collectors in Battery Monitor, provide summarized and advanced thermal UI sections, then build and install a verified DMG.

**Architecture:** A new `BatteryMonitorThermal` library target contains privileged native Swift collectors and depends on the Codable models and aggregation in `BatteryMonitorShared`. The root helper coordinates independent collectors and atomically writes a backward-compatible snapshot; the unprivileged app renders summary and detailed readings from that cache.

**Tech Stack:** Swift 5.9, Swift Package Manager, SwiftUI, Foundation, Darwin, IOKit, CoreFoundation, ServiceManagement, XCTest, `dlopen`/`dlsym`, `IOConnectCallStructMethod`.

---

## File Map

- Modify `Package.swift`: add `BatteryMonitorThermal`, link IOKit, and connect helper/tests.
- Modify `Sources/BatteryMonitorShared/ThermalTelemetry.swift`: preserve existing parsers and add backward-compatible snapshot fields.
- Create `Sources/BatteryMonitorShared/DetailedThermalTelemetry.swift`: detailed reading/source models and summary aggregation.
- Create `Sources/BatteryMonitorThermal/ThermalCollector.swift`: collector protocol, context, result helpers, and coordinator.
- Create `Sources/BatteryMonitorThermal/SMCThermalCollector.swift`: Swift AppleSMC ABI, provider, decoder, classifier, and collector.
- Create `Sources/BatteryMonitorThermal/HIDThermalCollector.swift`: dynamically loaded IOHID bindings and temperature mapping.
- Create `Sources/BatteryMonitorThermal/IOReportThermalCollector.swift`: dynamically loaded IOReport bindings and thermal-channel filtering.
- Create `Sources/BatteryMonitorThermal/IOKitThermalCollectors.swift`: AppleSmartBattery, `ProcessInfo`, and IORegistry collectors.
- Create `Sources/BatteryMonitorThermal/CommandThermalCollectors.swift`: bounded `powermetrics` and `pmset` collectors.
- Modify `Sources/BatteryMonitorPrivilegedHelper/main.swift`: run the coordinator and publish combined snapshots.
- Modify `Sources/BatteryMonitor/BatteryDisplayInfo.swift`: merge local battery fallback with helper summary/details.
- Modify `Sources/BatteryMonitor/BatteryDetailView.swift`: render General Thermals and Thermals Advanced.
- Modify `Tests/BatteryMonitorTests/ProjectStructureTests.swift`: enforce Swift-only production telemetry and both UI sections.
- Modify `Tests/BatteryMonitorTests/ThermalTelemetryTests.swift`: retain existing parser coverage and add snapshot compatibility.
- Create focused collector and aggregation test files under `Tests/BatteryMonitorTests/`.
- Delete `Tools/ThermalProbe/` and its obsolete standalone design/plan after the port is covered.
- Modify `README.md`: document native thermal sources and root-helper requirement.

### Task 1: Shared Detailed Telemetry Contract

**Files:**
- Create: `Sources/BatteryMonitorShared/DetailedThermalTelemetry.swift`
- Modify: `Sources/BatteryMonitorShared/ThermalTelemetry.swift`
- Create: `Tests/BatteryMonitorTests/DetailedThermalTelemetryTests.swift`
- Modify: `Tests/BatteryMonitorTests/ThermalTelemetryTests.swift`

- [ ] **Step 1: Write failing model and compatibility tests**

Add tests that construct detailed readings and decode an old snapshot with no new keys:

```swift
func testOldSnapshotDecodesWithEmptyDetailedTelemetry() throws {
    let json = #"{"generatedAt":"2026-07-11T00:00:00Z","thermalReadings":[],"componentPowers":[],"throttling":{"level":"Nominal","percentage":0,"source":"pmset"},"messages":[]}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(ThermalSnapshot.self, from: Data(json.utf8))
    XCTAssertEqual(snapshot.detailedReadings, [])
    XCTAssertEqual(snapshot.sourceStatuses, [])
}

func testSummaryPrefersSMCAndUsesHottestPlausibleCPU() {
    let readings = [
        DetailedThermalReading.temperature(source: "iohid", identifier: "cpu-hid", label: "CPU", category: .cpu, celsius: 61),
        DetailedThermalReading.temperature(source: "smc", identifier: "Tp01", label: "CPU P1", category: .cpu, celsius: 72),
        DetailedThermalReading.temperature(source: "smc", identifier: "Tp05", label: "CPU P2", category: .cpu, celsius: 78)
    ]
    XCTAssertEqual(ThermalSummaryBuilder.build(from: readings).first?.celsius, 78)
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter DetailedThermalTelemetryTests`

Expected: compilation fails because the detailed types and new snapshot fields do not exist.

- [ ] **Step 3: Add the detailed models and deterministic summary builder**

Define these public, Codable, Equatable, Sendable types:

```swift
public enum ThermalCategory: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, battery, memory, storage, pmu, enclosure, system, unknown
}

public enum ThermalReadingKind: String, Codable, Sendable {
    case temperature, thermalPressure
}

public enum ThermalClassification: String, Codable, Sendable {
    case known, heuristic, unclassified
}

public enum ThermalSourceState: String, Codable, Sendable {
    case success, partial, unavailable, failed
}

public struct DetailedThermalReading: Codable, Equatable, Sendable {
    public var source: String
    public var identifier: String
    public var label: String
    public var category: ThermalCategory
    public var kind: ThermalReadingKind
    public var numericValue: Double?
    public var textValue: String?
    public var unit: String?
    public var classification: ThermalClassification
    public var warnings: [String]
}

public struct ThermalSourceStatus: Codable, Equatable, Sendable {
    public var source: String
    public var state: ThermalSourceState
    public var readingCount: Int
    public var durationMilliseconds: Double
    public var warnings: [String]
    public var error: String?
    public var scannedRecordCount: Int?
}
```

Implement `ThermalSummaryBuilder.build(from:)` with fixed category order, source priority per category, finite/plausible filtering, and hottest-value selection. Exclude identifiers or labels containing `lifetime`, `minimum`, `maximum`, or `average` from current summaries.

- [ ] **Step 4: Add custom backward-compatible `ThermalSnapshot` Codable logic**

Keep all existing fields and add:

```swift
public var detailedReadings: [DetailedThermalReading]
public var sourceStatuses: [ThermalSourceStatus]
```

Decode with `decodeIfPresent(... ) ?? []`, and encode both arrays. Preserve the uncommitted powermetrics parsing improvements already present in `ThermalTelemetry.swift` and its tests.

- [ ] **Step 5: Run shared telemetry tests**

Run: `swift test --filter 'ThermalTelemetryTests|DetailedThermalTelemetryTests'`

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/BatteryMonitorShared Tests/BatteryMonitorTests/DetailedThermalTelemetryTests.swift Tests/BatteryMonitorTests/ThermalTelemetryTests.swift
git commit -m "feat: add detailed thermal telemetry contract"
```

### Task 2: Native Swift AppleSMC Collector

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BatteryMonitorThermal/ThermalCollector.swift`
- Create: `Sources/BatteryMonitorThermal/SMCThermalCollector.swift`
- Create: `Tests/BatteryMonitorTests/SMCThermalCollectorTests.swift`

- [ ] **Step 1: Add failing AppleSMC ABI, decoder, and fixture-provider tests**

Cover `MemoryLayout<SMCKeyData>.size`, FourCC round trips, `sp78`/`flt`/integer decoding, known CPU/GPU/battery keys, heuristic `T*` keys, and failure isolation through an injected provider.

```swift
func testKnownSMCKeyMapsToCPUReading() throws {
    let raw = SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0x36, 0x80], status: 0)
    let reading = try SMCReadingMapper.map(raw, timestamp: .distantPast)
    XCTAssertEqual(reading?.category, .cpu)
    XCTAssertEqual(reading?.numericValue, 54.5)
}
```

- [ ] **Step 2: Run the test and confirm failure**

Run: `swift test --filter SMCThermalCollectorTests`

Expected: compilation fails because the new target and SMC types do not exist.

- [ ] **Step 3: Add the package target and collector protocol**

Add `BatteryMonitorThermal` as a library target depending on `BatteryMonitorShared`, with `.linkedFramework("IOKit")`. Make the helper depend on it and the test target depend on it.

Define:

```swift
public protocol ThermalCollector: Sendable {
    var source: String { get }
    func collect(at timestamp: Date) -> ThermalCollectionResult
}

public struct ThermalCollectionResult: Sendable {
    public var readings: [DetailedThermalReading]
    public var status: ThermalSourceStatus
}
```

- [ ] **Step 4: Implement exact Swift AppleSMC bindings**

Define fixed-layout `SMCVersion`, `SMCPowerLimit`, `SMCKeyInfo`, and `SMCKeyData` structures. Open `AppleSMCKeysEndpoint` through IOKit, enumerate `#KEY`, and use `IOConnectCallStructMethod` selector 2 with commands 9, 8, and 5. Copy returned tuples to byte arrays with `withUnsafeBytes`; do not add a C target.

Use an `SMCRecordProviding` protocol so tests never access live SMC. Port the proven decoder and sensor classification table. Emit only decoded temperature keys in the normal result and preserve per-key warnings.

- [ ] **Step 5: Run SMC tests and the full shared test set**

Run: `swift test --filter SMCThermalCollectorTests`

Expected: all SMC tests pass.

Run: `swift test --filter Thermal`

Expected: all thermal tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/BatteryMonitorThermal Tests/BatteryMonitorTests/SMCThermalCollectorTests.swift
git commit -m "feat: collect AppleSMC thermals in Swift"
```

### Task 3: Native Swift IOHID And IOReport Collectors

**Files:**
- Create: `Sources/BatteryMonitorThermal/DynamicSystemLibrary.swift`
- Create: `Sources/BatteryMonitorThermal/HIDThermalCollector.swift`
- Create: `Sources/BatteryMonitorThermal/IOReportThermalCollector.swift`
- Create: `Tests/BatteryMonitorTests/HIDThermalCollectorTests.swift`
- Create: `Tests/BatteryMonitorTests/IOReportThermalCollectorTests.swift`

- [ ] **Step 1: Write failing mapping and unavailable-symbol tests**

Use fixture records to prove CPU/GPU/battery/NAND/PMU classification, plausibility warnings, IOReport temperature-unit filtering, and unavailable status when symbol loading fails.

```swift
func testIOReportRejectsPowerChannelAsTemperature() {
    let raw = IOReportRawRecord(group: "Energy Model", subgroup: "CPU", channel: "CPU Power", unit: "mW", value: 1200)
    XCTAssertNil(IOReportReadingMapper.mapTemperature(raw, timestamp: .distantPast))
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter 'HIDThermalCollectorTests|IOReportThermalCollectorTests'`

Expected: compilation fails because the native providers do not exist.

- [ ] **Step 3: Implement a typed dynamic-symbol loader**

Wrap `dlopen`, `dlsym`, and `dlclose` in a small owner that throws a source-specific unavailable error. Convert each symbol exactly once with `unsafeBitCast` to an `@convention(c)` type alias. Keep handles alive for the lifetime of each collection call.

- [ ] **Step 4: Implement the IOHID provider and collector**

Load the event-system client functions, match usage page `0xff00` and usage `5`, request event type `15`, and read field `15 << 16`. Capture product, location/sensor ID, and registry ID. Map every finite event to a detailed temperature reading; add a warning outside `-40...150 C`.

- [ ] **Step 5: Implement the IOReport provider and collector**

Load `libIOReport.dylib`, copy channels, create a subscription, sample twice over a bounded 100 ms interval, and compute a delta. Scan every returned record but emit a detailed reading only when the channel/group names are thermal and the unit is `C`, `degC`, `Celsius`, or `°C`. Record scanned and emitted counts in source status.

- [ ] **Step 6: Run focused and full tests**

Run: `swift test --filter 'HIDThermalCollectorTests|IOReportThermalCollectorTests'`

Expected: all selected tests pass.

Run: `swift test`

Expected: full suite passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/BatteryMonitorThermal Tests/BatteryMonitorTests/HIDThermalCollectorTests.swift Tests/BatteryMonitorTests/IOReportThermalCollectorTests.swift
git commit -m "feat: add native HID and IOReport thermals"
```

### Task 4: IOKit And Command Collectors

**Files:**
- Create: `Sources/BatteryMonitorThermal/IOKitThermalCollectors.swift`
- Create: `Sources/BatteryMonitorThermal/CommandThermalCollectors.swift`
- Create: `Tests/BatteryMonitorTests/IOKitThermalCollectorTests.swift`
- Create: `Tests/BatteryMonitorTests/CommandThermalCollectorTests.swift`

- [ ] **Step 1: Write failing conversion, parser, and timeout tests**

Cover root-battery deci-Kelvin conversion, pack centi-Celsius conversion, lifetime labels, `ProcessInfo` pressure mapping, IORegistry thermal-property filtering, `powermetrics` temperature/power parsing, `pmset` status, and command timeout/failure results.

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter 'IOKitThermalCollectorTests|CommandThermalCollectorTests'`

Expected: compilation fails because the collectors do not exist.

- [ ] **Step 3: Implement AppleSmartBattery, ProcessInfo, and IORegistry collectors**

Port the proven registry flattener and conversions. Emit current and lifetime battery readings with stable identifiers so the summary builder can exclude lifetime values. Traverse IORegistry recursively, scan thermal properties, and emit only values that can be identified as temperature or thermal pressure; keep unknown numeric context out of the UI.

- [ ] **Step 4: Implement bounded command execution and collectors**

Use Foundation `Process`, separate output/error pipes, a timeout, and process termination. Discover supported powermetrics samplers from `--help`; request thermal, CPU/GPU/ANE power, battery, and SFI samplers that exist. Parse plist first and text as fallback. Map command failures to source statuses and retain parsed partial readings.

- [ ] **Step 5: Run focused and full tests**

Run: `swift test --filter 'IOKitThermalCollectorTests|CommandThermalCollectorTests'`

Expected: all selected tests pass.

Run: `swift test`

Expected: full suite passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/BatteryMonitorThermal Tests/BatteryMonitorTests/IOKitThermalCollectorTests.swift Tests/BatteryMonitorTests/CommandThermalCollectorTests.swift
git commit -m "feat: collect IOKit and command thermals"
```

### Task 5: Coordinator And Privileged Helper Integration

**Files:**
- Modify: `Sources/BatteryMonitorThermal/ThermalCollector.swift`
- Create: `Tests/BatteryMonitorTests/ThermalCaptureCoordinatorTests.swift`
- Modify: `Sources/BatteryMonitorPrivilegedHelper/main.swift`
- Modify: `Tests/BatteryMonitorTests/PrivilegedHelperControlTests.swift`

- [ ] **Step 1: Write failing coordinator isolation and snapshot tests**

Inject one successful collector and one failing collector. Assert the snapshot retains successful readings, records both statuses, builds summary values, derives powers/throttling, and includes a readable failure message.

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter ThermalCaptureCoordinatorTests`

Expected: compilation fails because the coordinator does not exist.

- [ ] **Step 3: Implement the coordinator**

Define `ThermalCaptureCoordinator.collect(generatedAt:)` to run a stable collector list independently, flatten detailed readings, call `ThermalSummaryBuilder`, extract deduplicated component powers and strongest throttling state, and return a complete `ThermalSnapshot` even when every direct temperature source is unavailable.

Default collectors are SMC, IOHID, AppleSmartBattery, ProcessInfo, IOReport, powermetrics, pmset, and IORegistry.

- [ ] **Step 4: Replace helper-local collection with the coordinator**

Keep argument parsing, root enforcement, 10-second loop, and atomic file writing. Remove the helper's duplicate command/parser functions. Add a `--once` result summary to stderr only when collection cannot write a snapshot.

- [ ] **Step 5: Run helper and full tests**

Run: `swift test --filter 'ThermalCaptureCoordinatorTests|PrivilegedHelperControlTests'`

Expected: all selected tests pass.

Run: `swift build -c debug --product BatteryMonitorPrivilegedHelper`

Expected: helper builds with no C target.

- [ ] **Step 6: Commit**

```bash
git add Sources/BatteryMonitorThermal Sources/BatteryMonitorPrivilegedHelper Tests/BatteryMonitorTests
git commit -m "feat: publish native privileged thermals"
```

### Task 6: General And Advanced Thermal UI

**Files:**
- Modify: `Sources/BatteryMonitor/BatteryDisplayInfo.swift`
- Modify: `Sources/BatteryMonitor/BatteryDetailView.swift`
- Create: `Tests/BatteryMonitorTests/ThermalDisplayInfoTests.swift`
- Modify: `Tests/BatteryMonitorTests/ProjectStructureTests.swift`

- [ ] **Step 1: Write failing display merge and structure tests**

Test that helper summary replaces duplicate local battery rows without removing a local fallback, detailed readings survive into display state, source groups use stable source IDs, and the view source contains `ThermalsAdvancedSection` immediately after `GeneralThermalsSection`.

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter 'ThermalDisplayInfoTests|ProjectStructureTests'`

Expected: tests fail because detailed display state and the advanced section do not exist.

- [ ] **Step 3: Merge snapshot telemetry into display state**

Add `detailedThermalReadings` and `thermalSourceStatuses` to `BatteryDisplayInfo`. Build a local battery fallback first, then prefer helper `thermalReadings` when present. Deduplicate summary identity by category/name and detailed identity by `source + identifier`.

- [ ] **Step 4: Refine General Thermals**

Render stable summary category rows, throttling, and component power using existing `InfoRow`, font, disclosure, and thermal-band helpers. Show privileged telemetry state whenever the summary has no non-battery helper reading, not only when component power is empty.

- [ ] **Step 5: Add Thermals Advanced**

Insert `ThermalsAdvancedSection` directly below General Thermals. Group by source in source-status order, show status/count in compact headers, and render every temperature/pressure row with its label, identifier, value, classification, and warning. Keep the outer section collapsed by default and use `LazyVStack` for the long sensor list.

- [ ] **Step 6: Run focused, full, and app build checks**

Run: `swift test --filter 'ThermalDisplayInfoTests|ProjectStructureTests'`

Expected: selected tests pass.

Run: `swift test`

Expected: full suite passes.

Run: `swift build -c debug --product BatteryMonitor`

Expected: app builds.

- [ ] **Step 7: Commit**

```bash
git add Sources/BatteryMonitor/BatteryDisplayInfo.swift Sources/BatteryMonitor/BatteryDetailView.swift Tests/BatteryMonitorTests
git commit -m "feat: add summarized and advanced thermals"
```

### Task 7: Remove Standalone Probe And C Shim

**Files:**
- Delete: `Tools/ThermalProbe/`
- Delete: `docs/superpowers/specs/2026-07-09-macos-27-thermal-probe-design.md`
- Delete: `docs/superpowers/plans/2026-07-09-macos-27-thermal-probe.md`
- Modify: `Tests/BatteryMonitorTests/ProjectStructureTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Add failing Swift-only structure assertions**

Assert no tracked `.c` or `.h` files exist under `Tools/ThermalProbe`, no package/source references `CThermalProbeShim`, and production package targets include `BatteryMonitorThermal`.

- [ ] **Step 2: Run the structure test and confirm failure**

Run: `swift test --filter ProjectStructureTests`

Expected: failure reports the remaining C shim/tool files.

- [ ] **Step 3: Delete the standalone tool and update documentation**

Remove the tracked probe package, C shim, CLI, probe-only tests, validation utility, and obsolete standalone spec/plan. Do not delete the untracked `thermal-capture.json`. Update README thermal documentation to describe native sources, the helper cache, and General versus Advanced Thermals.

- [ ] **Step 4: Verify no C shim remains**

Run: `git ls-files | rg '\.(c|h)$|CThermalProbeShim|Tools/ThermalProbe'`

Expected: no output.

Run: `swift test`

Expected: full suite passes.

- [ ] **Step 5: Commit**

```bash
git add -A Tools/ThermalProbe docs/superpowers README.md Tests/BatteryMonitorTests/ProjectStructureTests.swift
git commit -m "refactor: remove standalone thermal probe"
```

### Task 8: Live Root Verification And Hardening

**Files:**
- Modify as failures require: `Sources/BatteryMonitorThermal/*.swift`
- Modify as failures require: focused matching test files under `Tests/BatteryMonitorTests/`

- [ ] **Step 1: Build the release helper**

Run: `swift build -c release --product BatteryMonitorPrivilegedHelper`

Expected: successful release build.

- [ ] **Step 2: Run a one-shot root capture**

Run:

```bash
sudo "$(swift build -c release --show-bin-path)/BatteryMonitorPrivilegedHelper" \
  --once \
  --output /tmp/batterymonitor-native-thermal.json
```

Expected: exit 0 and a fresh JSON snapshot owned by root.

- [ ] **Step 3: Inspect source evidence**

Run:

```bash
plutil -convert json -o - /tmp/batterymonitor-native-thermal.json | \
  jq '{summary: .thermalReadings, sources: .sourceStatuses, detailedCounts: (.detailedReadings | group_by(.source) | map({source: .[0].source, count: length}))}'
```

Expected: AppleSMC and/or IOHID produces non-battery temperature readings on this host; unavailable sources explicitly report their errors.

- [ ] **Step 4: Fix only evidence-backed live issues with regression tests**

For each live failure, first add a fixture reproducing the returned layout/value, run the focused test to see it fail, implement the smallest correction, and rerun the focused plus full test suite.

- [ ] **Step 5: Commit any hardening changes**

```bash
git add Sources/BatteryMonitorThermal Tests/BatteryMonitorTests
git commit -m "fix: harden native thermal collection"
```

Skip this commit only if no files changed.

### Task 9: Release DMG, Installation, And Final Verification

**Files:**
- Generated: `.build/artifacts/BatteryMonitor.dmg`
- Installed: `/Applications/BatteryMonitor.app`

- [ ] **Step 1: Run complete verification**

Run: `swift test`

Expected: all tests pass.

Run: `just lint`

Expected: SwiftLint is clean or explicitly skipped when absent; YAML and plist validation pass.

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 2: Build the release DMG**

Run: `VERSION=dev-native-thermals just build-dmg`

Expected: `.build/artifacts/BatteryMonitor.dmg` and its SHA-256 file are created.

- [ ] **Step 3: Verify the DMG payload**

Mount with `hdiutil attach -nobrowse -readonly`, verify `BatteryMonitor.app`, both Mach-O executables, the launch-daemon plist, bundle identifiers, and code-signing state, then detach it.

- [ ] **Step 4: Install the app**

Quit a running Battery Monitor instance, preserve an existing installation as `/Applications/BatteryMonitor.app.previous`, and install the DMG app to `/Applications/BatteryMonitor.app` with `ditto`. Use `sudo` where required. Do not overwrite the previous backup until the new installation is verified.

- [ ] **Step 5: Launch and verify installed telemetry**

Launch `/Applications/BatteryMonitor.app`, verify the app process starts, verify the helper registration/status, and confirm the privileged cache timestamp advances. Inspect the installed cache for non-battery detailed readings and source statuses.

- [ ] **Step 6: Review final repository state**

Run: `git status --short --branch`

Expected: only the intentionally untracked `thermal-capture.json` remains; no implementation file is unstaged.

Run: `git log --oneline --decorate -12`

Expected: design, schema, collectors, helper, UI, cleanup, and any hardening commits are present on `codex/native-thermal-integration`.
