import BatteryMonitorShared
import CoreFoundation
import Darwin
import Foundation

public struct IOReportRawRecord: Equatable, Sendable {
    public var group: String
    public var subgroup: String
    public var channel: String
    public var unit: String
    public var state: String?
    public var stateIndex: Int32
    public var value: Int64

    public init(
        group: String,
        subgroup: String,
        channel: String,
        unit: String,
        state: String?,
        stateIndex: Int32,
        value: Int64
    ) {
        self.group = group
        self.subgroup = subgroup
        self.channel = channel
        self.unit = unit
        self.state = state
        self.stateIndex = stateIndex
        self.value = value
    }
}

public struct IOReportRecordBatch: Equatable, Sendable {
    public var records: [IOReportRawRecord]
    public var scannedCount: Int
    public var warnings: [String]

    public init(records: [IOReportRawRecord], scannedCount: Int, warnings: [String] = []) {
        self.records = records
        self.scannedCount = scannedCount
        self.warnings = warnings
    }

}

struct IOReportScanAccumulator {
    private static let maximumWarnings = 20
    private(set) var records: [IOReportRawRecord] = []
    private(set) var scannedCount = 0
    private(set) var observedStateCount = 0
    private var warnings: [String] = []
    private var omittedWarningCount = 0

    mutating func recordMalformedEntry(warning: String) {
        scannedCount += 1
        appendWarning(warning)
    }

    mutating func recordChannel(
        base: IOReportRawRecord,
        observedStateCount: Int,
        warnings: [String] = []
    ) {
        scannedCount += 1
        self.observedStateCount += observedStateCount
        records.append(base)
        warnings.forEach { appendWarning($0) }
    }

    func batch() -> IOReportRecordBatch {
        var boundedWarnings = warnings
        if omittedWarningCount > 0 {
            boundedWarnings.append("\(omittedWarningCount) additional IOReport warnings omitted")
        }
        return IOReportRecordBatch(
            records: records,
            scannedCount: scannedCount,
            warnings: boundedWarnings
        )
    }

    private mutating func appendWarning(_ warning: String) {
        if omittedWarningCount > 0 {
            omittedWarningCount += 1
            return
        }
        if warnings.count < Self.maximumWarnings {
            warnings.append(warning)
            return
        }
        warnings.removeLast()
        omittedWarningCount = 2
    }
}

public protocol IOReportRecordProviding: Sendable {
    func recordBatch(sampleMilliseconds: UInt32) throws -> IOReportRecordBatch
}

enum IOReportProviderErrorKind: Equatable, Sendable {
    case unavailable
    case failed
}

struct IOReportProviderError: Error, Equatable, CustomStringConvertible, Sendable {
    var kind: IOReportProviderErrorKind
    var message: String

    var description: String { message }
}

enum IOReportRecordIdentity {
    static func identifier(for raw: IOReportRawRecord) -> String {
        let path = [raw.group, raw.subgroup, raw.channel]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        guard let state = raw.state else { return path }
        return "\(path)/state[\(raw.stateIndex)]:\(state)"
    }
}

enum IOReportReadingMapper {
    private static let celsiusUnits = ["c", "°c", "degc", "celsius"]
    private static let rejectedPathTerms = [
        "power", "energy", "residency", "duration", "timing", "time", "raw"
    ]

    static func map(_ raw: IOReportRawRecord) -> DetailedThermalReading? {
        guard raw.state == nil else { return nil }
        let unit = raw.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard celsiusUnits.contains(unit) else { return nil }

        let searchable = [raw.group, raw.subgroup, raw.channel]
            .joined(separator: " ")
            .lowercased()
        guard !rejectedPathTerms.contains(where: searchable.contains) else { return nil }
        guard searchable.contains("thermal") || searchable.contains("temperature") else {
            return nil
        }

        let value = Double(raw.value)
        let warnings = (-40...150).contains(value)
            ? []
            : ["temperature is outside the -40...150 C plausibility range"]
        return .temperature(
            source: "ioreport",
            identifier: IOReportRecordIdentity.identifier(for: raw),
            label: raw.channel.isEmpty ? IOReportRecordIdentity.identifier(for: raw) : raw.channel,
            category: category(for: searchable),
            celsius: value,
            classification: .heuristic,
            warnings: warnings
        )
    }

    private static func category(for value: String) -> ThermalCategory {
        if value.contains("cpu") || value.contains("ecpu") || value.contains("pcpu") {
            return .cpu
        }
        if value.contains("gpu") { return .gpu }
        if value.contains("battery") || value.contains("gas gauge") { return .battery }
        if value.contains("dram") || value.contains("memory") { return .memory }
        if value.contains("nand") || value.contains("storage") || value.contains("ssd") { return .storage }
        return .system
    }
}

struct IOReportMappedRecord {
    var raw: IOReportRawRecord
    var reading: DetailedThermalReading
}

enum IOReportBatchMapper {
    static func map(
        _ records: [IOReportRawRecord],
        using mapper: (IOReportRawRecord) -> DetailedThermalReading?
    ) -> [IOReportMappedRecord] {
        records.compactMap { raw in
            guard let reading = mapper(raw) else { return nil }
            return IOReportMappedRecord(raw: raw, reading: reading)
        }
    }
}

struct IOReportAPI {
    typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> UnsafeMutableRawPointer?
    typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UInt64,
        UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    typealias CreateSamples = @convention(c) (
        UnsafeRawPointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    typealias CreateSamplesDelta = @convention(c) (
        UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    typealias ChannelString = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias SimpleValue = @convention(c) (UnsafeRawPointer?, Int32) -> Int64
    typealias StateCount = @convention(c) (UnsafeRawPointer?) -> Int32
    typealias StateName = @convention(c) (UnsafeRawPointer?, Int32) -> UnsafeMutableRawPointer?
    typealias StateResidency = @convention(c) (UnsafeRawPointer?, Int32) -> Int64

    private let library: DynamicSystemLibrary
    let copyAllChannels: CopyAllChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelGroup: ChannelString
    let channelSubgroup: ChannelString
    let channelName: ChannelString
    let channelUnit: ChannelString
    let simpleValue: SimpleValue
    let stateCount: StateCount
    let stateName: StateName
    let stateResidency: StateResidency

    init(library: DynamicSystemLibrary) throws {
        self.library = library
        copyAllChannels = try library.resolve("IOReportCopyAllChannels")
        createSubscription = try library.resolve("IOReportCreateSubscription")
        createSamples = try library.resolve("IOReportCreateSamples")
        createSamplesDelta = try library.resolve("IOReportCreateSamplesDelta")
        channelGroup = try library.resolve("IOReportChannelGetGroup")
        channelSubgroup = try library.resolve("IOReportChannelGetSubGroup")
        channelName = try library.resolve("IOReportChannelGetChannelName")
        channelUnit = try library.resolve("IOReportChannelGetUnitLabel")
        simpleValue = try library.resolve("IOReportSimpleGetIntegerValue")
        stateCount = try library.resolve("IOReportStateGetCount")
        stateName = try library.resolve("IOReportStateGetNameForIndex")
        stateResidency = try library.resolve("IOReportStateGetResidency")
    }
}

public struct LiveIOReportRecordProvider: IOReportRecordProviding {
    private let libraryFactory: @Sendable () throws -> DynamicSystemLibrary
    private let sleeper: @Sendable (UInt32) -> Void

    public init() {
        libraryFactory = {
            try DynamicSystemLibrary(source: "ioreport", path: "/usr/lib/libIOReport.dylib")
        }
        sleeper = { milliseconds in
            usleep(useconds_t(milliseconds) * 1_000)
        }
    }

    init(
        libraryFactory: @escaping @Sendable () throws -> DynamicSystemLibrary,
        sleeper: @escaping @Sendable (UInt32) -> Void
    ) {
        self.libraryFactory = libraryFactory
        self.sleeper = sleeper
    }

    public func recordBatch(sampleMilliseconds: UInt32) throws -> IOReportRecordBatch {
        do {
            let library = try libraryFactory()
            let api = try IOReportAPI(library: library)
            return try collect(api: api, sampleMilliseconds: min(100, max(1, sampleMilliseconds)))
        } catch let error as DynamicSystemLibraryError {
            throw IOReportProviderError(kind: .unavailable, message: error.description)
        } catch let error as IOReportProviderError {
            throw error
        } catch {
            throw IOReportProviderError(kind: .failed, message: String(describing: error))
        }
    }

    private func collect(api: IOReportAPI, sampleMilliseconds: UInt32) throws -> IOReportRecordBatch {
        guard let allChannelsPointer = api.copyAllChannels(0, 0) else {
            throw IOReportProviderError(kind: .failed, message: "IOReportCopyAllChannels returned null")
        }
        let allChannels = Unmanaged<CFDictionary>.fromOpaque(allChannelsPointer).takeRetainedValue()
        guard let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, allChannels) else {
            throw IOReportProviderError(kind: .failed, message: "IOReport channel dictionary could not be copied")
        }

        var subscriptionInfo: UnsafeMutableRawPointer?
        let channelsPointer = Unmanaged.passUnretained(channels).toOpaque()
        guard let subscription = api.createSubscription(
            nil,
            channelsPointer,
            &subscriptionInfo,
            0,
            nil
        ) else {
            if let subscriptionInfo {
                Unmanaged<CFTypeRef>.fromOpaque(subscriptionInfo).release()
            }
            throw IOReportProviderError(kind: .failed, message: "IOReport subscription could not be created")
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(subscription).release() }
        guard let subscribedChannelsPointer = subscriptionInfo else {
            throw IOReportProviderError(
                kind: .failed,
                message: "IOReport subscription returned no subscribed channel descriptor"
            )
        }

        guard let first = api.createSamples(subscription, subscribedChannelsPointer, nil) else {
            Unmanaged<CFTypeRef>.fromOpaque(subscribedChannelsPointer).release()
            throw IOReportProviderError(kind: .failed, message: "IOReport first sample could not be created")
        }
        sleeper(sampleMilliseconds)
        guard let second = api.createSamples(subscription, subscribedChannelsPointer, nil) else {
            Unmanaged<CFTypeRef>.fromOpaque(first).release()
            Unmanaged<CFTypeRef>.fromOpaque(subscribedChannelsPointer).release()
            throw IOReportProviderError(kind: .failed, message: "IOReport second sample could not be created")
        }
        Unmanaged<CFTypeRef>.fromOpaque(subscribedChannelsPointer).release()
        let delta = api.createSamplesDelta(first, second, nil)
        Unmanaged<CFTypeRef>.fromOpaque(first).release()
        Unmanaged<CFTypeRef>.fromOpaque(second).release()
        guard let delta else {
            throw IOReportProviderError(kind: .failed, message: "IOReport delta sample could not be created")
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(delta).release() }

        let deltaDictionary = Unmanaged<CFDictionary>.fromOpaque(delta).takeUnretainedValue()
        let channelKey = "IOReportChannels" as CFString
        guard let arrayPointer = CFDictionaryGetValue(
            deltaDictionary,
            Unmanaged.passUnretained(channelKey).toOpaque()
        ), CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(arrayPointer).takeUnretainedValue()) == CFArrayGetTypeID() else {
            throw IOReportProviderError(kind: .failed, message: "IOReport delta has no channel array")
        }

        let channelArray = Unmanaged<CFArray>.fromOpaque(arrayPointer).takeUnretainedValue()
        let channelCount = CFArrayGetCount(channelArray)
        var accumulator = IOReportScanAccumulator()
        for index in 0..<channelCount {
            guard let channel = CFArrayGetValueAtIndex(channelArray, index) else {
                accumulator.recordMalformedEntry(
                    warning: "IOReport channel \(index): channel reference unavailable"
                )
                continue
            }
            let value = Unmanaged<CFTypeRef>.fromOpaque(channel).takeUnretainedValue()
            guard CFGetTypeID(value) == CFDictionaryGetTypeID() else {
                accumulator.recordMalformedEntry(
                    warning: "IOReport channel \(index): record is not a dictionary"
                )
                continue
            }

            let group = string(api.channelGroup(channel))
            let subgroup = string(api.channelSubgroup(channel))
            let name = string(api.channelName(channel))
            let unit = string(api.channelUnit(channel))
            let base = IOReportRawRecord(
                group: group,
                subgroup: subgroup,
                channel: name,
                unit: unit,
                state: nil,
                stateIndex: -1,
                value: api.simpleValue(channel, 0)
            )

            let stateCount = api.stateCount(channel)
            var channelWarnings: [String] = []
            let observedStateCount: Int
            if (0...4096).contains(stateCount) {
                observedStateCount = Int(stateCount)
            } else {
                observedStateCount = 0
                channelWarnings.append("IOReport channel \(index): invalid state count \(stateCount)")
            }
            accumulator.recordChannel(
                base: base,
                observedStateCount: observedStateCount,
                warnings: channelWarnings
            )
        }
        return accumulator.batch()
    }

    private func string(_ pointer: UnsafeMutableRawPointer?) -> String {
        guard let pointer else { return "" }
        let value = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        return value as String
    }
}

public struct IOReportThermalCollector: ThermalCollector {
    public let source = "ioreport"
    private static let maximumWarnings = 20
    private let provider: any IOReportRecordProviding
    private let sampleMilliseconds: UInt32

    public init(
        provider: any IOReportRecordProviding = LiveIOReportRecordProvider(),
        sampleMilliseconds: UInt32 = 100
    ) {
        self.provider = provider
        self.sampleMilliseconds = min(100, max(1, sampleMilliseconds))
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let batch = try provider.recordBatch(sampleMilliseconds: sampleMilliseconds)
            guard !batch.records.isEmpty else {
                return result(
                    state: .failed,
                    error: "IOReport returned no channel records",
                    scannedCount: batch.scannedCount,
                    warnings: bounded(batch.warnings),
                    start: start
                )
            }
            let mappedRecords = IOReportBatchMapper.map(
                batch.records,
                using: IOReportReadingMapper.map
            )
            let readings = mappedRecords.map(\.reading)
            var warnings = batch.warnings
            for mappedRecord in mappedRecords {
                warnings.append(contentsOf: mappedRecord.reading.warnings.map {
                    "IOReport \(IOReportRecordIdentity.identifier(for: mappedRecord.raw)): \($0)"
                })
            }
            return .completed(
                source: source,
                readings: readings,
                durationMilliseconds: elapsed(since: start),
                warnings: bounded(warnings),
                scannedRecordCount: batch.scannedCount
            )
        } catch let error as IOReportProviderError where error.kind == .unavailable {
            return result(state: .unavailable, error: error.description, start: start)
        } catch {
            return result(state: .failed, error: String(describing: error), start: start)
        }
    }

    private func result(
        state: ThermalSourceState,
        error: String,
        scannedCount: Int = 0,
        warnings: [String] = [],
        start: UInt64
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: state,
                readingCount: 0,
                durationMilliseconds: elapsed(since: start),
                warnings: warnings,
                error: error,
                scannedRecordCount: scannedCount
            )
        )
    }

    private func bounded(_ warnings: [String]) -> [String] {
        guard warnings.count > Self.maximumWarnings else { return warnings }
        let retained = Self.maximumWarnings - 1
        return Array(warnings.prefix(retained)) + [
            "\(warnings.count - retained) additional IOReport warnings omitted"
        ]
    }

    private func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
