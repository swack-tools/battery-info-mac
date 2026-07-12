import Foundation
import XCTest
@testable import ThermalProbeCore

final class CollectorTests: XCTestCase {
    func testFailedCollectorDoesNotSuppressSuccessfulCollector() {
        let clock = FixedClock()
        let context = CollectionContext(clock: clock, includeRaw: false)
        let results = CollectorRunner.run(
            collectors: [FailedCollector(), TemperatureCollector()],
            context: context
        )

        XCTAssertEqual(results.map(\.source), ["smc", "hid"])
        XCTAssertEqual(results.map(\.status), [.failed, .success])
        XCTAssertEqual(results.flatMap(\.readings).count, 1)
        XCTAssertEqual(results[1].readings[0].number, 42)
    }

    func testSourceResultFactoryMarksWarningsAsPartial() {
        let result = SourceResult.completed(
            source: "smc",
            startedAt: .distantPast,
            durationMilliseconds: 5,
            readings: [TemperatureCollector.reading],
            warnings: ["one key could not be read"]
        )

        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.error)
    }
}

private final class FixedClock: ProbeClock {
    var wallNow: Date { Date(timeIntervalSince1970: 100) }
    var monotonicNow: TimeInterval { 10 }
    func sleep(milliseconds _: Int) {}
}

private struct FailedCollector: ThermalCollector {
    let source = "smc"

    func collect(context: CollectionContext) -> SourceResult {
        .failed(
            source: source,
            startedAt: context.clock.wallNow,
            durationMilliseconds: 1,
            code: "fixture",
            message: "unavailable"
        )
    }
}

private struct TemperatureCollector: ThermalCollector {
    let source = "hid"

    static let reading = Reading(
        source: "hid",
        identifier: "PMU tdie1",
        label: "PMU tdie1",
        category: .pmu,
        kind: .temperature,
        value: .number(42),
        unit: "C",
        timestamp: Date(timeIntervalSince1970: 100),
        classification: .known
    )

    func collect(context: CollectionContext) -> SourceResult {
        .completed(
            source: source,
            startedAt: context.clock.wallNow,
            durationMilliseconds: 1,
            readings: [Self.reading]
        )
    }
}
