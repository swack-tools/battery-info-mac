import Foundation
import XCTest
@testable import BatteryMonitorShared
@testable import BatteryMonitorThermal

final class ThermalCaptureCoordinatorTests: XCTestCase {
    func testSuccessfulFailedAndThrownCollectorsAreIsolatedInStableOrder() {
        let success = FixtureThermalCollector(
            source: "first",
            result: result(
                source: "first",
                readings: [temperature(source: "first", identifier: "cpu", category: .cpu, value: 72)]
            )
        )
        let failed = FixtureThermalCollector(
            source: "second",
            result: ThermalCollectionResult.failed(source: "second", durationMilliseconds: 2, error: "denied")
        )
        let thrown = ThrowingThermalCollector(source: "third")

        let snapshot = ThermalCaptureCoordinator(collectors: [success, failed, thrown])
            .collect(generatedAt: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(snapshot.detailedReadings.map(\.identifier), ["cpu"])
        XCTAssertEqual(snapshot.thermalReadings.map(\.name), ["CPU"])
        XCTAssertEqual(snapshot.sourceStatuses.map(\.source), ["first", "second", "third"])
        XCTAssertEqual(snapshot.sourceStatuses.map(\.state), [.success, .failed, .failed])
        XCTAssertTrue(snapshot.messages.contains { $0.contains("second") && $0.contains("denied") })
        XCTAssertTrue(snapshot.messages.contains { $0.contains("third") && $0.contains("fixture throw") })
    }

    func testCoordinatorAggregatesSummaryPowersThrottlingAndMostSeverePressure() {
        let first = FixtureThermalCollector(source: "smc", result: result(
            source: "smc",
            readings: [temperature(source: "smc", identifier: "cpu", category: .cpu, value: 77)],
            powers: [
                ComponentPowerReading(name: " CPU ", watts: 3, source: "first"),
                ComponentPowerReading(name: "GPU", watts: 0, source: "first")
            ],
            throttling: ThrottlingStatus(level: "Light", percentage: 20, source: "first"),
            pressure: "Fair"
        ))
        let second = FixtureThermalCollector(source: "powermetrics", result: result(
            source: "powermetrics",
            readings: [temperature(source: "powermetrics", identifier: "gpu", category: .gpu, value: 69)],
            powers: [
                ComponentPowerReading(name: "cpu", watts: 0, source: "second-zero"),
                ComponentPowerReading(name: "CPU", watts: 5, source: "second"),
                ComponentPowerReading(name: "gpu", watts: 2, source: "second")
            ],
            throttling: ThrottlingStatus(level: "Moderate", percentage: 55, source: "second"),
            pressure: "Serious"
        ))
        let third = FixtureThermalCollector(source: "pmset", result: result(
            source: "pmset",
            readings: [],
            powers: [ComponentPowerReading(name: "Gpu", watts: 0, source: "third-zero")],
            throttling: ThrottlingStatus(level: "Heavy", percentage: 90, source: "third"),
            pressure: "Critical"
        ))

        let snapshot = ThermalCaptureCoordinator(collectors: [first, second, third]).collect()

        XCTAssertEqual(snapshot.thermalReadings.map(\.name), ["CPU", "GPU"])
        XCTAssertEqual(snapshot.componentPowers.map { $0.name.lowercased() }, ["cpu", "gpu"])
        XCTAssertEqual(snapshot.componentPowers.map(\.watts), [5, 2])
        XCTAssertEqual(snapshot.componentPowers.map(\.source), ["second", "second"])
        XCTAssertEqual(snapshot.throttling.percentage, 90)
        XCTAssertEqual(snapshot.throttling.source, "third")
        XCTAssertEqual(snapshot.thermalPressure, "Critical")
    }

    func testAllFailedCollectorsStillProduceCompleteBoundedSnapshot() {
        let collectors: [any ThermalCollector] = (0..<30).map { index in
            FixtureThermalCollector(
                source: "failed-\(index)",
                result: ThermalCollectionResult.failed(
                    source: "failed-\(index)",
                    durationMilliseconds: 1,
                    error: String(repeating: "failure detail ", count: 40)
                )
            )
        }

        let snapshot = ThermalCaptureCoordinator(collectors: collectors).collect()

        XCTAssertTrue(snapshot.thermalReadings.isEmpty)
        XCTAssertTrue(snapshot.detailedReadings.isEmpty)
        XCTAssertTrue(snapshot.componentPowers.isEmpty)
        XCTAssertEqual(snapshot.throttling, .nominal(source: "coordinator"))
        XCTAssertNil(snapshot.thermalPressure)
        XCTAssertEqual(snapshot.sourceStatuses.count, 30)
        XCTAssertLessThanOrEqual(snapshot.messages.count, 20)
        XCTAssertTrue(snapshot.messages.allSatisfy { $0.count <= 240 })
    }

    func testPressureFallsBackToStrongestThrottleWhenNoCollectorSuppliesPressure() {
        let collector = FixtureThermalCollector(source: "pmset", result: result(
            source: "pmset",
            readings: [],
            throttling: ThrottlingStatus(level: "Moderate", percentage: 60, source: "pmset")
        ))

        let snapshot = ThermalCaptureCoordinator(collectors: [collector]).collect()

        XCTAssertEqual(snapshot.thermalPressure, "Moderate")
    }

    func testThrottleDerivedPressureCompetesWithExplicitNominalPressure() {
        let nominal = FixtureThermalCollector(source: "processInfo", result: result(
            source: "processInfo",
            readings: [DetailedThermalReading(
                source: "processInfo",
                identifier: "thermalState",
                label: "System thermal state",
                category: .system,
                kind: .thermalPressure,
                textValue: "nominal",
                classification: .known
            )],
            pressure: "Nominal"
        ))
        let throttled = FixtureThermalCollector(source: "powermetrics", result: result(
            source: "powermetrics",
            readings: [],
            throttling: ThrottlingStatus(level: "Moderate", percentage: 60, source: "powermetrics")
        ))

        let snapshot = ThermalCaptureCoordinator(collectors: [nominal, throttled]).collect()

        XCTAssertEqual(snapshot.throttling.percentage, 60)
        XCTAssertEqual(snapshot.throttling.level, "Moderate")
        XCTAssertEqual(snapshot.thermalPressure, "Moderate")
    }

    func testDefaultCollectorOrderIsStable() {
        XCTAssertEqual(
            ThermalCaptureCoordinator.default.sources,
            ["smc", "iohid", "appleSmartBattery", "processInfo", "ioreport", "powermetrics", "pmset", "ioRegistry"]
        )
    }

    private func result(
        source: String,
        readings: [DetailedThermalReading],
        powers: [ComponentPowerReading] = [],
        throttling: ThrottlingStatus? = nil,
        pressure: String? = nil
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: readings,
            status: ThermalSourceStatus(
                source: source,
                state: .success,
                readingCount: readings.count,
                durationMilliseconds: 1
            ),
            componentPowers: powers,
            throttling: throttling,
            thermalPressure: pressure
        )
    }

    private func temperature(
        source: String,
        identifier: String,
        category: ThermalCategory,
        value: Double
    ) -> DetailedThermalReading {
        .temperature(
            source: source,
            identifier: identifier,
            label: identifier,
            category: category,
            celsius: value
        )
    }
}

private struct FixtureThermalCollector: ThermalCollector {
    var source: String
    var result: ThermalCollectionResult
    func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        return result
    }
}

private struct ThrowingThermalCollector: ThermalCollector {
    enum Failure: Error, CustomStringConvertible { case expected; var description: String { "fixture throw" } }
    var source: String
    func collect(at timestamp: Date) throws -> ThermalCollectionResult {
        _ = timestamp
        throw Failure.expected
    }
}
