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

    func testRawInt64ValueIsPreservedExactlyInStructuredOutput() throws {
        let raw = IOReportRawRecord(
            group: "CPU Stats",
            subgroup: "Residency",
            channel: "Counter",
            unit: "ticks",
            state: nil,
            stateIndex: -1,
            value: Int64.max,
            sampleMilliseconds: 100
        )

        let reading = IOReportCollector.map(raw, timestamp: .distantPast)
        let data = try ProbeJSON.encoder.encode(reading)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let decoded = try ProbeJSON.decoder.decode(Reading.self, from: data)

        XCTAssertEqual((object["rawIntegerValue"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertEqual(decoded.rawIntegerValue, Int64.max)
    }

    func testUnavailableProviderIsReportedWithoutReadings() {
        let context = CollectionContext(clock: IOReportFixedClock(), includeRaw: false)
        let result = IOReportCollector(provider: UnavailableIOReportProvider()).collect(context: context)

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.error?.code, "ioreport_unavailable")
        XCTAssertTrue(result.readings.isEmpty)
    }

    func testCollectorFiltersUnrelatedChannelsUnlessRawModeIsRequested() {
        let records = [
            IOReportRawRecord(
                group: "Energy Model",
                subgroup: "CPU",
                channel: "CPU Energy",
                unit: "nJ",
                state: nil,
                stateIndex: -1,
                value: 100,
                sampleMilliseconds: 100
            ),
            IOReportRawRecord(
                group: "Interface en0",
                subgroup: "Network",
                channel: "Packets",
                unit: "count",
                state: nil,
                stateIndex: -1,
                value: 2,
                sampleMilliseconds: 100
            )
        ]
        let provider = FixtureIOReportProvider(records: records)
        let clock = IOReportFixedClock()

        let normal = IOReportCollector(provider: provider).collect(
            context: CollectionContext(clock: clock, includeRaw: false)
        )
        let raw = IOReportCollector(provider: provider).collect(
            context: CollectionContext(clock: clock, includeRaw: true)
        )

        XCTAssertEqual(normal.readings.map(\.identifier), ["Energy Model/CPU/CPU Energy"])
        XCTAssertEqual(raw.readings.count, 2)
        XCTAssertEqual(raw.capabilities["rawChannelRecordCount"], .number(2))
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

private struct FixtureIOReportProvider: IOReportRecordProviding {
    let recordsValue: [IOReportRawRecord]

    init(records: [IOReportRawRecord]) {
        recordsValue = records
    }

    func records(sampleMilliseconds _: UInt32) throws -> [IOReportRawRecord] {
        recordsValue
    }
}
