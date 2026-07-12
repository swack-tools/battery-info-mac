# macOS 27 Thermal Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a root-only standalone Swift CLI that inventories direct and contextual thermal telemetry from every practical macOS 27 source without third-party runtime dependencies.

**Architecture:** Add an isolated Swift package under `Tools/ThermalProbe/`. Swift owns models, collection orchestration, parsing, normalization, aggregation, and rendering; an in-package C shim owns the AppleSMC, IOHIDEventSystem, and dynamically loaded IOReport ABI boundaries. Every collector returns an isolated source result so private-API or command failures remain visible without stopping the capture.

**Tech Stack:** Swift 5 language mode with SwiftPM 5.9, Foundation, IOKit, CoreFoundation, Darwin, C11, XCTest, built-in `powermetrics`, `pmset`, `sysctl`, and `system_profiler`.

---

## File Structure

- Create `Tools/ThermalProbe/Package.swift`: independent package and framework linkage.
- Create `Tools/ThermalProbe/README.md`: build, test, and root-run commands plus output examples.
- Create `Tools/ThermalProbe/THIRD_PARTY_NOTICES.md`: attribution for referenced sensor mappings and ABI patterns.
- Create `Tools/ThermalProbe/Validation/ThermalLoad.swift`: separately compiled CPU and Metal load used only for sensor-response validation.
- Create `Tools/ThermalProbe/Sources/CThermalProbeShim/include/ThermalProbeShim.h`: fixed C records and copy/free APIs.
- Create `Tools/ThermalProbe/Sources/CThermalProbeShim/ThermalProbeShim.c`: AppleSMC, IOHID, and dynamic IOReport implementations.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/Models.swift`: versioned Codable capture schema.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/Arguments.swift`: dependency-free option parsing and exit decisions.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/Collector.swift`: collector protocol, context, timing, and source-result helpers.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/SMC.swift`: SMC decoding, classification, and shim-backed collection.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/HID.swift`: shim-backed IOHID temperature collection.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/IOReport.swift`: shim-backed channel collection.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/IOKitCollectors.swift`: AppleSmartBattery, ProcessInfo, IORegistry, and AppleCLPC collectors.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/CommandRunner.swift`: bounded child-process execution with timeout cleanup.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/CommandCollectors.swift`: powermetrics, pmset, sysctl, and system_profiler capability collectors.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/Aggregation.swift`: sample and capture summaries.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/Rendering.swift`: human, JSON, and tagged JSONL rendering.
- Create `Tools/ThermalProbe/Sources/ThermalProbeCore/CaptureCoordinator.swift`: deterministic collection and repeated sampling.
- Create `Tools/ThermalProbe/Sources/ThermalProbe/main.swift`: root guard, signal-safe process cleanup, output, and exit code.
- Create focused XCTest files and fixtures under `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/`.
- Create `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/TestSupport.swift`: deterministic clocks, fixture collectors, and capture builders shared by tests.

No production Battery Monitor file is modified by this plan.

### Task 1: Package And Versioned Capture Models

**Files:**
- Create: `Tools/ThermalProbe/Package.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/Models.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write the model round-trip tests**

Create a test that constructs a source result with numeric and textual values, nested typed metadata, warnings, and raw bytes:

```swift
import XCTest
@testable import ThermalProbeCore

final class ModelsTests: XCTestCase {
    func testCaptureEnvelopeRoundTripsWithoutLosingTypedMetadata() throws {
        let reading = Reading(
            source: "smc",
            identifier: "Tp01",
            label: "CPU performance core 1",
            category: .cpu,
            kind: .temperature,
            value: .number(61.25),
            unit: "C",
            timestamp: Date(timeIntervalSince1970: 10),
            classification: .known,
            metadata: ["nested": .object(["enabled": .bool(true)])],
            warnings: [],
            rawDataType: "sp78",
            rawBytes: [0x3d, 0x40]
        )
        let source = SourceResult(
            source: "smc", status: .success,
            startedAt: Date(timeIntervalSince1970: 9), durationMilliseconds: 4,
            readings: [reading], warnings: [], error: nil, capabilities: [:]
        )
        let sample = ThermalSample(index: 0, startedAt: Date(timeIntervalSince1970: 9),
                                   durationMilliseconds: 4, sources: [source], summaries: [])
        let capture = CaptureEnvelope(
            schemaVersion: 1,
            host: HostMetadata(osVersion: "27.0", osBuild: "26A5378j",
                               model: "Mac16,12", chip: "Apple M4"),
            invocation: InvocationMetadata(arguments: ["--raw"], isRoot: true,
                                           requestedSamples: 1, intervalMilliseconds: 1000,
                                           raw: true),
            samples: [sample], aggregates: [], warnings: []
        )

        let data = try ProbeJSON.encoder.encode(capture)
        XCTAssertEqual(try ProbeJSON.decoder.decode(CaptureEnvelope.self, from: data), capture)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the expected red state**

Run: `cd Tools/ThermalProbe && swift test --filter ModelsTests`

Expected: FAIL because the package and model types do not exist.

- [ ] **Step 3: Add the package manifest and model types**

Use Swift tools 5.9 and define products/targets exactly as follows:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThermalProbe",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "thermal-probe", targets: ["ThermalProbe"])],
    targets: [
        .target(
            name: "CThermalProbeShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "ThermalProbeCore",
            dependencies: ["CThermalProbeShim"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(name: "ThermalProbe", dependencies: ["ThermalProbeCore"]),
        .testTarget(name: "ThermalProbeCoreTests", dependencies: ["ThermalProbeCore"])
    ],
    swiftLanguageVersions: [.v5]
)
```

Implement `JSONValue`, `ReadingValue`, `ReadingCategory`, `ReadingKind`, `ClassificationLevel`, `SourceStatus`, `Reading`, `SourceResult`, `SensorSummary`, `SensorAggregate`, `ThermalSample`, `HostMetadata`, `InvocationMetadata`, `CaptureEnvelope`, `SampleStreamRecord`, `SummaryStreamRecord`, and tagged `StreamRecord` as `Codable` and `Equatable`. `Reading.number` returns the associated `Double` only for `.number`. Encode dates with ISO-8601 fractional seconds and JSON keys in sorted order through `ProbeJSON.encoder` and `ProbeJSON.decoder`.

- [ ] **Step 4: Run the model tests**

Run: `cd Tools/ThermalProbe && swift test --filter ModelsTests`

Expected: PASS.

- [ ] **Step 5: Commit the model foundation**

```bash
git add Tools/ThermalProbe/Package.swift Tools/ThermalProbe/Sources/ThermalProbeCore/Models.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ModelsTests.swift
git commit -m "feat: add thermal probe capture model"
```

### Task 2: Arguments, Root Policy, And Collector Contract

**Files:**
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/Arguments.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/Collector.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ArgumentsTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CollectorTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/TestSupport.swift`

- [ ] **Step 1: Write argument and source-isolation tests**

```swift
func testParsesStreamingRepeatedRawCapture() throws {
    XCTAssertEqual(
        try ProbeOptions.parse(["--jsonl", "--samples", "3", "--interval", "250", "--raw"]),
        ProbeOptions(format: .jsonLines, samples: 3, intervalMilliseconds: 250, raw: true, help: false)
    )
}

func testRejectsMutuallyExclusiveJSONModes() {
    XCTAssertThrowsError(try ProbeOptions.parse(["--json", "--jsonl"]))
}

func testRuntimeDecisionRequiresRootBeforeCollection() {
    XCTAssertEqual(RuntimeDecision.evaluate(options: .default, effectiveUserID: 501), .exit(77))
    XCTAssertEqual(RuntimeDecision.evaluate(options: .default, effectiveUserID: 0), .collect)
}

func testFailedCollectorDoesNotSuppressSuccessfulCollector() {
    let results = CollectorRunner.run(
        collectors: [FixtureCollector.failed("smc"), FixtureCollector.temperature("hid", 42)],
        context: .fixture
    )
    XCTAssertEqual(results.map(\.status), [.failed, .success])
    XCTAssertEqual(results.flatMap(\.readings).count, 1)
}
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `cd Tools/ThermalProbe && swift test --filter 'ArgumentsTests|CollectorTests'`

Expected: FAIL because argument and collector types do not exist.

- [ ] **Step 3: Implement dependency-free parsing and collector isolation**

Define:

```swift
public struct ProbeOptions: Equatable {
    public enum Format: Equatable { case human, json, jsonLines }
    public static let `default` = ProbeOptions(format: .human, samples: 1,
        intervalMilliseconds: 1000, raw: false, help: false)
    public static func parse(_ arguments: [String]) throws -> ProbeOptions
    public static func repeated(samples: Int, interval: Int) -> ProbeOptions
}

public enum RuntimeDecision: Equatable {
    case showHelp, collect, exit(Int32)
    public static func evaluate(options: ProbeOptions, effectiveUserID: uid_t) -> RuntimeDecision
}

public protocol ThermalCollector {
    var source: String { get }
    func collect(context: CollectionContext) -> SourceResult
}

public enum CollectorRunner {
    public static func run(collectors: [any ThermalCollector], context: CollectionContext) -> [SourceResult]
}

public protocol ProbeClock: AnyObject {
    var wallNow: Date { get }
    var monotonicNow: TimeInterval { get }
    func sleep(milliseconds: Int)
}
```

The parser accepts only `--json`, `--jsonl`, `--samples N`, `--interval MS`, `--raw`, and `--help`. Samples and intervals must be positive. `--json` and `--jsonl` are mutually exclusive. Parse errors map to exit 64; non-root collection maps to 77; help is allowed without root.

`TestSupport.swift` defines `FixtureCollector.failed`, both `FixtureCollector.temperature` overloads, `CollectionContext.fixture`, `ThermalFixtures.sample`, `ThermalFixtures.capture`, and a mutable `FixtureClock` conforming to `ProbeClock`. The fixture collector returns a complete `SourceResult`; the fixture clock exposes `advance(_:)` so coordinator tests simulate collection overruns without sleeping.

- [ ] **Step 4: Run argument and collector tests**

Run: `cd Tools/ThermalProbe && swift test --filter 'ArgumentsTests|CollectorTests'`

Expected: PASS.

- [ ] **Step 5: Commit the runtime contract**

```bash
git add Tools/ThermalProbe/Sources/ThermalProbeCore/Arguments.swift Tools/ThermalProbe/Sources/ThermalProbeCore/Collector.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ArgumentsTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CollectorTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/TestSupport.swift
git commit -m "feat: define thermal collector runtime"
```

### Task 3: SMC Decoder And Conservative M4 Classification

**Files:**
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/SMC.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/SMCDecoderTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/SensorClassifierTests.swift`

- [ ] **Step 1: Write decoder and classifier tests**

```swift
func testDecodesSignedSP78AndLittleEndianFloat() throws {
    XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "sp78", bytes: [0x2a, 0x80])), 42.5, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "sp78", bytes: [0xff, 0x00])), -1.0, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "flt ", bytes: [0x00, 0x00, 0x28, 0x42])), 42.0, accuracy: 0.001)
}

func testDecodesIntegerAndFixedPointFamilies() throws {
    XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "ui16", bytes: [0x01, 0x02])), 258)
    XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "fpe2", bytes: [0x01, 0x00])), 64)
    XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "sp5a", bytes: [0x04, 0x00])), 1)
}

func testClassifiesKnownM4KeysAndLeavesPrefixGuessHeuristic() {
    XCTAssertEqual(SensorClassifier.classifySMC(key: "Tp01").category, .cpu)
    XCTAssertEqual(SensorClassifier.classifySMC(key: "Tg0G").category, .gpu)
    XCTAssertEqual(SensorClassifier.classifySMC(key: "TB0T").category, .battery)
    XCTAssertEqual(SensorClassifier.classifySMC(key: "Tzzz").classification, .heuristic)
}
```

- [ ] **Step 2: Run the SMC tests and verify they fail**

Run: `cd Tools/ThermalProbe && swift test --filter 'SMCDecoderTests|SensorClassifierTests'`

Expected: FAIL because `SMCDecoder` and `SensorClassifier` do not exist.

- [ ] **Step 3: Implement decoding and explicit mappings**

`SMCDecoder.decode(type:bytes:) throws -> Double?` must decode big-endian `ui8`, `ui16`, `ui32`, `si8`, `si16`, `si32`; unsigned `fpXY`/`fpe2`; signed `spXY`; and native little-endian `flt `. It returns `nil` for unsupported types and throws for short buffers or non-finite floats. `SensorClassifier.classifySMC(key:)` returns a `SensorClassification` containing label, category, kind, and confidence.

Use explicit M4 mappings for `Te05`, `Te0S`, `Te09`, `Te0H`; `Tp01`, `Tp05`, `Tp09`, `Tp0D`, `Tp0V`, `Tp0Y`, `Tp0b`, `Tp0e`; `Tg0G`, `Tg0H`, `Tg0K`, `Tg0L`, `Tg0d`, `Tg0e`, `Tg0j`, `Tg0k`, `Tg1U`, `Tg1k`; and memory proximity keys `Tm0p`, `Tm1p`, `Tm2p`. Battery keys `TB0T`, `TB1T`, `TB2T` are known battery sensors. Other decoded `T...` keys are unlabelled heuristic temperatures. Values outside `-40...150 C` receive a plausibility warning but remain available.

- [ ] **Step 4: Run the SMC tests**

Run: `cd Tools/ThermalProbe && swift test --filter 'SMCDecoderTests|SensorClassifierTests'`

Expected: PASS.

- [ ] **Step 5: Commit decoding and classification**

```bash
git add Tools/ThermalProbe/Sources/ThermalProbeCore/SMC.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/SMCDecoderTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/SensorClassifierTests.swift
git commit -m "feat: decode and classify SMC sensors"
```

### Task 4: AppleSMC And IOHID C Shim Collectors

**Files:**
- Create: `Tools/ThermalProbe/Sources/CThermalProbeShim/include/ThermalProbeShim.h`
- Create: `Tools/ThermalProbe/Sources/CThermalProbeShim/ThermalProbeShim.c`
- Modify: `Tools/ThermalProbe/Sources/ThermalProbeCore/SMC.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/HID.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ShimMappingTests.swift`

- [ ] **Step 1: Write Swift mapping tests around fixed C records**

```swift
func testSMCRawRecordMapsToTemperatureReading() throws {
    let raw = SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0x3d, 0x40], status: 0)
    let reading = try SMCCollector.map(raw: raw, timestamp: Date(timeIntervalSince1970: 1), includeRaw: true)
    XCTAssertEqual(reading.value, .number(61.25))
    XCTAssertEqual(reading.category, .cpu)
    XCTAssertEqual(reading.rawBytes, [0x3d, 0x40])
}

func testHIDRecordPreservesDuplicateServiceIdentity() {
    let first = HIDRawRecord(index: 1, product: "PMU tdie1", location: "1", registryID: 100, celsius: 55)
    let second = HIDRawRecord(index: 2, product: "PMU tdie1", location: "2", registryID: 101, celsius: 55)
    XCTAssertNotEqual(HIDCollector.map(first, timestamp: .distantPast).identifier,
                      HIDCollector.map(second, timestamp: .distantPast).identifier)
}
```

- [ ] **Step 2: Run the mapping tests and verify they fail**

Run: `cd Tools/ThermalProbe && swift test --filter ShimMappingTests`

Expected: FAIL because shim records and collectors do not exist.

- [ ] **Step 3: Define the stable shim API**

Expose fixed records and copy/free functions:

```c
typedef struct {
    char key[5];
    char data_type[5];
    uint32_t data_size;
    uint8_t bytes[32];
    int32_t status;
} TPSMCRecord;

typedef struct {
    uint32_t index;
    char product[192];
    char location[96];
    uint64_t registry_id;
    double celsius;
} TPHIDRecord;

int32_t tp_smc_copy_records(TPSMCRecord **records, size_t *count,
                            char *error, size_t error_capacity);
int32_t tp_hid_copy_temperature_records(TPHIDRecord **records, size_t *count,
                                        char *error, size_t error_capacity);
void tp_free_records(void *records);
```

Implement AppleSMC by iterating `IOServiceMatching("AppleSMC")`, preferring the registry entry named `AppleSMCKeysEndpoint`, opening the user client read-only, reading `#KEY`, enumerating indices with command 8, reading metadata with command 9, and reading bytes with command 5. Check both IOKit return codes and the SMC result byte.

Implement IOHID with usage page `0xff00`, usage `5`, event type `15`, and field `15 << 16`. Preserve product, location-like properties, service index, and all finite event values. Release every copied Core Foundation object.

- [ ] **Step 4: Map shim arrays into isolated source results**

`SMCCollector` emits all readable keys in raw mode and decoded temperature candidates otherwise. Unsupported datatypes remain raw records when `--raw` is active. `HIDCollector` emits each finite service event independently and marks values outside `-40...150 C` with a warning rather than dropping them.

- [ ] **Step 5: Run tests and compile both language boundaries**

Run: `cd Tools/ThermalProbe && swift test --filter 'SMCDecoderTests|SensorClassifierTests|ShimMappingTests'`

Expected: PASS and `CThermalProbeShim` compiles without warnings promoted to errors.

- [ ] **Step 6: Commit direct sensor collectors**

```bash
git add Tools/ThermalProbe/Sources/CThermalProbeShim Tools/ThermalProbe/Sources/ThermalProbeCore/SMC.swift Tools/ThermalProbe/Sources/ThermalProbeCore/HID.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ShimMappingTests.swift
git commit -m "feat: collect AppleSMC and IOHID temperatures"
```

### Task 5: Battery, Process Thermal State, IORegistry, And AppleCLPC

**Files:**
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/IOKitCollectors.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/IOKitCollectorTests.swift`

- [ ] **Step 1: Write fixture tests for battery units and registry flattening**

```swift
func testBatteryTemperatureUnitsRemainSourceSpecific() throws {
    let properties: [String: Any] = [
        "Temperature": 3095,
        "VirtualTemperature": 3095,
        "LifetimeData": ["AverageTemperature": 239,
                         "MaximumTemperature": 42,
                         "MinimumTemperature": 14],
        "TimeChargingThermallyLimited": 120
    ]
    let readings = BatteryCollector.map(properties: properties, timestamp: .distantPast)
    XCTAssertEqual(try XCTUnwrap(readings.first { $0.identifier == "Temperature" }?.number), 36.35, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(readings.first { $0.identifier == "LifetimeData.AverageTemperature" }?.number), 23.9, accuracy: 0.01)
}

func testRegistryWalkerRetainsTypedNestedPath() {
    let flattened = RegistryFlattener.flatten(["Thermal": ["Limit": 72, "Enabled": true]])
    XCTAssertEqual(flattened["Thermal.Limit"], .number(72))
    XCTAssertEqual(flattened["Thermal.Enabled"], .bool(true))
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `cd Tools/ThermalProbe && swift test --filter IOKitCollectorTests`

Expected: FAIL because the collectors do not exist.

- [ ] **Step 3: Implement the four collectors**

`BatteryCollector` reads `AppleSmartBattery` and `AppleSmartBatteryPack` through `IORegistryEntryCreateCFProperties`. Root battery current/virtual temperature uses `raw / 10 - 273.15`; pack temperature uses `raw / 100`; lifetime average uses `raw / 10`; lifetime min/max are Celsius; thermally limited charging time is seconds.

`ProcessThermalStateCollector` maps `ProcessInfo.processInfo.thermalState` to nominal, fair, serious, or critical as a textual thermal-pressure reading.

`IORegistryThermalCollector` iterates the IOService plane recursively and emits scalar properties whose full property path contains `temp` or `thermal`, preserving service class, registry path, property path, and typed value.

For services named or classed `AppleCLPC`, additionally emit scalar properties containing `limit`, `target`, `power`, `cpu`, `gpu`, or `die` as `.rawContext`; do not assign Celsius or watt units to undocumented fields.

- [ ] **Step 4: Run the collector tests**

Run: `cd Tools/ThermalProbe && swift test --filter IOKitCollectorTests`

Expected: PASS.

- [ ] **Step 5: Commit IOKit collectors**

```bash
git add Tools/ThermalProbe/Sources/ThermalProbeCore/IOKitCollectors.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/IOKitCollectorTests.swift
git commit -m "feat: collect battery and registry thermals"
```

### Task 6: Bounded Command Runner And Built-In Command Collectors

**Files:**
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/CommandRunner.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/CommandCollectors.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CommandRunnerTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CommandParserTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/Fixtures/pmset-nominal.txt`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/Fixtures/powermetrics-sample.txt`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/Fixtures/powermetrics-sample.plist`

- [ ] **Step 1: Write timeout, pmset, and powermetrics parser tests**

```swift
func testRunnerTimesOutAndReturnsBoundedDiagnostics() throws {
    let result = try ProcessCommandRunner(maximumBytes: 1024).run(
        executable: "/bin/sleep", arguments: ["2"], timeout: 0.05)
    XCTAssertTrue(result.timedOut)
}

func testPMSetNominalOutputDoesNotInventTemperature() {
    let result = PMSetParser.parse("""
    Note: No thermal warning level has been recorded
    Note: No performance warning level has been recorded
    Note: No CPU power status has been recorded
    """, timestamp: .distantPast)
    XCTAssertEqual(result.filter { $0.kind == .thermalPressure }.first?.value, .text("nominal"))
    XCTAssertFalse(result.contains { $0.kind == .temperature })
}

func testPowermetricsTextExtractsContextFields() throws {
    let readings = PowermetricsParser.parseText("""
    CPU Power: 1234 mW
    GPU Power: 456 mW
    Thermal pressure: moderate
    SFI Class 2: 37% forced idle
    CPU Power limit: 68%
    """, timestamp: .distantPast)
    XCTAssertEqual(try XCTUnwrap(readings.first { $0.identifier == "CPU Power" }?.number), 1.234, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(readings.first { $0.kind == .powerLimit }?.number), 68)
}
```

- [ ] **Step 2: Run the command tests and verify they fail**

Run: `cd Tools/ThermalProbe && swift test --filter 'CommandRunnerTests|CommandParserTests'`

Expected: FAIL because command runner and parser types do not exist.

- [ ] **Step 3: Implement bounded execution**

`ProcessCommandRunner` must drain stdout and stderr concurrently, append at most 16 MiB combined while continuing to drain excess bytes, wait with a monotonic timeout, call `terminate()`, then send `SIGKILL` after a 500 ms grace period. The returned `CommandResult` contains executable, arguments, status, stdout, stderr, timeout, truncation, start time, and duration.

- [ ] **Step 4: Implement source collectors**

`PowermetricsCollector` parses `/usr/bin/powermetrics --help`, intersects `thermal,cpu_power,gpu_power,ane_power,battery,sfi` with supported samplers, and runs one 1000 ms sample with `--show-plimits --handle-invalid-values`. Prefer `--format plist`; split NUL-separated plist records and flatten relevant temperature, thermal, pressure, forced-idle, power, and limit paths. If plist parsing fails, rerun text format and use the text parser. Record absent `smc` support as a capability warning, not a failure. Timeout is 15 seconds.

`PMSetCollector` runs `/usr/bin/pmset -g therm` with a 5-second timeout.

`CapabilityProbeCollector` runs `/usr/sbin/sysctl -a` and `/usr/sbin/system_profiler SPPowerDataType -json` with 5-second timeouts, retains only flattened fields whose paths contain `temp` or `thermal`, and reports success with zero readings when no such fields exist.

- [ ] **Step 5: Run parser and runner tests**

Run: `cd Tools/ThermalProbe && swift test --filter 'CommandRunnerTests|CommandParserTests'`

Expected: PASS.

- [ ] **Step 6: Commit built-in command collectors**

```bash
git add Tools/ThermalProbe/Sources/ThermalProbeCore/CommandRunner.swift Tools/ThermalProbe/Sources/ThermalProbeCore/CommandCollectors.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CommandRunnerTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CommandParserTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/Fixtures
git commit -m "feat: collect macOS thermal command telemetry"
```

### Task 7: Dynamically Loaded IOReport Inventory

**Files:**
- Modify: `Tools/ThermalProbe/Sources/CThermalProbeShim/include/ThermalProbeShim.h`
- Modify: `Tools/ThermalProbe/Sources/CThermalProbeShim/ThermalProbeShim.c`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/IOReport.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/IOReportTests.swift`

- [ ] **Step 1: Write record-mapping tests**

```swift
func testIOReportUnknownUnitRemainsRawContext() {
    let raw = IOReportRawRecord(group: "Thermal", subgroup: "CPU",
        channel: "CPU Thermal Status", unit: "ticks", state: nil, value: 17)
    let reading = IOReportCollector.map(raw, timestamp: .distantPast)
    XCTAssertEqual(reading.kind, .rawContext)
    XCTAssertEqual(reading.unit, "ticks")
    XCTAssertEqual(reading.metadata["group"], .string("Thermal"))
}

func testIOReportTemperatureNameWithoutCelsiusUnitIsNotRelabelled() {
    let raw = IOReportRawRecord(group: "Thermal", subgroup: "", channel: "Target",
        unit: "level", state: nil, value: 2)
    XCTAssertNotEqual(IOReportCollector.map(raw, timestamp: .distantPast).kind, .temperature)
}
```

- [ ] **Step 2: Run the IOReport tests and verify they fail**

Run: `cd Tools/ThermalProbe && swift test --filter IOReportTests`

Expected: FAIL because IOReport records and mapping do not exist.

- [ ] **Step 3: Extend the C shim with dynamically resolved IOReport symbols**

Add:

```c
typedef struct {
    char group[96];
    char subgroup[96];
    char channel[192];
    char unit[48];
    char state[96];
    int32_t state_index;
    int64_t value;
} TPIOReportRecord;

int32_t tp_ioreport_copy_records(uint32_t sample_milliseconds,
    TPIOReportRecord **records, size_t *count, char *error, size_t error_capacity);
```

Open `/usr/lib/libIOReport.dylib` with `dlopen`. Resolve `IOReportCopyAllChannels`, `IOReportCreateSubscription`, `IOReportCreateSamples`, `IOReportCreateSamplesDelta`, group/subgroup/channel/unit accessors, simple value access, and state accessors with `dlsym`. Copy all channels into a mutable dictionary, create a subscription, sample twice 100 ms apart, compute a delta, and append one simple record plus one record per state residency. Return a descriptive unavailable error when the dylib or a required symbol is absent.

- [ ] **Step 4: Implement conservative Swift mapping**

Every channel retains group, subgroup, channel, unit, state, and raw integer. Only documented unit labels map to `.power`, `.duration`, or `.temperature`; unknown units and undocumented Thermal-group scalars map to `.rawContext`.

- [ ] **Step 5: Run the IOReport tests and compile the dynamic boundary**

Run: `cd Tools/ThermalProbe && swift test --filter IOReportTests`

Expected: PASS without linking against an SDK IOReport stub.

- [ ] **Step 6: Commit IOReport collection**

```bash
git add Tools/ThermalProbe/Sources/CThermalProbeShim Tools/ThermalProbe/Sources/ThermalProbeCore/IOReport.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/IOReportTests.swift
git commit -m "feat: inventory IOReport thermal context"
```

### Task 8: Aggregation, Rendering, Coordinator, And Executable

**Files:**
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/Aggregation.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/Rendering.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbeCore/CaptureCoordinator.swift`
- Create: `Tools/ThermalProbe/Sources/ThermalProbe/main.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/AggregationTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/RenderingTests.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CoordinatorTests.swift`

- [ ] **Step 1: Write aggregation, streaming, and interval tests**

```swift
func testRepeatedAggregationCalculatesMinAverageMaxAndDelta() {
    let readings = [40.0, 44.0, 48.0].enumerated().map {
        ThermalFixtures.sample(index: $0.offset, source: "smc", identifier: "Tp01", value: $0.element)
    }
    let aggregate = CaptureAggregator.aggregate(readings).first!
    XCTAssertEqual(aggregate.minimum, 40)
    XCTAssertEqual(aggregate.average, 44)
    XCTAssertEqual(aggregate.maximum, 48)
    XCTAssertEqual(aggregate.delta, 8)
}

func testJSONLHasSampleRecordsAndFinalSummaryRecord() throws {
    let lines = try JSONLinesRenderer.render(capture: ThermalFixtures.capture(sampleCount: 2))
        .split(separator: "\n")
    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(try ProbeJSON.decoder.decode(StreamRecord.self, from: Data(lines[0].utf8)).tag, .sample)
    XCTAssertEqual(try ProbeJSON.decoder.decode(StreamRecord.self, from: Data(lines[2].utf8)).tag, .summary)
}

func testCoordinatorRecordsIntervalOverrun() {
    let clock = FixtureClock()
    let capture = CaptureCoordinator(clock: clock).capture(options: .repeated(samples: 2, interval: 100),
        collectors: [FixtureCollector.temperature("smc", 42, clock: clock, advanceSeconds: 0.2)])
    XCTAssertTrue(capture.warnings.contains { $0.contains("overrun") })
}
```

- [ ] **Step 2: Run orchestration tests and verify they fail**

Run: `cd Tools/ThermalProbe && swift test --filter 'AggregationTests|RenderingTests|CoordinatorTests'`

Expected: FAIL because aggregation, rendering, and coordination do not exist.

- [ ] **Step 3: Implement summaries and renderers**

Group repeated numeric readings by source plus identifier so two sources are never deduplicated. Calculate min, arithmetic mean, max, and last-minus-first delta. Human output begins with host and source-status tables, then prints every normalized reading grouped by category and source, then capture aggregates. Raw mode includes unsupported SMC records and source metadata.

JSON emits one `CaptureEnvelope`. JSONL emits one tagged, self-contained sample record immediately after each sample and one tagged summary record at completion. Structured output goes only to stdout; human diagnostics go to stderr.

- [ ] **Step 4: Implement deterministic repeated collection**

Use this collector order: SMC, IOHID, AppleSmartBattery, ProcessInfo, IOReport, powermetrics, pmset, IORegistry/AppleCLPC, capability probes. Measure sample-start intervals with a monotonic clock. Sleep only for the remaining interval; if collection exceeds it, append an overrun warning and continue immediately.

- [ ] **Step 5: Implement the root-only executable**

`main.swift` parses arguments, prints help without collecting, evaluates `geteuid()`, constructs all collectors, captures samples, renders the selected format, writes diagnostics to stderr, and exits 0 when at least one source contains readings, 1 when none do, 64 for usage, or 77 for non-root. Install signal handlers that terminate child processes through the command-runner registry before exiting with `128 + signal`.

- [ ] **Step 6: Run all unit tests and a release build**

Run: `cd Tools/ThermalProbe && swift test && swift build -c release --product thermal-probe`

Expected: all tests PASS and `.build/release/thermal-probe` exists.

- [ ] **Step 7: Commit the complete executable flow**

```bash
git add Tools/ThermalProbe/Sources/ThermalProbeCore/Aggregation.swift Tools/ThermalProbe/Sources/ThermalProbeCore/Rendering.swift Tools/ThermalProbe/Sources/ThermalProbeCore/CaptureCoordinator.swift Tools/ThermalProbe/Sources/ThermalProbe/main.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/AggregationTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/RenderingTests.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/CoordinatorTests.swift
git commit -m "feat: add thermal probe CLI output modes"
```

### Task 9: Documentation, Attribution, And End-To-End Validation

**Files:**
- Create: `Tools/ThermalProbe/README.md`
- Create: `Tools/ThermalProbe/THIRD_PARTY_NOTICES.md`
- Create: `Tools/ThermalProbe/Validation/ThermalLoad.swift`
- Create: `Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ProjectIsolationTests.swift`

- [ ] **Step 1: Write the isolation test**

```swift
func testProductionPackageDoesNotReferenceThermalProbe() throws {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let package = try String(contentsOf: repo.appendingPathComponent("Package.swift"))
    XCTAssertFalse(package.contains("ThermalProbe"))
}
```

- [ ] **Step 2: Document exact use and source boundaries**

README commands:

```bash
cd Tools/ThermalProbe
swift test
swift build -c release --product thermal-probe
sudo .build/release/thermal-probe
sudo .build/release/thermal-probe --raw --json > thermal-capture.json
sudo .build/release/thermal-probe --jsonl --samples 10 --interval 1000 > thermal-capture.jsonl
```

Document that private interfaces may disappear, values are diagnostic rather than safety controls, unknown units remain raw, and this tool does not modify hardware. Attribute Stats (MIT), MacMonitor (MIT), macmon (MIT), and freedomtan/sensors (BSD-3-Clause); include applicable copyright and license text for any adapted portions.

- [ ] **Step 3: Run non-root policy and complete automated verification**

Run:

```bash
cd Tools/ThermalProbe
swift test
swift build -c release --product thermal-probe
.build/release/thermal-probe >/tmp/thermal-probe-nonroot.out 2>/tmp/thermal-probe-nonroot.err; test $? -eq 77
```

Expected: tests and build pass; non-root execution exits 77 and performs no collection.

- [ ] **Step 4: Run one-shot root human and raw JSON captures**

Run:

```bash
cd Tools/ThermalProbe
sudo .build/release/thermal-probe | tee /tmp/thermal-probe-human.txt
sudo .build/release/thermal-probe --raw --json > /tmp/thermal-probe-raw.json
/usr/bin/plutil -lint /tmp/thermal-probe-raw.json >/dev/null
```

Expected: exit 0; every configured source has a visible status; JSON validates; SMC and IOHID contain broad inventories; known M4 CPU and GPU keys are present when exposed by this machine.

- [ ] **Step 5: Run repeated JSONL capture and validate record types**

Run:

```bash
cd Tools/ThermalProbe
sudo .build/release/thermal-probe --raw --jsonl --samples 3 --interval 1000 > /tmp/thermal-probe.jsonl
swift -e 'import Foundation; let s=try String(contentsOfFile:"/tmp/thermal-probe.jsonl"); let tags=try s.split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }.map { $0["tag"] as! String }; precondition(tags == ["sample","sample","sample","summary"])'
```

Expected: exit 0 and exactly three sample records followed by one summary record.

- [ ] **Step 6: Inspect sensor responsiveness under a controlled load**

Create a validation-only program that runs CPU arithmetic on each active processor while repeatedly dispatching this Metal kernel until a requested deadline:

```swift
import Foundation
import Metal

let seconds = max(1, Int(CommandLine.arguments.dropFirst().first ?? "15") ?? 15)
let deadline = Date().addingTimeInterval(TimeInterval(seconds))
let workers = DispatchGroup()

for seed in 0..<ProcessInfo.processInfo.activeProcessorCount {
    workers.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        var value = Double(seed + 1)
        while Date() < deadline {
            for _ in 0..<100_000 { value = sin(value) * cos(value) + 1.000_001 }
        }
        withExtendedLifetime(value) {}
        workers.leave()
    }
}

if let device = MTLCreateSystemDefaultDevice(),
   let queue = device.makeCommandQueue(),
   let library = try? device.makeLibrary(source: """
   kernel void burn(device float *values [[buffer(0)]], uint id [[thread_position_in_grid]]) {
       float x = values[id];
       for (uint i = 0; i < 1024; ++i) { x = sin(x) * cos(x) + 1.0001f; }
       values[id] = x;
   }
   """, options: nil),
   let function = library.makeFunction(name: "burn"),
   let pipeline = try? device.makeComputePipelineState(function: function),
   let buffer = device.makeBuffer(length: 1_048_576 * MemoryLayout<Float>.stride) {
    while Date() < deadline {
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { break }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1_048_576, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup,
                                                              height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
    }
}

workers.wait()
```

Run:

```bash
cd Tools/ThermalProbe
sudo .build/release/thermal-probe --json --samples 5 --interval 1000 > /tmp/thermal-idle.json
xcrun swiftc -O -framework Foundation -framework Metal Validation/ThermalLoad.swift -o .build/thermal-load
.build/thermal-load 20 & LOAD_PID=$!
sudo .build/release/thermal-probe --json --samples 5 --interval 1000 > /tmp/thermal-loaded.json
wait $LOAD_PID
```

Compare known CPU and GPU sensor aggregates between `/tmp/thermal-idle.json` and `/tmp/thermal-loaded.json`. Record the observed deltas without requiring an exact rise because scheduler and cooling behavior vary.

- [ ] **Step 7: Verify repository isolation and diff hygiene**

Run:

```bash
git status --short
git diff --check
git diff HEAD~1 -- Package.swift Sources Tests .github project.yml BatteryMonitor.xcodeproj
```

Expected: no ThermalProbe integration changes appear in production paths; the pre-existing `ThermalTelemetry.swift` and `ThermalTelemetryTests.swift` edits remain uncommitted and untouched.

- [ ] **Step 8: Commit docs and isolation coverage**

```bash
git add Tools/ThermalProbe/README.md Tools/ThermalProbe/THIRD_PARTY_NOTICES.md Tools/ThermalProbe/Validation/ThermalLoad.swift Tools/ThermalProbe/Tests/ThermalProbeCoreTests/ProjectIsolationTests.swift
git commit -m "docs: document standalone thermal probe"
```

- [ ] **Step 9: Run final verification from a clean tool build directory**

Run: `cd Tools/ThermalProbe && swift package clean && swift test && swift build -c release --product thermal-probe`

Expected: all tests pass and the release executable builds from scratch.
