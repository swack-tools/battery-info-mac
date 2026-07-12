import BatteryMonitorShared
import Foundation
import XCTest
@testable import BatteryMonitorThermal

final class IOReportThermalCollectorTests: XCTestCase {
    func testMapperAcceptsOnlyNormalizedCelsiusTemperatureChannels() {
        for unit in ["C", "°C", "degC", "Celsius", " cELSiUs "] {
            let raw = record(group: "Thermal", channel: "CPU Temperature", unit: unit, value: 57)

            let reading = IOReportReadingMapper.map(raw)

            XCTAssertEqual(reading?.kind, .temperature, unit)
            XCTAssertEqual(reading?.numericValue, 57, unit)
            XCTAssertEqual(reading?.unit, "C", unit)
        }
    }

    func testMapperRejectsNonCelsiusAndNonthermalChannels() {
        let records = [
            record(group: "CPU Stats", channel: "CPU Temperature", unit: "mW"),
            record(group: "GPU Stats", channel: "GPU Energy", unit: "J"),
            record(group: "CPU Stats", channel: "CPU Power", unit: "C"),
            record(group: "CPU Stats", channel: "CPU Residency", unit: "C"),
            record(group: "GPU Stats", channel: "GPU Timing", unit: "C"),
            record(group: "CPU Stats", channel: "CPU Raw Temperature", unit: "C"),
            record(group: "CPU Stats", channel: "CPU Temperature", unit: "ns"),
            record(group: "CPU Stats", channel: "CPU Temperature", unit: "cycles"),
            record(group: "CPU Stats", channel: "CPU Frequency", unit: "C")
        ]

        for raw in records {
            XCTAssertNil(IOReportReadingMapper.map(raw), "\(raw.channel) [\(raw.unit)]")
        }
    }

    func testMapperRejectsStateResidenciesEvenUnderTemperatureChannel() {
        let raw = record(
            group: "Thermal",
            channel: "CPU Temperature",
            unit: "C",
            state: "P1",
            stateIndex: 2,
            value: 10_000
        )

        XCTAssertNil(IOReportReadingMapper.map(raw))
    }

    func testMapperClassifiesThermalCategories() throws {
        let cases: [(String, String, ThermalCategory)] = [
            ("CPU Stats", "CPU Temperature", .cpu),
            ("GPU Stats", "GPU Temperature", .gpu),
            ("Battery", "Battery Temperature", .battery),
            ("DRAM", "Memory Temperature", .memory),
            ("NAND", "Storage Temperature", .storage),
            ("Thermal", "SoC Temperature", .system)
        ]

        for (group, channel, category) in cases {
            let reading = try XCTUnwrap(IOReportReadingMapper.map(
                record(group: group, channel: channel, unit: "C")
            ))
            XCTAssertEqual(reading.category, category, channel)
            XCTAssertEqual(reading.source, "ioreport", channel)
            XCTAssertEqual(reading.classification, .heuristic, channel)
        }
    }

    func testIdentifiersAreStableForChannelsAndStates() {
        let channel = record(group: "Thermal", subgroup: "CPU", channel: "Die Temperature", unit: "C")
        let state = record(
            group: "CPU Stats",
            subgroup: "Cluster 0",
            channel: "Residency",
            unit: "ns",
            state: "P1",
            stateIndex: 2
        )

        XCTAssertEqual(IOReportRecordIdentity.identifier(for: channel), "Thermal/CPU/Die Temperature")
        XCTAssertEqual(
            IOReportRecordIdentity.identifier(for: state),
            "CPU Stats/Cluster 0/Residency/state[2]:P1"
        )
        XCTAssertEqual(
            IOReportReadingMapper.map(channel)?.identifier,
            "Thermal/CPU/Die Temperature"
        )
        XCTAssertEqual(IOReportReadingMapper.map(channel)?.label, "Die Temperature")
    }

    func testImplausibleTemperatureIsPreservedWithWarning() throws {
        let reading = try XCTUnwrap(IOReportReadingMapper.map(
            record(group: "Thermal", channel: "GPU Temperature", unit: "C", value: -41)
        ))

        XCTAssertEqual(reading.numericValue, -41)
        XCTAssertEqual(reading.warnings, [
            "temperature is outside the -40...150 C plausibility range"
        ])
    }

    func testInjectedBatchReportsScannedAndEmittedCountsWithoutSleeping() {
        let provider = FixtureIOReportProvider(batch: IOReportRecordBatch(
            records: [
                record(group: "Thermal", channel: "CPU Temperature", unit: "C", value: 55),
                record(group: "CPU Stats", channel: "CPU Power", unit: "mW", value: 7_000),
                record(group: "CPU Stats", channel: "CPU Residency", unit: "ns", state: "P0", stateIndex: 0)
            ],
            scannedCount: 3
        ))

        let result = IOReportThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings.map(\.identifier), ["Thermal/CPU Temperature"])
        XCTAssertEqual(result.status.source, "ioreport")
        XCTAssertEqual(result.status.state, .success)
        XCTAssertEqual(result.status.readingCount, 1)
        XCTAssertEqual(result.status.scannedRecordCount, 3)
        XCTAssertEqual(result.status.warnings, [])
    }

    func testInjectedBatchWarningsProduceBoundedPartialStatus() {
        let warnings = (0..<25).map { "IOReport record \($0): malformed channel" }
        let provider = FixtureIOReportProvider(batch: IOReportRecordBatch(
            records: [record(group: "Thermal", channel: "GPU Temperature", unit: "C")],
            scannedCount: 26,
            warnings: warnings
        ))

        let result = IOReportThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.status.scannedRecordCount, 26)
        XCTAssertEqual(result.status.warnings.count, 20)
        XCTAssertEqual(result.status.warnings.last, "6 additional IOReport warnings omitted")
    }

    func testCleanBatchWithNoThermalChannelsSucceedsWithZeroReadings() {
        let provider = FixtureIOReportProvider(batch: IOReportRecordBatch(
            records: [record(group: "CPU Stats", channel: "CPU Power", unit: "mW")],
            scannedCount: 1
        ))

        let result = IOReportThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.state, .success)
        XCTAssertEqual(result.status.scannedRecordCount, 1)
    }

    func testEmptyNativeBatchFailsTruthfully() {
        let provider = FixtureIOReportProvider(batch: IOReportRecordBatch(records: [], scannedCount: 0))

        let result = IOReportThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.error, "IOReport returned no channel records")
        XCTAssertEqual(result.status.scannedRecordCount, 0)
    }

    func testTypedProviderErrorsMapToUnavailableAndFailed() {
        let unavailable = IOReportThermalCollector(provider: ThrowingIOReportProvider(error: IOReportProviderError(
            kind: .unavailable,
            message: "IOReport symbol is unavailable"
        ))).collect(at: .distantPast)
        let failed = IOReportThermalCollector(provider: ThrowingIOReportProvider(error: IOReportProviderError(
            kind: .failed,
            message: "IOReport delta sample could not be created"
        ))).collect(at: .distantPast)

        XCTAssertEqual(unavailable.status.state, .unavailable)
        XCTAssertEqual(unavailable.status.error, "IOReport symbol is unavailable")
        XCTAssertEqual(failed.status.state, .failed)
        XCTAssertEqual(failed.status.error, "IOReport delta sample could not be created")
    }

    func testInjectedMissingSymbolIsUnavailableWithoutCallingPrivateAPIOrSleeping() throws {
        let backend = IOReportFixtureDynamicLibraryBackend(
            symbols: ["IOReportCopyAllChannels": UnsafeMutableRawPointer(bitPattern: 1)!]
        )
        let library = try DynamicSystemLibrary(source: "ioreport", path: "/fixture", backend: backend)
        let provider = LiveIOReportRecordProvider(
            libraryFactory: { library },
            sleeper: { _ in XCTFail("missing symbols must fail before sleeping") }
        )

        let result = IOReportThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .unavailable)
        XCTAssertTrue(result.status.error?.contains("IOReportCreateSubscription") == true)
        XCTAssertEqual(backend.symbolRequests, [
            "IOReportCopyAllChannels",
            "IOReportCreateSubscription"
        ])
    }

    private func record(
        group: String,
        subgroup: String = "",
        channel: String,
        unit: String,
        state: String? = nil,
        stateIndex: Int32 = -1,
        value: Int64 = 42
    ) -> IOReportRawRecord {
        IOReportRawRecord(
            group: group,
            subgroup: subgroup,
            channel: channel,
            unit: unit,
            state: state,
            stateIndex: stateIndex,
            value: value
        )
    }
}

private struct FixtureIOReportProvider: IOReportRecordProviding {
    let batch: IOReportRecordBatch

    func recordBatch(sampleMilliseconds: UInt32) throws -> IOReportRecordBatch {
        XCTAssertEqual(sampleMilliseconds, 100)
        return batch
    }
}

private struct ThrowingIOReportProvider: IOReportRecordProviding {
    let error: IOReportProviderError

    func recordBatch(sampleMilliseconds: UInt32) throws -> IOReportRecordBatch {
        _ = sampleMilliseconds
        throw error
    }
}

private final class IOReportFixtureDynamicLibraryBackend: DynamicLibraryBackend, @unchecked Sendable {
    let symbols: [String: UnsafeMutableRawPointer]
    private(set) var symbolRequests: [String] = []

    init(symbols: [String: UnsafeMutableRawPointer]) {
        self.symbols = symbols
    }

    func open(path: String?, flags: Int32) -> UnsafeMutableRawPointer? {
        _ = path
        _ = flags
        return UnsafeMutableRawPointer(bitPattern: 1)
    }

    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        _ = handle
        symbolRequests.append(name)
        return symbols[name]
    }

    func close(handle: UnsafeMutableRawPointer) { _ = handle }
    func errorMessage() -> String { "fixture symbol missing" }
}
