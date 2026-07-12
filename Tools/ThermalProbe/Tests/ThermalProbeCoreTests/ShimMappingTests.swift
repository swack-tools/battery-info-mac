import Foundation
import XCTest
@testable import ThermalProbeCore

final class ShimMappingTests: XCTestCase {
    private let context = CollectionContext(clock: ShimFixedClock(), includeRaw: false)

    func testSMCRawRecordMapsToTemperatureReading() throws {
        let raw = SMCRawRecord(
            key: "Tp01",
            dataType: "sp78",
            data: [0x3d, 0x40],
            status: 0
        )

        let reading = try XCTUnwrap(
            SMCCollector.map(
                raw: raw,
                timestamp: Date(timeIntervalSince1970: 1),
                includeRaw: true
            )
        )

        XCTAssertEqual(reading.value, .number(61.25))
        XCTAssertEqual(reading.category, .cpu)
        XCTAssertEqual(reading.kind, .temperature)
        XCTAssertEqual(reading.classification, .known)
        XCTAssertEqual(reading.rawDataType, "sp78")
        XCTAssertEqual(reading.rawBytes, [0x3d, 0x40])
    }

    func testUnsupportedSMCRecordOnlyAppearsInRawMode() throws {
        let raw = SMCRawRecord(key: "ABCD", dataType: "ch8*", data: [0x41, 0x42], status: 0)

        XCTAssertNil(try SMCCollector.map(raw: raw, timestamp: .distantPast, includeRaw: false))

        let reading = try XCTUnwrap(
            SMCCollector.map(raw: raw, timestamp: .distantPast, includeRaw: true)
        )
        XCTAssertEqual(reading.kind, .rawContext)
        XCTAssertEqual(reading.value, .text("4142"))
        XCTAssertEqual(reading.rawBytes, [0x41, 0x42])
    }

    func testImplausibleSMCTemperatureIsRetainedWithWarning() throws {
        let raw = SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0xce, 0x00], status: 0)
        let reading = try XCTUnwrap(
            SMCCollector.map(raw: raw, timestamp: .distantPast, includeRaw: false)
        )

        XCTAssertEqual(reading.number, -50)
        XCTAssertTrue(reading.warnings.contains { $0.contains("plausibility") })
    }

    func testHIDRecordPreservesDuplicateServiceIdentity() {
        let first = HIDRawRecord(
            index: 1,
            product: "PMU tdie1",
            location: "1",
            registryID: 100,
            celsius: 55
        )
        let second = HIDRawRecord(
            index: 2,
            product: "PMU tdie1",
            location: "2",
            registryID: 101,
            celsius: 55
        )

        let firstReading = HIDCollector.map(first, timestamp: .distantPast)
        let secondReading = HIDCollector.map(second, timestamp: .distantPast)

        XCTAssertNotEqual(firstReading.identifier, secondReading.identifier)
        XCTAssertEqual(firstReading.category, .pmu)
        XCTAssertEqual(firstReading.metadata["product"], .string("PMU tdie1"))
        XCTAssertEqual(secondReading.metadata["location"], .string("2"))
    }

    func testSMCCollectorKeepsGoodKeysWhenOneKeyCannotDecode() {
        let provider = FixtureSMCProvider(records: [
            SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0x3d, 0x40], status: 0),
            SMCRawRecord(key: "Tp05", dataType: "ui32", data: [0x01], status: 0)
        ])

        let result = SMCCollector(provider: provider).collect(context: context)

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.readings.map(\.identifier), ["Tp01"])
        XCTAssertTrue(result.warnings.contains { $0.contains("Tp05") })
    }

    func testProviderFailureBecomesIsolatedSourceFailure() {
        let result = HIDCollector(provider: FailingHIDProvider()).collect(context: context)

        XCTAssertEqual(result.source, "iohid")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, "iohid_collection_failed")
        XCTAssertTrue(result.readings.isEmpty)
    }
}

private final class ShimFixedClock: ProbeClock {
    var wallNow: Date { Date(timeIntervalSince1970: 100) }
    var monotonicNow: TimeInterval { 10 }
    func sleep(milliseconds _: Int) {}
}

private struct FixtureSMCProvider: SMCRecordProviding {
    let recordsValue: [SMCRawRecord]

    init(records: [SMCRawRecord]) {
        recordsValue = records
    }

    func records() throws -> [SMCRawRecord] {
        recordsValue
    }
}

private struct FailingHIDProvider: HIDRecordProviding {
    func records() throws -> [HIDRawRecord] {
        throw FixtureShimError.failed
    }
}

private enum FixtureShimError: Error {
    case failed
}
