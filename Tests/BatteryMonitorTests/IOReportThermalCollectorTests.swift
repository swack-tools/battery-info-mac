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

    func testMapperRejectsNonthermalContextAnywhereInFullPath() {
        let records = [
            record(group: "Energy Model", channel: "CPU Temperature", unit: "C"),
            record(group: "Thermal", subgroup: "GPU Power", channel: "GPU Temperature", unit: "C"),
            record(group: "CPU Residency", channel: "CPU Temperature", unit: "C"),
            record(group: "Thermal", subgroup: "Sample Duration", channel: "SoC Temperature", unit: "C"),
            record(group: "Thermal", subgroup: "Raw Context", channel: "Battery Temperature", unit: "C")
        ]

        for raw in records {
            XCTAssertNil(
                IOReportReadingMapper.map(raw),
                "\(raw.group)/\(raw.subgroup)/\(raw.channel)"
            )
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

    func testBatchMapperInvokesMapperOncePerBaseRecord() {
        let records = [
            record(group: "Thermal", channel: "CPU Temperature", unit: "C"),
            record(group: "CPU Stats", channel: "CPU Power", unit: "mW")
        ]
        var invocationCount = 0

        let mapped = IOReportBatchMapper.map(records) { record in
            invocationCount += 1
            return IOReportReadingMapper.map(record)
        }

        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(mapped.map(\.reading.identifier), ["Thermal/CPU Temperature"])
    }

    func testScanAccumulatorCountsChannelOnceWithoutMaterializingStates() {
        let base = record(group: "CPU Stats", channel: "CPU Residency", unit: "ns")
        var accumulator = IOReportScanAccumulator()

        accumulator.recordChannel(base: base, observedStateCount: 2)
        let batch = accumulator.batch()

        XCTAssertEqual(batch.records, [base])
        XCTAssertEqual(batch.scannedCount, 1)
        XCTAssertEqual(accumulator.observedStateCount, 2)
    }

    func testAllMalformedScanRetainsAttemptCountAndBoundedWarningsInFailedStatus() {
        var accumulator = IOReportScanAccumulator()
        for index in 0..<25 {
            accumulator.recordMalformedEntry(
                warning: "IOReport channel \(index): record is not a dictionary"
            )
        }
        let batch = accumulator.batch()

        XCTAssertEqual(batch.records, [])
        XCTAssertEqual(batch.scannedCount, 25)
        XCTAssertEqual(batch.warnings.count, 20)
        XCTAssertEqual(batch.warnings.first, "IOReport channel 0: record is not a dictionary")
        XCTAssertEqual(batch.warnings.last, "6 additional IOReport warnings omitted")

        let result = IOReportThermalCollector(provider: FixtureIOReportProvider(batch: batch))
            .collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.scannedRecordCount, 25)
        XCTAssertEqual(result.status.warnings, batch.warnings)
        XCTAssertEqual(result.status.error, "IOReport returned no channel records")
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

    func testIOReportAPIRetainsDynamicLibraryUntilAPIIsReleased() throws {
        let symbols = [
            "IOReportCopyAllChannels",
            "IOReportCreateSubscription",
            "IOReportCreateSamples",
            "IOReportCreateSamplesDelta",
            "IOReportChannelGetGroup",
            "IOReportChannelGetSubGroup",
            "IOReportChannelGetChannelName",
            "IOReportChannelGetUnitLabel",
            "IOReportSimpleGetIntegerValue",
            "IOReportStateGetCount",
            "IOReportStateGetNameForIndex",
            "IOReportStateGetResidency"
        ]
        let backend = IOReportFixtureDynamicLibraryBackend(
            symbols: Dictionary(uniqueKeysWithValues: symbols.enumerated().map {
                ($0.element, UnsafeMutableRawPointer(bitPattern: $0.offset + 2)!)
            })
        )
        var library: DynamicSystemLibrary? = try DynamicSystemLibrary(
            source: "ioreport",
            path: "/fixture",
            backend: backend
        )
        var api: IOReportAPI? = try IOReportAPI(library: XCTUnwrap(library))

        library = nil
        XCTAssertEqual(backend.closeCount, 0)
        XCTAssertNotNil(api)

        api = nil
        XCTAssertEqual(backend.closeCount, 1)
    }

    func testLiveProviderSamplesWithSubscribedDescriptorAndReleasesOwnedObjects() throws {
        IOReportCFixtureState.shared.reset(emitSubscribedDescriptor: true)
        let backend = IOReportFixtureDynamicLibraryBackend(symbols: ioReportCFixtureSymbols())
        let library = try DynamicSystemLibrary(source: "ioreport", path: "/fixture", backend: backend)
        let provider = LiveIOReportRecordProvider(
            libraryFactory: { library },
            sleeper: { _ in }
        )

        let batch = try provider.recordBatch(sampleMilliseconds: 1)
        let snapshot = IOReportCFixtureState.shared.snapshot()

        XCTAssertEqual(batch.records.map(\.channel), ["CPU Temperature"])
        XCTAssertEqual(snapshot.sampleDescriptorAddresses, [
            snapshot.subscribedDescriptorAddress,
            snapshot.subscribedDescriptorAddress
        ])
        XCTAssertEqual(snapshot.descriptorAliveDuringSamples, [true, true])
        XCTAssertFalse(snapshot.subscribedDescriptorIsAlive)
        XCTAssertFalse(snapshot.subscriptionIsAlive)
    }

    func testLiveProviderObservesButDoesNotMaterializeStateRows() throws {
        IOReportCFixtureState.shared.reset(emitSubscribedDescriptor: true, stateCount: 3)
        let backend = IOReportFixtureDynamicLibraryBackend(symbols: ioReportCFixtureSymbols())
        let library = try DynamicSystemLibrary(source: "ioreport", path: "/fixture", backend: backend)
        let provider = LiveIOReportRecordProvider(
            libraryFactory: { library },
            sleeper: { _ in }
        )

        let batch = try provider.recordBatch(sampleMilliseconds: 1)
        let snapshot = IOReportCFixtureState.shared.snapshot()

        XCTAssertEqual(batch.records.map(\.channel), ["CPU Temperature"])
        XCTAssertEqual(batch.scannedCount, 1)
        XCTAssertEqual(snapshot.stateCountCalls, 1)
        XCTAssertEqual(snapshot.stateNameCalls, 0)
        XCTAssertEqual(snapshot.stateResidencyCalls, 0)
    }

    func testLiveProviderFailsAndCleansUpWhenSubscriptionOmitsDescriptor() throws {
        IOReportCFixtureState.shared.reset(emitSubscribedDescriptor: false)
        let backend = IOReportFixtureDynamicLibraryBackend(symbols: ioReportCFixtureSymbols())
        let library = try DynamicSystemLibrary(source: "ioreport", path: "/fixture", backend: backend)
        let provider = LiveIOReportRecordProvider(
            libraryFactory: { library },
            sleeper: { _ in XCTFail("missing descriptor must fail before sleeping") }
        )

        XCTAssertThrowsError(try provider.recordBatch(sampleMilliseconds: 1)) { error in
            XCTAssertEqual(
                error as? IOReportProviderError,
                IOReportProviderError(
                    kind: .failed,
                    message: "IOReport subscription returned no subscribed channel descriptor"
                )
            )
        }
        let snapshot = IOReportCFixtureState.shared.snapshot()
        XCTAssertEqual(snapshot.sampleDescriptorAddresses, [])
        XCTAssertFalse(snapshot.subscriptionIsAlive)
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

private struct IOReportCFixtureSnapshot {
    var subscribedDescriptorAddress: UInt?
    var sampleDescriptorAddresses: [UInt?]
    var descriptorAliveDuringSamples: [Bool]
    var subscribedDescriptorIsAlive: Bool
    var subscriptionIsAlive: Bool
    var stateCountCalls: Int
    var stateNameCalls: Int
    var stateResidencyCalls: Int
}

private final class IOReportCFixtureState: @unchecked Sendable {
    static let shared = IOReportCFixtureState()

    private let lock = NSLock()
    private var emitSubscribedDescriptor = true
    private var subscribedDescriptorAddress: UInt?
    private var sampleDescriptorAddresses: [UInt?] = []
    private var descriptorAliveDuringSamples: [Bool] = []
    private weak var subscribedDescriptor: AnyObject?
    private weak var subscription: AnyObject?
    private var returnedStateCount: Int32 = 0
    private var stateCountCalls = 0
    private var stateNameCalls = 0
    private var stateResidencyCalls = 0
    let group = "Thermal" as NSString
    let subgroup = "CPU" as NSString
    let channel = "CPU Temperature" as NSString
    let unit = "C" as NSString

    func reset(emitSubscribedDescriptor: Bool, stateCount: Int32 = 0) {
        lock.lock()
        defer { lock.unlock() }
        self.emitSubscribedDescriptor = emitSubscribedDescriptor
        subscribedDescriptorAddress = nil
        sampleDescriptorAddresses = []
        descriptorAliveDuringSamples = []
        subscribedDescriptor = nil
        subscription = nil
        returnedStateCount = stateCount
        stateCountCalls = 0
        stateNameCalls = 0
        stateResidencyCalls = 0
    }

    func configureSubscription(
        output: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> UnsafeMutableRawPointer {
        let subscription = NSObject()
        lock.lock()
        self.subscription = subscription
        let shouldEmit = emitSubscribedDescriptor
        lock.unlock()

        if shouldEmit {
            let descriptor = NSMutableDictionary()
            let pointer = Unmanaged.passRetained(descriptor).toOpaque()
            lock.lock()
            subscribedDescriptor = descriptor
            subscribedDescriptorAddress = UInt(bitPattern: pointer)
            lock.unlock()
            output?.pointee = pointer
        }
        return Unmanaged.passRetained(subscription).toOpaque()
    }

    func recordSample(descriptor: UnsafeMutableRawPointer?) {
        lock.lock()
        defer { lock.unlock() }
        sampleDescriptorAddresses.append(descriptor.map(UInt.init(bitPattern:)))
        descriptorAliveDuringSamples.append(subscribedDescriptor != nil)
    }

    func recordStateCount() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        stateCountCalls += 1
        return returnedStateCount
    }

    func recordStateName() {
        lock.lock()
        stateNameCalls += 1
        lock.unlock()
    }

    func recordStateResidency() {
        lock.lock()
        stateResidencyCalls += 1
        lock.unlock()
    }

    func snapshot() -> IOReportCFixtureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return IOReportCFixtureSnapshot(
            subscribedDescriptorAddress: subscribedDescriptorAddress,
            sampleDescriptorAddresses: sampleDescriptorAddresses,
            descriptorAliveDuringSamples: descriptorAliveDuringSamples,
            subscribedDescriptorIsAlive: subscribedDescriptor != nil,
            subscriptionIsAlive: subscription != nil,
            stateCountCalls: stateCountCalls,
            stateNameCalls: stateNameCalls,
            stateResidencyCalls: stateResidencyCalls
        )
    }
}

private func ioReportCFixtureSymbols() -> [String: UnsafeMutableRawPointer] {
    [
        "IOReportCopyAllChannels": unsafeBitCast(
            ioReportFixtureCopyAllChannels as IOReportAPI.CopyAllChannels,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportCreateSubscription": unsafeBitCast(
            ioReportFixtureCreateSubscription as IOReportAPI.CreateSubscription,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportCreateSamples": unsafeBitCast(
            ioReportFixtureCreateSamples as IOReportAPI.CreateSamples,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportCreateSamplesDelta": unsafeBitCast(
            ioReportFixtureCreateSamplesDelta as IOReportAPI.CreateSamplesDelta,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportChannelGetGroup": unsafeBitCast(
            ioReportFixtureChannelGroup as IOReportAPI.ChannelString,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportChannelGetSubGroup": unsafeBitCast(
            ioReportFixtureChannelSubgroup as IOReportAPI.ChannelString,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportChannelGetChannelName": unsafeBitCast(
            ioReportFixtureChannelName as IOReportAPI.ChannelString,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportChannelGetUnitLabel": unsafeBitCast(
            ioReportFixtureChannelUnit as IOReportAPI.ChannelString,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportSimpleGetIntegerValue": unsafeBitCast(
            ioReportFixtureSimpleValue as IOReportAPI.SimpleValue,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportStateGetCount": unsafeBitCast(
            ioReportFixtureStateCount as IOReportAPI.StateCount,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportStateGetNameForIndex": unsafeBitCast(
            ioReportFixtureStateName as IOReportAPI.StateName,
            to: UnsafeMutableRawPointer.self
        ),
        "IOReportStateGetResidency": unsafeBitCast(
            ioReportFixtureStateResidency as IOReportAPI.StateResidency,
            to: UnsafeMutableRawPointer.self
        )
    ]
}

private func ioReportFixtureCopyAllChannels(
    _ options: UInt64,
    _ channelType: UInt64
) -> UnsafeMutableRawPointer? {
    _ = options
    _ = channelType
    return Unmanaged.passRetained(NSMutableDictionary()).toOpaque()
}

private func ioReportFixtureCreateSubscription(
    _ allocator: UnsafeRawPointer?,
    _ channels: UnsafeMutableRawPointer?,
    _ subscribedChannels: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ options: UInt64,
    _ callback: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    _ = allocator
    _ = channels
    _ = options
    _ = callback
    return IOReportCFixtureState.shared.configureSubscription(output: subscribedChannels)
}

private func ioReportFixtureCreateSamples(
    _ subscription: UnsafeRawPointer?,
    _ subscribedChannels: UnsafeMutableRawPointer?,
    _ options: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    _ = subscription
    _ = options
    IOReportCFixtureState.shared.recordSample(descriptor: subscribedChannels)
    return Unmanaged.passRetained(NSMutableDictionary()).toOpaque()
}

private func ioReportFixtureCreateSamplesDelta(
    _ first: UnsafeRawPointer?,
    _ second: UnsafeRawPointer?,
    _ options: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    _ = first
    _ = second
    _ = options
    let channel = NSMutableDictionary()
    let delta = NSMutableDictionary()
    delta["IOReportChannels"] = [channel]
    return Unmanaged.passRetained(delta).toOpaque()
}

private func ioReportFixtureChannelGroup(_ channel: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    _ = channel
    return Unmanaged.passUnretained(IOReportCFixtureState.shared.group).toOpaque()
}

private func ioReportFixtureChannelSubgroup(_ channel: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    _ = channel
    return Unmanaged.passUnretained(IOReportCFixtureState.shared.subgroup).toOpaque()
}

private func ioReportFixtureChannelName(_ channel: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    _ = channel
    return Unmanaged.passUnretained(IOReportCFixtureState.shared.channel).toOpaque()
}

private func ioReportFixtureChannelUnit(_ channel: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    _ = channel
    return Unmanaged.passUnretained(IOReportCFixtureState.shared.unit).toOpaque()
}

private func ioReportFixtureSimpleValue(_ channel: UnsafeRawPointer?, _ index: Int32) -> Int64 {
    _ = channel
    _ = index
    return 52
}

private func ioReportFixtureStateCount(_ channel: UnsafeRawPointer?) -> Int32 {
    _ = channel
    return IOReportCFixtureState.shared.recordStateCount()
}

private func ioReportFixtureStateName(
    _ channel: UnsafeRawPointer?,
    _ index: Int32
) -> UnsafeMutableRawPointer? {
    _ = channel
    _ = index
    IOReportCFixtureState.shared.recordStateName()
    return nil
}

private func ioReportFixtureStateResidency(_ channel: UnsafeRawPointer?, _ index: Int32) -> Int64 {
    _ = channel
    _ = index
    IOReportCFixtureState.shared.recordStateResidency()
    return 0
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
    private(set) var closeCount = 0

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

    func close(handle: UnsafeMutableRawPointer) {
        _ = handle
        closeCount += 1
    }
    func errorMessage() -> String { "fixture symbol missing" }
}
