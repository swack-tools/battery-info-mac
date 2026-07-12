import XCTest
@testable import ThermalProbeCore

final class CoordinatorTests: XCTestCase {
    func testCoordinatorRecordsIntervalOverrunAndStreamsEachSample() {
        let clock = FixtureClock()
        let coordinator = CaptureCoordinator(clock: clock, hostProvider: FixtureHostProvider())
        var streamed: [SampleStreamRecord] = []

        let capture = coordinator.capture(
            options: .repeated(samples: 2, interval: 100),
            arguments: [],
            isRoot: true,
            collectors: [
                FixtureCollector.temperature(
                    "smc",
                    42,
                    clock: clock,
                    advanceSeconds: 0.2
                )
            ],
            onSample: { streamed.append($0) }
        )

        XCTAssertEqual(streamed.map(\.sample.index), [0, 1])
        XCTAssertEqual(streamed.first?.host, ThermalFixtures.host)
        XCTAssertEqual(streamed.first?.schemaVersion, CaptureCoordinator.schemaVersion)
        XCTAssertEqual(capture.samples.count, 2)
        XCTAssertTrue(capture.warnings.contains { $0.contains("overrun") })
        XCTAssertEqual(capture.aggregates.first?.sampleCount, 2)
    }

    func testCoordinatorSleepsOnlyRemainingInterval() {
        let clock = FixtureClock()
        let coordinator = CaptureCoordinator(clock: clock, hostProvider: FixtureHostProvider())

        _ = coordinator.capture(
            options: .repeated(samples: 2, interval: 1_000),
            arguments: [],
            isRoot: true,
            collectors: [
                FixtureCollector.temperature(
                    "smc",
                    42,
                    clock: clock,
                    advanceSeconds: 0.25
                )
            ]
        )

        XCTAssertEqual(clock.monotonicNow, 11.25, accuracy: 0.001)
    }

    func testExitCodeRequiresAtLeastOneReading() {
        XCTAssertEqual(ProbeExitCode.forCapture(ThermalFixtures.capture(sampleCount: 1)), 0)

        var empty = ThermalFixtures.capture(sampleCount: 0)
        empty.samples = []
        XCTAssertEqual(ProbeExitCode.forCapture(empty), 1)
    }
}
