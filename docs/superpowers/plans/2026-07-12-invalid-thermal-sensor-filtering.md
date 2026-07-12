# Invalid Thermal Sensor Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove four confirmed-unreliable SMC and IOHID sensor identities before they enter detailed or summary telemetry.

**Architecture:** Each source mapper owns its source-specific identity rejection. The SMC mapper rejects exact key `TVDi`; the IOHID mapper rejects three normalized product names before constructing a reading, while all other sensor behavior remains unchanged.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest

---

### Task 1: Filter confirmed-unreliable IOHID sensors

**Files:**
- Modify: `Sources/BatteryMonitorThermal/HIDThermalCollector.swift`
- Test: `Tests/BatteryMonitorTests/HIDThermalCollectorTests.swift`

- [x] **Step 1: Write failing mapper tests**

Add tests that pass `PMU tdev1`, `PMU2 tdev1`, and `PMU2 tdev3` through `HIDReadingMapper.map` and assert `nil`. Include whitespace/case variation, then assert that `PMU tdev3` and `PMU2 tdev2` still produce readings.

```swift
func testMapperOmitsConfirmedUnreliablePMUProducts() throws {
    for product in ["PMU tdev1", " pmu2 TDEV1 ", "PMU2 tdev3"] {
        let raw = HIDRawRecord(index: 0, product: product, location: "", registryID: 1, celsius: -21.8)
        XCTAssertNil(try HIDReadingMapper.map(raw), product)
    }
}

func testMapperPreservesSimilarValidPMUProducts() throws {
    for product in ["PMU tdev3", "PMU2 tdev2"] {
        let raw = HIDRawRecord(index: 0, product: product, location: "", registryID: 1, celsius: 50)
        XCTAssertNotNil(try HIDReadingMapper.map(raw), product)
    }
}
```

- [x] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter HIDThermalCollectorTests.testMapperOmitsConfirmedUnreliablePMUProducts
```

Expected: compilation or assertion failure because the mapper still returns a reading for these products.

- [x] **Step 3: Implement normalized identity rejection**

Change `HIDReadingMapper.map` to return `DetailedThermalReading?`, normalize the product with trimming and lowercasing, and return `nil` for the three exact normalized values.

```swift
private static let excludedProducts: Set<String> = [
    "pmu tdev1", "pmu2 tdev1", "pmu2 tdev3"
]

static func map(_ raw: HIDRawRecord) throws -> DetailedThermalReading? {
    let normalizedProduct = raw.product
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !excludedProducts.contains(normalizedProduct) else { return nil }
    // Existing mapping follows unchanged.
}
```

Update the collector to append only non-`nil` mapped readings. Update existing direct mapper tests to unwrap expected readings and `compactMap` optional mapper results where arrays are mapped.

- [x] **Step 4: Run all IOHID tests**

Run:

```bash
swift test --filter HIDThermalCollectorTests
```

Expected: all IOHID tests pass.

### Task 2: Filter the confirmed-unreliable SMC key

**Files:**
- Modify: `Sources/BatteryMonitorThermal/SMCThermalCollector.swift`
- Test: `Tests/BatteryMonitorTests/SMCThermalCollectorTests.swift`

- [x] **Step 1: Write failing mapper tests**

Add one test proving `TVDi` is omitted despite a finite decodable payload and another proving neighboring heuristic key `TVDj` remains emitted.

```swift
func testMapperOmitsConfirmedUnreliableTVDiKey() throws {
    let raw = SMCRawRecord(key: "TVDi", dataType: "ui32", data: [0x0d, 0x00, 0x00, 0x00], status: 0)
    XCTAssertNil(try SMCReadingMapper.map(raw, timestamp: .distantPast))
}

func testMapperPreservesNeighboringHeuristicTemperatureKey() throws {
    let raw = SMCRawRecord(key: "TVDj", dataType: "sp78", data: [0x32, 0x00], status: 0)
    XCTAssertNotNil(try SMCReadingMapper.map(raw, timestamp: .distantPast))
}
```

- [x] **Step 2: Run the focused test and verify failure**

Run:

```bash
swift test --filter SMCThermalCollectorTests.testMapperOmitsConfirmedUnreliableTVDiKey
```

Expected: failure because `TVDi` currently becomes a heuristic temperature reading.

- [x] **Step 3: Implement exact SMC-key rejection**

Add an early return before classification and decoding:

```swift
guard raw.key != "TVDi" else { return nil }
```

- [x] **Step 4: Run all SMC tests**

Run:

```bash
swift test --filter SMCThermalCollectorTests
```

Expected: all SMC tests pass.

### Task 3: Verify the complete change

**Files:**
- Modify: `docs/superpowers/plans/2026-07-12-invalid-thermal-sensor-filtering.md`

- [x] **Step 1: Run formatting and diff checks**

Run:

```bash
git diff --check
```

Expected: no output and exit status 0.

- [x] **Step 2: Run the complete test suite**

Run:

```bash
swift test
```

Expected: all tests pass with zero failures.

- [x] **Step 3: Commit the implementation**

Run:

```bash
git add Sources/BatteryMonitorThermal/HIDThermalCollector.swift Sources/BatteryMonitorThermal/SMCThermalCollector.swift Tests/BatteryMonitorTests/HIDThermalCollectorTests.swift Tests/BatteryMonitorTests/SMCThermalCollectorTests.swift docs/superpowers/plans/2026-07-12-invalid-thermal-sensor-filtering.md
git commit -S -m "fix: exclude unreliable thermal sensors"
```
