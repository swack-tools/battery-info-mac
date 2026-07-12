import BatteryMonitorShared
import Foundation
import XCTest
@testable import BatteryMonitorThermal

final class HIDThermalCollectorTests: XCTestCase {
    func testClassifierMapsKnownProductFamilies() {
        let cases: [(String, ThermalCategory)] = [
            ("CPU Die Temperature", .cpu),
            ("GPU Die Temperature", .gpu),
            ("Battery Gas Gauge", .battery),
            ("NAND temperature", .storage),
            ("Storage temperature", .storage),
            ("PMU temperature", .pmu),
            ("Enclosure Bottom", .enclosure),
            ("System temperature", .system)
        ]

        for (product, expected) in cases {
            XCTAssertEqual(HIDSensorClassifier.category(for: product), expected, product)
        }
    }

    func testMapperBuildsStableTemperatureIdentityAndLabel() throws {
        let raw = HIDRawRecord(
            index: 7,
            product: "CPU Die Temperature",
            location: "CPU 0",
            registryID: 42,
            celsius: 61.25
        )

        let reading = try HIDReadingMapper.map(raw)

        XCTAssertEqual(reading.source, "iohid")
        XCTAssertEqual(reading.identifier, "registry-42:cpu-die-temperature:cpu-0")
        XCTAssertEqual(reading.label, "CPU Die Temperature")
        XCTAssertEqual(reading.category, .cpu)
        XCTAssertEqual(reading.kind, .temperature)
        XCTAssertEqual(reading.numericValue, 61.25)
        XCTAssertEqual(reading.unit, "C")
        XCTAssertEqual(reading.classification, .heuristic)
        XCTAssertEqual(reading.warnings, [])
    }

    func testMapperUsesIndexIdentityAndFallbackLabelWhenPropertiesAreEmpty() throws {
        let reading = try HIDReadingMapper.map(HIDRawRecord(
            index: 3,
            product: "",
            location: "",
            registryID: 0,
            celsius: 22
        ))

        XCTAssertEqual(reading.identifier, "index-3:temperature")
        XCTAssertEqual(reading.label, "IOHID temperature 3")
        XCTAssertEqual(reading.category, .system)
        XCTAssertEqual(reading.classification, .unclassified)
    }

    func testMapperPreservesImplausibleFiniteValueWithWarning() throws {
        let reading = try HIDReadingMapper.map(HIDRawRecord(
            index: 0,
            product: "GPU temperature",
            location: "die",
            registryID: 9,
            celsius: 151
        ))

        XCTAssertEqual(reading.numericValue, 151)
        XCTAssertEqual(reading.warnings, [
            "temperature is outside the -40...150 C plausibility range"
        ])
    }

    func testMapperRejectsNonfiniteValues() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try HIDReadingMapper.map(HIDRawRecord(
                index: 0,
                product: "CPU temperature",
                location: "die",
                registryID: 1,
                celsius: value
            ))) { error in
                XCTAssertEqual(error as? HIDReadingMappingError, .nonFiniteTemperature)
            }
        }
    }

    func testInjectedProviderReportsAttemptedCountWithoutLiveIOHID() {
        let provider = FixtureHIDProvider(batch: HIDRecordBatch(
            records: [HIDRawRecord(
                index: 0,
                product: "CPU temperature",
                location: "die",
                registryID: 1,
                celsius: 50
            )],
            attemptedCount: 2
        ))

        let result = HIDThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings.map(\.identifier), ["registry-1:cpu-temperature:die"])
        XCTAssertEqual(result.status.source, "iohid")
        XCTAssertEqual(result.status.state, .success)
        XCTAssertEqual(result.status.readingCount, 1)
        XCTAssertEqual(result.status.scannedRecordCount, 2)
        XCTAssertEqual(result.status.warnings, [])
    }

    func testInjectedProviderPreservesPartialWarningsAndBoundsThem() {
        let warnings = (0..<25).map { "IOHID service \($0): event unavailable" }
        let provider = FixtureHIDProvider(batch: HIDRecordBatch(
            records: [HIDRawRecord(
                index: 0,
                product: "Battery Gas Gauge",
                location: "pack",
                registryID: 11,
                celsius: 31
            )],
            attemptedCount: 26,
            warnings: warnings
        ))

        let result = HIDThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.status.scannedRecordCount, 26)
        XCTAssertEqual(result.status.warnings.count, 20)
        XCTAssertEqual(result.status.warnings.first, "IOHID service 0: event unavailable")
        XCTAssertEqual(result.status.warnings.last, "6 additional IOHID warnings omitted")
    }

    func testNonfiniteRecordIsOmittedAndReportedAsPartial() {
        let provider = FixtureHIDProvider(batch: HIDRecordBatch(
            records: [
                HIDRawRecord(index: 0, product: "CPU temperature", location: "die", registryID: 1, celsius: 48),
                HIDRawRecord(index: 1, product: "GPU temperature", location: "die", registryID: 2, celsius: .nan)
            ],
            attemptedCount: 2
        ))

        let result = HIDThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings.map(\.identifier), ["registry-1:cpu-temperature:die"])
        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.status.scannedRecordCount, 2)
        XCTAssertEqual(result.status.warnings, ["IOHID service 1: nonfinite temperature"])
    }

    func testNoMatchingServicesIsUnavailable() {
        let error = HIDProviderError(kind: .unavailable, message: "IOHID found no matching temperature services")

        let result = HIDThermalCollector(provider: ThrowingHIDProvider(error: error))
            .collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .unavailable)
        XCTAssertEqual(result.status.scannedRecordCount, 0)
        XCTAssertEqual(result.status.error, "IOHID found no matching temperature services")
    }

    func testServicesWithoutReadableEventsFail() {
        let provider = FixtureHIDProvider(batch: HIDRecordBatch(
            records: [],
            attemptedCount: 4,
            warnings: ["IOHID service 0: event unavailable"]
        ))

        let result = HIDThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.scannedRecordCount, 4)
        XCTAssertEqual(result.status.error, "IOHID scanned 4 services but produced no readable events")
        XCTAssertEqual(result.status.warnings, ["IOHID service 0: event unavailable"])
    }

    func testProviderFailureIsFailed() {
        let error = HIDProviderError(kind: .failed, message: "IOHID service copy failed")

        let result = HIDThermalCollector(provider: ThrowingHIDProvider(error: error))
            .collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.error, "IOHID service copy failed")
    }

    func testDynamicLibraryMissingLibraryAndSymbolUseTypedUnavailableErrors() throws {
        let missingLibrary = FixtureDynamicLibraryBackend(openResult: nil)
        XCTAssertThrowsError(
            try DynamicSystemLibrary(source: "iohid", path: "/missing", backend: missingLibrary)
        ) { error in
            XCTAssertEqual(
                error as? DynamicSystemLibraryError,
                .libraryUnavailable(source: "iohid", path: "/missing", detail: "fixture loader error")
            )
        }

        let missingSymbol = FixtureDynamicLibraryBackend(
            openResult: UnsafeMutableRawPointer(bitPattern: 1),
            symbols: [:]
        )
        let library = try DynamicSystemLibrary(source: "iohid", path: nil, backend: missingSymbol)
        XCTAssertThrowsError(try library.rawSymbol(named: "MissingSymbol")) { error in
            XCTAssertEqual(
                error as? DynamicSystemLibraryError,
                .symbolUnavailable(source: "iohid", symbol: "MissingSymbol", detail: "fixture loader error")
            )
        }
        XCTAssertThrowsError(try library.rawSymbol(named: "MissingSymbol"))
        XCTAssertEqual(missingSymbol.symbolRequests, ["MissingSymbol"])
    }

    func testInjectedHIDMissingSymbolMapsToUnavailableWithoutCallingHostAPI() throws {
        let backend = FixtureDynamicLibraryBackend(
            openResult: UnsafeMutableRawPointer(bitPattern: 1),
            symbols: ["IOHIDEventSystemClientCreate": UnsafeMutableRawPointer(bitPattern: 2)!]
        )
        let library = try DynamicSystemLibrary(source: "iohid", path: "/fixture", backend: backend)
        let provider = LiveHIDRecordProvider(libraryFactory: { library })

        let result = HIDThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .unavailable)
        XCTAssertTrue(result.status.error?.contains("IOHIDEventSystemClientSetMatching") == true)
        XCTAssertEqual(backend.symbolRequests, [
            "IOHIDEventSystemClientCreate",
            "IOHIDEventSystemClientSetMatching"
        ])
    }
}

private struct FixtureHIDProvider: HIDRecordProviding {
    let batch: HIDRecordBatch

    func recordBatch() throws -> HIDRecordBatch { batch }
}

private struct ThrowingHIDProvider: HIDRecordProviding {
    let error: HIDProviderError

    func recordBatch() throws -> HIDRecordBatch { throw error }
}

private final class FixtureDynamicLibraryBackend: DynamicLibraryBackend, @unchecked Sendable {
    let openResult: UnsafeMutableRawPointer?
    let symbols: [String: UnsafeMutableRawPointer]
    private(set) var symbolRequests: [String] = []

    init(
        openResult: UnsafeMutableRawPointer?,
        symbols: [String: UnsafeMutableRawPointer] = [:]
    ) {
        self.openResult = openResult
        self.symbols = symbols
    }

    func open(path: String?, flags: Int32) -> UnsafeMutableRawPointer? {
        _ = flags
        return openResult
    }

    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        _ = handle
        symbolRequests.append(name)
        return symbols[name]
    }

    func close(handle: UnsafeMutableRawPointer) {
        _ = handle
    }

    func errorMessage() -> String { "fixture loader error" }
}
