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

    func testMapperUsesGenericIdentityAndFallbackLabelWhenPropertiesAreEmpty() throws {
        let reading = try HIDReadingMapper.map(HIDRawRecord(
            index: 3,
            product: "",
            location: "",
            registryID: 0,
            celsius: 22
        ))

        XCTAssertEqual(reading.identifier, "sensor:unidentified")
        XCTAssertEqual(reading.label, "Unidentified IOHID temperature")
        XCTAssertEqual(reading.category, .system)
        XCTAssertEqual(reading.classification, .unclassified)
        XCTAssertEqual(reading.warnings, ["stable hardware identity unavailable"])
    }

    func testFallbackIdentityIsStableAcrossPermutedEnumerationIndices() throws {
        let firstOrder = [
            HIDRawRecord(index: 0, product: "CPU Die Temperature", location: "CPU 0", registryID: 0, celsius: 50),
            HIDRawRecord(index: 1, product: "Battery Gas Gauge", location: "Pack", registryID: 0, celsius: 31)
        ]
        let reversedOrder = [
            HIDRawRecord(index: 0, product: "Battery Gas Gauge", location: "Pack", registryID: 0, celsius: 31),
            HIDRawRecord(index: 1, product: "CPU Die Temperature", location: "CPU 0", registryID: 0, celsius: 50)
        ]

        let firstIdentifiers = try firstOrder.map(HIDReadingMapper.map).map(\.identifier).sorted()
        let reversedIdentifiers = try reversedOrder.map(HIDReadingMapper.map).map(\.identifier).sorted()

        XCTAssertEqual(firstIdentifiers, reversedIdentifiers)
        XCTAssertEqual(firstIdentifiers, [
            "sensor:battery-gas-gauge:pack",
            "sensor:cpu-die-temperature:cpu-0"
        ])
    }

    func testCompletelyUnidentifiedSensorUsesGenericStableIdentityAndWarning() throws {
        let reading = try HIDReadingMapper.map(HIDRawRecord(
            index: 99,
            product: "",
            location: "",
            registryID: 0,
            celsius: 22
        ))

        XCTAssertEqual(reading.identifier, "sensor:unidentified")
        XCTAssertEqual(reading.label, "Unidentified IOHID temperature")
        XCTAssertEqual(reading.warnings, ["stable hardware identity unavailable"])
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

    func testAllNonfiniteRecordsFailWithZeroReadableEvents() {
        let provider = FixtureHIDProvider(batch: HIDRecordBatch(
            records: [
                HIDRawRecord(index: 0, product: "CPU temperature", location: "die", registryID: 1, celsius: .nan),
                HIDRawRecord(index: 1, product: "GPU temperature", location: "die", registryID: 2, celsius: .infinity)
            ],
            attemptedCount: 2
        ))

        let result = HIDThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.scannedRecordCount, 2)
        XCTAssertEqual(result.status.error, "IOHID scanned 2 services but produced no readable events")
        XCTAssertEqual(result.status.warnings, [
            "IOHID service 0: nonfinite temperature",
            "IOHID service 1: nonfinite temperature"
        ])
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

    func testConcurrentRepeatedSymbolResolutionUsesOneStableLookup() throws {
        let symbol = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        let backend = ConcurrentDynamicLibraryBackend(symbol: symbol)
        let library = try DynamicSystemLibrary(source: "fixture", path: nil, backend: backend)
        let results = ConcurrentResolutionResults()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                results.append(address: UInt(bitPattern: try library.rawSymbol(named: "StableSymbol")))
            } catch {
                results.append(error: String(describing: error))
            }
        }

        XCTAssertEqual(results.errors, [])
        XCTAssertEqual(results.addresses, Array(repeating: UInt(bitPattern: symbol), count: 32))
        XCTAssertEqual(backend.symbolRequestCount, 1)
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

    func testHIDAPIRetainsDynamicLibraryUntilAPIIsReleased() throws {
        let symbols = [
            "IOHIDEventSystemClientCreate",
            "IOHIDEventSystemClientSetMatching",
            "IOHIDEventSystemClientCopyServices",
            "IOHIDServiceClientCopyProperty",
            "IOHIDServiceClientCopyEvent",
            "IOHIDEventGetFloatValue"
        ]
        let backend = FixtureDynamicLibraryBackend(
            openResult: UnsafeMutableRawPointer(bitPattern: 1),
            symbols: Dictionary(uniqueKeysWithValues: symbols.enumerated().map {
                ($0.element, UnsafeMutableRawPointer(bitPattern: $0.offset + 2)!)
            })
        )
        var library: DynamicSystemLibrary? = try DynamicSystemLibrary(
            source: "iohid",
            path: "/fixture",
            backend: backend
        )
        var api: HIDDynamicAPI? = try HIDDynamicAPI(library: XCTUnwrap(library))

        library = nil
        XCTAssertEqual(backend.closeCount, 0)
        XCTAssertNotNil(api)

        api = nil
        XCTAssertEqual(backend.closeCount, 1)
    }

    func testLiveProviderUsesNumericLocationAndSensorIDsForStableIdentity() throws {
        let backend = FixtureDynamicLibraryBackend(
            openResult: UnsafeMutableRawPointer(bitPattern: 1),
            symbols: hidCFixtureSymbols()
        )
        let library = try DynamicSystemLibrary(source: "iohid", path: "/fixture", backend: backend)
        let provider = LiveHIDRecordProvider(libraryFactory: { library })

        let batch = try provider.recordBatch()
        let identifiers = try batch.records.map(HIDReadingMapper.map).map(\.identifier).sorted()

        XCTAssertEqual(batch.records.map(\.product), ["CPU Temperature", "CPU Temperature"])
        XCTAssertEqual(batch.records.map(\.location), ["101", "202"])
        XCTAssertEqual(identifiers, [
            "sensor:cpu-temperature:101",
            "sensor:cpu-temperature:202"
        ])
    }
}

private final class ConcurrentResolutionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAddresses: [UInt] = []
    private var storedErrors: [String] = []

    var addresses: [UInt] {
        lock.lock()
        defer { lock.unlock() }
        return storedAddresses.sorted()
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }

    func append(address: UInt) {
        lock.lock()
        storedAddresses.append(address)
        lock.unlock()
    }

    func append(error: String) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }
}

private final class ConcurrentDynamicLibraryBackend: DynamicLibraryBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let resolvedSymbol: UnsafeMutableRawPointer
    private var requests = 0

    init(symbol: UnsafeMutableRawPointer) {
        resolvedSymbol = symbol
    }

    var symbolRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func open(path: String?, flags: Int32) -> UnsafeMutableRawPointer? {
        _ = path
        _ = flags
        return UnsafeMutableRawPointer(bitPattern: 1)
    }

    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        _ = handle
        _ = name
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        usleep(2_000)
        return resolvedSymbol
    }

    func close(handle: UnsafeMutableRawPointer) { _ = handle }
    func errorMessage() -> String { "fixture error" }
}

private final class HIDCFixtureState: @unchecked Sendable {
    static let shared = HIDCFixtureState()

    let firstService = NSObject()
    let secondService = NSObject()

    func serviceIndex(_ pointer: UnsafeRawPointer?) -> Int? {
        guard let pointer else { return nil }
        if pointer == UnsafeRawPointer(Unmanaged.passUnretained(firstService).toOpaque()) {
            return 0
        }
        if pointer == UnsafeRawPointer(Unmanaged.passUnretained(secondService).toOpaque()) {
            return 1
        }
        return nil
    }
}

private func hidCFixtureSymbols() -> [String: UnsafeMutableRawPointer] {
    [
        "IOHIDEventSystemClientCreate": unsafeBitCast(
            hidFixtureCreateClient as HIDDynamicAPI.ClientCreate,
            to: UnsafeMutableRawPointer.self
        ),
        "IOHIDEventSystemClientSetMatching": unsafeBitCast(
            hidFixtureSetMatching as HIDDynamicAPI.SetMatching,
            to: UnsafeMutableRawPointer.self
        ),
        "IOHIDEventSystemClientCopyServices": unsafeBitCast(
            hidFixtureCopyServices as HIDDynamicAPI.CopyServices,
            to: UnsafeMutableRawPointer.self
        ),
        "IOHIDServiceClientCopyProperty": unsafeBitCast(
            hidFixtureCopyProperty as HIDDynamicAPI.CopyProperty,
            to: UnsafeMutableRawPointer.self
        ),
        "IOHIDServiceClientCopyEvent": unsafeBitCast(
            hidFixtureCopyEvent as HIDDynamicAPI.CopyEvent,
            to: UnsafeMutableRawPointer.self
        ),
        "IOHIDEventGetFloatValue": unsafeBitCast(
            hidFixtureGetFloatValue as HIDDynamicAPI.GetFloatValue,
            to: UnsafeMutableRawPointer.self
        )
    ]
}

private func hidFixtureCreateClient(_ allocator: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    _ = allocator
    return Unmanaged.passRetained(NSObject()).toOpaque()
}

private func hidFixtureSetMatching(
    _ client: UnsafeMutableRawPointer?,
    _ matching: UnsafeRawPointer?
) -> Int32 {
    _ = client
    _ = matching
    return 1
}

private func hidFixtureCopyServices(_ client: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    _ = client
    let state = HIDCFixtureState.shared
    return Unmanaged.passRetained(NSArray(objects: state.firstService, state.secondService)).toOpaque()
}

private func hidFixtureCopyProperty(
    _ service: UnsafeRawPointer?,
    _ property: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let property,
          let serviceIndex = HIDCFixtureState.shared.serviceIndex(service) else {
        return nil
    }
    let key = Unmanaged<CFString>
        .fromOpaque(UnsafeMutableRawPointer(mutating: property))
        .takeUnretainedValue() as String
    let value: AnyObject?
    switch (key, serviceIndex) {
    case ("Product", _):
        value = "CPU Temperature" as NSString
    case ("LocationID", 0):
        value = NSNumber(value: 101)
    case ("SensorID", 1):
        value = NSNumber(value: 202)
    default:
        value = nil
    }
    guard let value else { return nil }
    return Unmanaged.passRetained(value).toOpaque()
}

private func hidFixtureCopyEvent(
    _ service: UnsafeRawPointer?,
    _ eventType: Int64,
    _ options: Int32,
    _ timeout: Int64
) -> UnsafeMutableRawPointer? {
    _ = service
    _ = eventType
    _ = options
    _ = timeout
    return Unmanaged.passRetained(NSObject()).toOpaque()
}

private func hidFixtureGetFloatValue(_ event: UnsafeRawPointer?, _ field: Int32) -> Double {
    _ = event
    _ = field
    return 50
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
    private(set) var closeCount = 0

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
        closeCount += 1
    }

    func errorMessage() -> String { "fixture loader error" }
}
