# Estimated Battery Throughput Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the undocumented Lifetime Energy estimate with cycle-derived battery throughput for models with a verified Apple-rated battery capacity.

**Architecture:** A pure `BatterySpecificationCatalog` maps stable Mac model identifiers to rated watt-hours, and `BatteryThroughputEstimator` calculates cycle-equivalent kWh. `BatteryDisplayInfo` formats the estimate while Advanced Diagnostics displays it under an accurate label; unknown models produce no row.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, SwiftUI

---

### Task 1: Add the battery specification and throughput calculation

**Files:**
- Modify: `Sources/BatteryMonitor/BatteryData.swift`
- Create: `Tests/BatteryMonitorTests/BatteryThroughputTests.swift`

- [ ] **Step 1: Write failing catalog and estimator tests**

Create tests covering the verified model, unknown models, the 311-cycle result, and invalid cycle counts.

```swift
import XCTest
@testable import BatteryMonitor

final class BatteryThroughputTests: XCTestCase {
    func testCatalogReturnsVerifiedM4AirCapacity() {
        XCTAssertEqual(BatterySpecificationCatalog.ratedWattHours(for: "Mac16,12"), 53.8)
    }

    func testCatalogReturnsNilForUnknownModel() {
        XCTAssertNil(BatterySpecificationCatalog.ratedWattHours(for: "UnknownMac1,1"))
    }

    func testEstimatorCalculatesCycleEquivalentKilowattHours() throws {
        let result = try XCTUnwrap(BatteryThroughputEstimator.kilowattHours(cycleCount: 311, modelIdentifier: "Mac16,12"))
        XCTAssertEqual(result, 16.7318, accuracy: 0.000_001)
    }

    func testEstimatorRejectsNonpositiveCyclesAndUnknownModels() {
        XCTAssertNil(BatteryThroughputEstimator.kilowattHours(cycleCount: 0, modelIdentifier: "Mac16,12"))
        XCTAssertNil(BatteryThroughputEstimator.kilowattHours(cycleCount: -1, modelIdentifier: "Mac16,12"))
        XCTAssertNil(BatteryThroughputEstimator.kilowattHours(cycleCount: 311, modelIdentifier: "UnknownMac1,1"))
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter BatteryThroughputTests
```

Expected: compilation fails because the catalog and estimator do not exist.

- [ ] **Step 3: Implement the minimal catalog and estimator**

Add pure model-layer types:

```swift
enum BatterySpecificationCatalog {
    private static let ratedWattHoursByModel = [
        "Mac16,12": 53.8
    ]

    static func ratedWattHours(for modelIdentifier: String) -> Double? {
        ratedWattHoursByModel[modelIdentifier]
    }
}

enum BatteryThroughputEstimator {
    static func kilowattHours(cycleCount: Int, modelIdentifier: String) -> Double? {
        guard cycleCount > 0,
              let wattHours = BatterySpecificationCatalog.ratedWattHours(for: modelIdentifier) else {
            return nil
        }
        let result = Double(cycleCount) * wattHours / 1000.0
        return result.isFinite && result > 0 ? result : nil
    }
}
```

- [ ] **Step 4: Run the focused tests and verify success**

Run:

```bash
swift test --filter BatteryThroughputTests
```

Expected: all four tests pass.

### Task 2: Replace the old data and UI path

**Files:**
- Modify: `Sources/BatteryMonitor/BatteryData.swift`
- Modify: `Sources/BatteryMonitor/IOKitBattery.swift`
- Modify: `Sources/BatteryMonitor/BatteryDisplayInfo.swift`
- Modify: `Sources/BatteryMonitor/BatteryDetailView.swift`
- Modify: `Tests/BatteryMonitorTests/BatteryThroughputTests.swift`
- Modify: `Tests/BatteryMonitorTests/ProjectStructureTests.swift`

- [ ] **Step 1: Write failing display and removal tests**

Add formatter tests:

```swift
func testDisplayFormatsKnownModelThroughput() {
    XCTAssertEqual(
        BatteryDisplayInfo.estimatedBatteryThroughputText(cycleCount: 311, modelIdentifier: "Mac16,12"),
        "~16.7 kWh"
    )
}

func testDisplayOmitsUnknownModelThroughput() {
    XCTAssertNil(
        BatteryDisplayInfo.estimatedBatteryThroughputText(cycleCount: 311, modelIdentifier: "UnknownMac1,1")
    )
}
```

Add a project-structure test that reads the four production files and asserts the old symbols and label are absent while the new label exists.

```swift
func testUndocumentedLifetimeEnergyPathIsRemoved() throws {
    let data = try String(contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/BatteryData.swift"))
    let iokit = try String(contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/IOKitBattery.swift"))
    let display = try String(contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/BatteryDisplayInfo.swift"))
    let view = try String(contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/BatteryDetailView.swift"))

    for source in [data, iokit, display, view] {
        XCTAssertFalse(source.contains("AccumulatedSystemEnergyConsumed"))
        XCTAssertFalse(source.contains("accumulatedSystemEnergy"))
        XCTAssertFalse(source.contains("lifetimeEnergyKWh"))
        XCTAssertFalse(source.contains("Lifetime Energy"))
    }
    XCTAssertTrue(view.contains("Estimated Battery Throughput"))
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter BatteryThroughputTests
swift test --filter ProjectStructureTests.testUndocumentedLifetimeEnergyPathIsRemoved
```

Expected: formatter compilation fails and the old production path remains present.

- [ ] **Step 3: Implement display formatting and remove the old path**

Rename `BatteryDisplayInfo.lifetimeEnergy` to `estimatedBatteryThroughput`. Add:

```swift
static func estimatedBatteryThroughputText(cycleCount: Int, modelIdentifier: String) -> String? {
    guard let value = BatteryThroughputEstimator.kilowattHours(
        cycleCount: cycleCount,
        modelIdentifier: modelIdentifier
    ) else { return nil }
    return String(format: "~%.1f kWh", value)
}
```

In `fetch()`, populate it with `batteryData.cycleCount` and `systemInfo.macModel`. Change the Advanced Diagnostics label to `Estimated Battery Throughput`.

Delete `accumulatedSystemEnergy`, `lifetimeEnergyKWh`, `AccumulatedSystemEnergyConsumed` parsing, and the operating-time/current-power fallback. Preserve `totalOperatingTime`.

- [ ] **Step 4: Run the focused tests and verify success**

Run:

```bash
swift test --filter BatteryThroughputTests
swift test --filter ProjectStructureTests.testUndocumentedLifetimeEnergyPathIsRemoved
```

Expected: all selected tests pass.

### Task 3: Verify and commit

**Files:**
- Modify: `docs/superpowers/plans/2026-07-12-estimated-battery-throughput.md`

- [ ] **Step 1: Run repository checks**

Run:

```bash
git diff --check
just lint
swift test
```

Expected: lint succeeds and all tests pass with zero failures.

- [ ] **Step 2: Commit the implementation**

Run:

```bash
git add Sources/BatteryMonitor/BatteryData.swift Sources/BatteryMonitor/IOKitBattery.swift Sources/BatteryMonitor/BatteryDisplayInfo.swift Sources/BatteryMonitor/BatteryDetailView.swift Tests/BatteryMonitorTests/BatteryThroughputTests.swift Tests/BatteryMonitorTests/ProjectStructureTests.swift docs/superpowers/plans/2026-07-12-estimated-battery-throughput.md
git commit -S -m "fix: estimate battery throughput from cycles"
```
