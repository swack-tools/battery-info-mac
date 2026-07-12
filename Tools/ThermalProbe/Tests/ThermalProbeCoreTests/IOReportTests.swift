import Foundation
import XCTest
@testable import ThermalProbeCore

final class IOReportTests: XCTestCase {
    func testUnknownUnitRemainsRawContext() {
        let raw = IOReportRawRecord(
            group: "Thermal",
            subgroup: "CPU",
            channel: "CPU Thermal Status",
            unit: "ticks",
            state: nil,
            stateIndex: -1,
            value: 17,
            sampleMilliseconds: 100
        )

        let reading = IOReportCollector.map(raw, timestamp: .distantPast)

        XCTAssertEqual(reading.kind, .rawContext)
        XCTAssertEqual(reading.unit, "ticks")
        XCTAssertEqual(reading.metadata["group"], .string("Thermal"))
    }

    func testThermalGroupLevelIsNotRelabelledAsTemperature() {
        let raw = IOReportRawRecord(
            group: "Thermal",
            subgroup: "",
            channel: "Target",
            unit: "level",
            state: nil,
            stateIndex: -1,
            value: 2,
            sampleMilliseconds: 100
        )

        XCTAssertNotEqual(IOReportCollector.map(raw, timestamp: .distantPast).kind, .temperature)
    }

    func testExplicitCelsiusChannelMapsToTemperature() {
        let raw = IOReportRawRecord(
            group: "Thermal",
            subgroup: "GPU",
            channel: "GPU Temperature",
            unit: "C",
            state: nil,
            stateIndex: -1,
            value: 71,
            sampleMilliseconds: 100
        )

        let reading = IOReportCollector.map(raw, timestamp: .distantPast)

        XCTAssertEqual(reading.kind, .temperature)
        XCTAssertEqual(reading.category, .gpu)
        XCTAssertEqual(reading.number, 71)
    }

    func testUnavailableProviderIsReportedWithoutReadings() {
        let context = CollectionContext(clock: IOReportFixedClock(), includeRaw: false)
        let result = IOReportCollector(provider: UnavailableIOReportProvider()).collect(context: context)

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.error?.code, "ioreport_unavailable")
        XCTAssertTrue(result.readings.isEmpty)
    }
}

private final class IOReportFixedClock: ProbeClock {
    var wallNow: Date { Date(timeIntervalSince1970: 100) }
    var monotonicNow: TimeInterval { 10 }
    func sleep(milliseconds _: Int) {}
}

private struct UnavailableIOReportProvider: IOReportRecordProviding {
    func records(sampleMilliseconds _: UInt32) throws -> [IOReportRawRecord] {
        throw ShimProviderError(source: "ioreport", status: -2, message: "dylib unavailable")
    }
}
