import CThermalProbeShim
import Foundation

public struct IOReportRawRecord: Equatable {
    public var group: String
    public var subgroup: String
    public var channel: String
    public var unit: String
    public var state: String?
    public var stateIndex: Int32
    public var value: Int64
    public var sampleMilliseconds: UInt32

    public init(
        group: String,
        subgroup: String,
        channel: String,
        unit: String,
        state: String?,
        stateIndex: Int32,
        value: Int64,
        sampleMilliseconds: UInt32
    ) {
        self.group = group
        self.subgroup = subgroup
        self.channel = channel
        self.unit = unit
        self.state = state
        self.stateIndex = stateIndex
        self.value = value
        self.sampleMilliseconds = sampleMilliseconds
    }
}

public protocol IOReportRecordProviding {
    func records(sampleMilliseconds: UInt32) throws -> [IOReportRawRecord]
}

public struct LiveIOReportRecordProvider: IOReportRecordProviding {
    public init() {}

    public func records(sampleMilliseconds: UInt32) throws -> [IOReportRawRecord] {
        var pointer: UnsafeMutablePointer<TPIOReportRecord>?
        var count = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = error.withUnsafeMutableBufferPointer { errorBuffer in
            tp_ioreport_copy_records(
                sampleMilliseconds,
                &pointer,
                &count,
                errorBuffer.baseAddress,
                errorBuffer.count
            )
        }
        guard status == 0, let pointer else {
            throw ShimProviderError(
                source: "ioreport",
                status: status,
                message: ShimBridge.errorMessage(from: error)
            )
        }
        defer { tp_free_records(pointer) }

        return (0..<count).map { index in
            let record = pointer[index]
            let state = ShimBridge.string(from: record.state)
            return IOReportRawRecord(
                group: ShimBridge.string(from: record.group),
                subgroup: ShimBridge.string(from: record.subgroup),
                channel: ShimBridge.string(from: record.channel),
                unit: ShimBridge.string(from: record.unit),
                state: state.isEmpty ? nil : state,
                stateIndex: record.state_index,
                value: record.value,
                sampleMilliseconds: sampleMilliseconds
            )
        }
    }
}

public struct IOReportCollector: ThermalCollector {
    public let source = "ioreport"
    private let provider: any IOReportRecordProviding
    private let sampleMilliseconds: UInt32

    public init(
        provider: any IOReportRecordProviding = LiveIOReportRecordProvider(),
        sampleMilliseconds: UInt32 = 100
    ) {
        self.provider = provider
        self.sampleMilliseconds = sampleMilliseconds
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let start = context.clock.monotonicNow
        do {
            let rawRecords = try provider.records(sampleMilliseconds: sampleMilliseconds)
            let readings = rawRecords.map { Self.map($0, timestamp: context.clock.wallNow) }
            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                readings: readings,
                capabilities: [
                    "channelRecordCount": .number(Double(rawRecords.count)),
                    "sampleMilliseconds": .number(Double(sampleMilliseconds))
                ]
            )
        } catch let error as ShimProviderError {
            return .unavailable(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                code: "ioreport_unavailable",
                message: error.description
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                code: "ioreport_collection_failed",
                message: String(describing: error)
            )
        }
    }

    public static func map(_ raw: IOReportRawRecord, timestamp: Date) -> Reading {
        let path = [raw.group, raw.subgroup, raw.channel]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let identifier = raw.state.map { "\(path)/state[\(raw.stateIndex)]:\($0)" } ?? path
        let lowered = path.lowercased()
        let unit = raw.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUnit = unit.lowercased()

        let category: ReadingCategory
        if lowered.contains("cpu") || lowered.contains("ecpu") || lowered.contains("pcpu") {
            category = .cpu
        } else if lowered.contains("gpu") {
            category = .gpu
        } else if lowered.contains("battery") {
            category = .battery
        } else if lowered.contains("dram") || lowered.contains("memory") {
            category = .memory
        } else {
            category = .system
        }

        let kind: ReadingKind
        let value: Double
        let outputUnit: String?
        if ["c", "°c", "degc", "celsius"].contains(normalizedUnit),
           lowered.contains("temp") || lowered.contains("thermal") {
            kind = .temperature
            value = Double(raw.value)
            outputUnit = "C"
        } else if normalizedUnit == "w" {
            kind = .power
            value = Double(raw.value)
            outputUnit = "W"
        } else if normalizedUnit == "mw" {
            kind = .power
            value = Double(raw.value) / 1_000
            outputUnit = "W"
        } else if ["ns", "us", "µs", "ms", "s"].contains(normalizedUnit) {
            kind = .duration
            value = Double(raw.value)
            outputUnit = unit
        } else {
            kind = .rawContext
            value = Double(raw.value)
            outputUnit = unit.isEmpty ? nil : unit
        }

        var warnings: [String] = []
        if kind == .temperature, !(-40...150).contains(value) {
            warnings.append("temperature is outside the -40...150 C plausibility range")
        }

        var metadata: [String: JSONValue] = [
            "group": .string(raw.group),
            "subgroup": .string(raw.subgroup),
            "channel": .string(raw.channel),
            "sampleMilliseconds": .number(Double(raw.sampleMilliseconds)),
            "rawValue": .number(Double(raw.value))
        ]
        if let state = raw.state {
            metadata["state"] = .string(state)
            metadata["stateIndex"] = .number(Double(raw.stateIndex))
        }

        return Reading(
            source: "ioreport",
            identifier: identifier,
            label: raw.state.map { "\(raw.channel): \($0)" } ?? raw.channel,
            category: category,
            kind: kind,
            value: .number(value),
            unit: outputUnit,
            timestamp: timestamp,
            classification: kind == .rawContext ? .unclassified : .heuristic,
            metadata: metadata,
            warnings: warnings
        )
    }

    private func elapsed(_ start: TimeInterval, clock: any ProbeClock) -> Double {
        max(0, (clock.monotonicNow - start) * 1_000)
    }
}
