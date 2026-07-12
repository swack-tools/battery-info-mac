import CThermalProbeShim
import Foundation

public struct HIDRawRecord: Equatable {
    public var index: UInt32
    public var product: String
    public var location: String
    public var registryID: UInt64
    public var celsius: Double

    public init(
        index: UInt32,
        product: String,
        location: String,
        registryID: UInt64,
        celsius: Double
    ) {
        self.index = index
        self.product = product
        self.location = location
        self.registryID = registryID
        self.celsius = celsius
    }
}

public protocol HIDRecordProviding {
    func records() throws -> [HIDRawRecord]
}

public struct LiveHIDRecordProvider: HIDRecordProviding {
    public init() {}

    public func records() throws -> [HIDRawRecord] {
        var pointer: UnsafeMutablePointer<TPHIDRecord>?
        var count = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = error.withUnsafeMutableBufferPointer { errorBuffer in
            tp_hid_copy_temperature_records(
                &pointer,
                &count,
                errorBuffer.baseAddress,
                errorBuffer.count
            )
        }
        guard status == 0, let pointer else {
            throw ShimProviderError(
                source: "iohid",
                status: status,
                message: ShimBridge.errorMessage(from: error)
            )
        }
        defer { tp_free_records(pointer) }

        return (0..<count).map { index in
            let record = pointer[index]
            return HIDRawRecord(
                index: record.index,
                product: ShimBridge.string(from: record.product),
                location: ShimBridge.string(from: record.location),
                registryID: record.registry_id,
                celsius: record.celsius
            )
        }
    }
}

public struct HIDCollector: ThermalCollector {
    public let source = "iohid"
    private let provider: any HIDRecordProviding

    public init(provider: any HIDRecordProviding = LiveHIDRecordProvider()) {
        self.provider = provider
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let monotonicStart = context.clock.monotonicNow

        do {
            let rawRecords = try provider.records()
            let readings = rawRecords.map { Self.map($0, timestamp: context.clock.wallNow) }
            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsedMilliseconds(since: monotonicStart, clock: context.clock),
                readings: readings,
                capabilities: ["serviceCount": .number(Double(rawRecords.count))]
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsedMilliseconds(since: monotonicStart, clock: context.clock),
                code: "iohid_collection_failed",
                message: String(describing: error)
            )
        }
    }

    public static func map(_ raw: HIDRawRecord, timestamp: Date) -> Reading {
        let lowered = raw.product.lowercased()
        let category: ReadingCategory
        if lowered.contains("battery") || lowered.contains("gas gauge") {
            category = .battery
        } else if lowered.contains("nand") {
            category = .nand
        } else if lowered.contains("pmu") {
            category = .pmu
        } else if lowered.contains("gpu") {
            category = .gpu
        } else if lowered.contains("cpu") {
            category = .cpu
        } else {
            category = .system
        }

        let identity = raw.registryID == 0 ? "index-\(raw.index)" : "registry-\(raw.registryID)"
        let warnings = (-40...150).contains(raw.celsius)
            ? []
            : ["temperature is outside the -40...150 C plausibility range"]

        return Reading(
            source: "iohid",
            identifier: "\(identity):\(raw.product):\(raw.location)",
            label: raw.product.isEmpty ? nil : raw.product,
            category: category,
            kind: .temperature,
            value: .number(raw.celsius),
            unit: "C",
            timestamp: timestamp,
            classification: category == .system ? .unclassified : .heuristic,
            metadata: [
                "index": .number(Double(raw.index)),
                "product": .string(raw.product),
                "location": .string(raw.location),
                "registryID": .number(Double(raw.registryID)),
                "usagePage": .number(Double(0xff00)),
                "usage": .number(5)
            ],
            warnings: warnings
        )
    }

    private func elapsedMilliseconds(since start: TimeInterval, clock: any ProbeClock) -> Double {
        max(0, (clock.monotonicNow - start) * 1_000)
    }
}
