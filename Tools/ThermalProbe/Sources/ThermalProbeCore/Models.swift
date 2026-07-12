import CoreFoundation
import Foundation

public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public static func convert(_ value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as Data:
            return .string(value.base64EncodedString())
        case let value as Date:
            return .string(ProbeJSON.format(date: value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(value.compactMap(convert))
        case let value as [String: Any]:
            return .object(value.compactMapValues(convert))
        case let value as NSDictionary:
            var object: [String: JSONValue] = [:]
            for (key, nestedValue) in value {
                guard let key = key as? String, let converted = convert(nestedValue) else { continue }
                object[key] = converted
            }
            return .object(object)
        default:
            return nil
        }
    }
}

public enum ReadingValue: Codable, Equatable {
    case number(Double)
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case number
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .number(value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .text(value):
            try container.encode(ValueType.text, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum ReadingCategory: String, Codable, CaseIterable, Equatable {
    case cpu
    case gpu
    case battery
    case pmu
    case nand
    case memory
    case enclosure
    case system
    case unknown
}

public enum ReadingKind: String, Codable, Equatable {
    case temperature
    case thermalPressure
    case powerLimit
    case forcedIdle
    case power
    case duration
    case rawContext
}

public enum ClassificationLevel: String, Codable, Equatable {
    case known
    case heuristic
    case unclassified
}

public enum SourceStatus: String, Codable, Equatable {
    case success
    case partial
    case unavailable
    case failed
    case timedOut
}

public struct SourceError: Codable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct Reading: Codable, Equatable {
    public var source: String
    public var identifier: String
    public var label: String?
    public var category: ReadingCategory
    public var kind: ReadingKind
    public var value: ReadingValue
    public var unit: String?
    public var timestamp: Date
    public var classification: ClassificationLevel
    public var metadata: [String: JSONValue]
    public var warnings: [String]
    public var rawDataType: String?
    public var rawBytes: [UInt8]?
    public var rawIntegerValue: Int64?

    public init(
        source: String,
        identifier: String,
        label: String?,
        category: ReadingCategory,
        kind: ReadingKind,
        value: ReadingValue,
        unit: String?,
        timestamp: Date,
        classification: ClassificationLevel,
        metadata: [String: JSONValue] = [:],
        warnings: [String] = [],
        rawDataType: String? = nil,
        rawBytes: [UInt8]? = nil,
        rawIntegerValue: Int64? = nil
    ) {
        self.source = source
        self.identifier = identifier
        self.label = label
        self.category = category
        self.kind = kind
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.classification = classification
        self.metadata = metadata
        self.warnings = warnings
        self.rawDataType = rawDataType
        self.rawBytes = rawBytes
        self.rawIntegerValue = rawIntegerValue
    }

    public var number: Double? {
        guard case let .number(value) = value else { return nil }
        return value
    }
}

public struct SourceResult: Codable, Equatable {
    public var source: String
    public var status: SourceStatus
    public var startedAt: Date
    public var durationMilliseconds: Double
    public var readings: [Reading]
    public var warnings: [String]
    public var error: SourceError?
    public var capabilities: [String: JSONValue]

    public init(
        source: String,
        status: SourceStatus,
        startedAt: Date,
        durationMilliseconds: Double,
        readings: [Reading],
        warnings: [String],
        error: SourceError?,
        capabilities: [String: JSONValue]
    ) {
        self.source = source
        self.status = status
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.readings = readings
        self.warnings = warnings
        self.error = error
        self.capabilities = capabilities
    }
}

public struct SensorSummary: Codable, Equatable {
    public var category: ReadingCategory
    public var minimum: Double
    public var average: Double
    public var maximum: Double
    public var count: Int

    public init(category: ReadingCategory, minimum: Double, average: Double, maximum: Double, count: Int) {
        self.category = category
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
        self.count = count
    }
}

public struct SensorAggregate: Codable, Equatable {
    public var source: String
    public var identifier: String
    public var label: String?
    public var category: ReadingCategory
    public var kind: ReadingKind
    public var unit: String?
    public var minimum: Double
    public var average: Double
    public var maximum: Double
    public var delta: Double
    public var sampleCount: Int

    public init(
        source: String,
        identifier: String,
        label: String?,
        category: ReadingCategory,
        kind: ReadingKind,
        unit: String?,
        minimum: Double,
        average: Double,
        maximum: Double,
        delta: Double,
        sampleCount: Int
    ) {
        self.source = source
        self.identifier = identifier
        self.label = label
        self.category = category
        self.kind = kind
        self.unit = unit
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
        self.delta = delta
        self.sampleCount = sampleCount
    }
}

public struct ThermalSample: Codable, Equatable {
    public var index: Int
    public var startedAt: Date
    public var durationMilliseconds: Double
    public var sources: [SourceResult]
    public var summaries: [SensorSummary]

    public init(
        index: Int,
        startedAt: Date,
        durationMilliseconds: Double,
        sources: [SourceResult],
        summaries: [SensorSummary]
    ) {
        self.index = index
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.sources = sources
        self.summaries = summaries
    }
}

public struct HostMetadata: Codable, Equatable {
    public var osVersion: String
    public var osBuild: String
    public var model: String
    public var chip: String

    public init(osVersion: String, osBuild: String, model: String, chip: String) {
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.model = model
        self.chip = chip
    }
}

public struct InvocationMetadata: Codable, Equatable {
    public var arguments: [String]
    public var isRoot: Bool
    public var requestedSamples: Int
    public var intervalMilliseconds: Int
    public var raw: Bool

    public init(
        arguments: [String],
        isRoot: Bool,
        requestedSamples: Int,
        intervalMilliseconds: Int,
        raw: Bool
    ) {
        self.arguments = arguments
        self.isRoot = isRoot
        self.requestedSamples = requestedSamples
        self.intervalMilliseconds = intervalMilliseconds
        self.raw = raw
    }
}

public struct CaptureEnvelope: Codable, Equatable {
    public var schemaVersion: Int
    public var host: HostMetadata
    public var invocation: InvocationMetadata
    public var samples: [ThermalSample]
    public var aggregates: [SensorAggregate]
    public var warnings: [String]

    public init(
        schemaVersion: Int,
        host: HostMetadata,
        invocation: InvocationMetadata,
        samples: [ThermalSample],
        aggregates: [SensorAggregate],
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.host = host
        self.invocation = invocation
        self.samples = samples
        self.aggregates = aggregates
        self.warnings = warnings
    }
}

public struct SampleStreamRecord: Codable, Equatable {
    public var schemaVersion: Int
    public var host: HostMetadata
    public var invocation: InvocationMetadata
    public var sample: ThermalSample

    public init(schemaVersion: Int, host: HostMetadata, invocation: InvocationMetadata, sample: ThermalSample) {
        self.schemaVersion = schemaVersion
        self.host = host
        self.invocation = invocation
        self.sample = sample
    }
}

public struct SummaryStreamRecord: Codable, Equatable {
    public var schemaVersion: Int
    public var host: HostMetadata
    public var invocation: InvocationMetadata
    public var aggregates: [SensorAggregate]
    public var warnings: [String]

    public init(
        schemaVersion: Int,
        host: HostMetadata,
        invocation: InvocationMetadata,
        aggregates: [SensorAggregate],
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.host = host
        self.invocation = invocation
        self.aggregates = aggregates
        self.warnings = warnings
    }
}

public struct StreamRecord: Codable, Equatable {
    public enum Tag: String, Codable, Equatable {
        case sample
        case summary
    }

    public var tag: Tag
    public var sample: SampleStreamRecord?
    public var summary: SummaryStreamRecord?

    public init(sample: SampleStreamRecord) {
        tag = .sample
        self.sample = sample
        summary = nil
    }

    public init(summary: SummaryStreamRecord) {
        tag = .summary
        sample = nil
        self.summary = summary
    }
}

public enum ProbeJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date: date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parse(date: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }

    public static func format(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func parse(date value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
