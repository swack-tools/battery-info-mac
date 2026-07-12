import XCTest
@testable import ThermalProbeCore

final class AggregationTests: XCTestCase {
    func testRepeatedAggregationCalculatesMinAverageMaxAndDelta() {
        let samples = [40.0, 44.0, 48.0].enumerated().map {
            ThermalFixtures.sample(
                index: $0.offset,
                source: "smc",
                identifier: "Tp01",
                value: $0.element
            )
        }

        let aggregate = CaptureAggregator.aggregate(samples).first

        XCTAssertEqual(aggregate?.minimum, 40)
        XCTAssertEqual(aggregate?.average, 44)
        XCTAssertEqual(aggregate?.maximum, 48)
        XCTAssertEqual(aggregate?.delta, 8)
        XCTAssertEqual(aggregate?.sampleCount, 3)
    }

    func testAggregationNeverDeduplicatesAcrossSources() {
        let first = ThermalFixtures.sample(index: 0, source: "smc", identifier: "temp", value: 40)
        let second = ThermalFixtures.sample(index: 1, source: "iohid", identifier: "temp", value: 40)

        let aggregates = CaptureAggregator.aggregate([first, second])

        XCTAssertEqual(aggregates.count, 2)
        XCTAssertEqual(Set(aggregates.map(\.source)), Set(["smc", "iohid"]))
    }

    func testSampleSummaryOnlyUsesTemperatureReadings() {
        var sample = ThermalFixtures.sample(index: 0, source: "smc", identifier: "Tp01", value: 40)
        sample.sources[0].readings.append(
            Reading(
                source: "smc",
                identifier: "PSTR",
                label: nil,
                category: .cpu,
                kind: .power,
                value: .number(100),
                unit: "W",
                timestamp: sample.startedAt,
                classification: .known
            )
        )

        let summaries = CaptureAggregator.summarize(sample: sample)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].average, 40)
    }
}
