import Foundation

public enum SMCDecodeError: Error, Equatable {
    case insufficientBytes(expected: Int, actual: Int)
    case nonFiniteValue
}

public enum SMCDecoder {
    public static func decode(type: String, bytes: [UInt8]) throws -> Double? {
        switch type {
        case "ui8 ":
            try require(bytes, count: 1)
            return Double(bytes[0])
        case "ui16":
            return Double(try unsigned16(bytes))
        case "ui32":
            return Double(try unsigned32(bytes))
        case "si8 ":
            try require(bytes, count: 1)
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            return Double(Int16(bitPattern: try unsigned16(bytes)))
        case "si32":
            return Double(Int32(bitPattern: try unsigned32(bytes)))
        case "flt ":
            try require(bytes, count: 4)
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            guard value.isFinite else { throw SMCDecodeError.nonFiniteValue }
            return value
        default:
            return try decodeFixedPoint(type: type, bytes: bytes)
        }
    }

    private static func decodeFixedPoint(type: String, bytes: [UInt8]) throws -> Double? {
        guard type.count == 4, type.hasPrefix("fp") || type.hasPrefix("sp") else {
            return nil
        }
        guard let fractionalCharacter = type.last,
              let fractionalBits = Int(String(fractionalCharacter), radix: 16) else {
            return nil
        }

        let raw = try unsigned16(bytes)
        let divisor = pow(2, Double(fractionalBits))
        if type.hasPrefix("sp") {
            return Double(Int16(bitPattern: raw)) / divisor
        }
        return Double(raw) / divisor
    }

    private static func unsigned16(_ bytes: [UInt8]) throws -> UInt16 {
        try require(bytes, count: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private static func unsigned32(_ bytes: [UInt8]) throws -> UInt32 {
        try require(bytes, count: 4)
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    private static func require(_ bytes: [UInt8], count: Int) throws {
        guard bytes.count >= count else {
            throw SMCDecodeError.insufficientBytes(expected: count, actual: bytes.count)
        }
    }
}

public struct SensorClassification: Equatable {
    public var label: String?
    public var category: ReadingCategory
    public var kind: ReadingKind
    public var classification: ClassificationLevel

    public init(
        label: String?,
        category: ReadingCategory,
        kind: ReadingKind,
        classification: ClassificationLevel
    ) {
        self.label = label
        self.category = category
        self.kind = kind
        self.classification = classification
    }
}

public enum SensorClassifier {
    private struct KnownSensor {
        let label: String
        let category: ReadingCategory
    }

    private static let knownSMCSensors: [String: KnownSensor] = [
        "Te05": KnownSensor(label: "CPU efficiency core 1", category: .cpu),
        "Te0S": KnownSensor(label: "CPU efficiency core 2", category: .cpu),
        "Te09": KnownSensor(label: "CPU efficiency core 3", category: .cpu),
        "Te0H": KnownSensor(label: "CPU efficiency core 4", category: .cpu),
        "Tp01": KnownSensor(label: "CPU performance core 1", category: .cpu),
        "Tp05": KnownSensor(label: "CPU performance core 2", category: .cpu),
        "Tp09": KnownSensor(label: "CPU performance core 3", category: .cpu),
        "Tp0D": KnownSensor(label: "CPU performance core 4", category: .cpu),
        "Tp0V": KnownSensor(label: "CPU performance core 5", category: .cpu),
        "Tp0Y": KnownSensor(label: "CPU performance core 6", category: .cpu),
        "Tp0b": KnownSensor(label: "CPU performance core 7", category: .cpu),
        "Tp0e": KnownSensor(label: "CPU performance core 8", category: .cpu),
        "Tg0G": KnownSensor(label: "GPU 1", category: .gpu),
        "Tg0H": KnownSensor(label: "GPU 2", category: .gpu),
        "Tg0K": KnownSensor(label: "GPU 3", category: .gpu),
        "Tg0L": KnownSensor(label: "GPU 4", category: .gpu),
        "Tg0d": KnownSensor(label: "GPU 5", category: .gpu),
        "Tg0e": KnownSensor(label: "GPU 6", category: .gpu),
        "Tg0j": KnownSensor(label: "GPU 7", category: .gpu),
        "Tg0k": KnownSensor(label: "GPU 8", category: .gpu),
        "Tg1U": KnownSensor(label: "GPU 1", category: .gpu),
        "Tg1k": KnownSensor(label: "GPU 2", category: .gpu),
        "TB0T": KnownSensor(label: "Battery 1", category: .battery),
        "TB1T": KnownSensor(label: "Battery 2", category: .battery),
        "TB2T": KnownSensor(label: "Battery 3", category: .battery),
        "Tm0p": KnownSensor(label: "Memory proximity 1", category: .memory),
        "Tm1p": KnownSensor(label: "Memory proximity 2", category: .memory),
        "Tm2p": KnownSensor(label: "Memory proximity 3", category: .memory)
    ]

    public static func classifySMC(key: String) -> SensorClassification {
        if let sensor = knownSMCSensors[key] {
            return SensorClassification(
                label: sensor.label,
                category: sensor.category,
                kind: .temperature,
                classification: .known
            )
        }

        guard key.hasPrefix("T") else {
            return SensorClassification(
                label: nil,
                category: .unknown,
                kind: .rawContext,
                classification: .unclassified
            )
        }

        let category: ReadingCategory
        if key.hasPrefix("Tg") {
            category = .gpu
        } else if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf") {
            category = .cpu
        } else if key.hasPrefix("TB") {
            category = .battery
        } else if key.hasPrefix("Tm") {
            category = .memory
        } else {
            category = .unknown
        }

        return SensorClassification(
            label: nil,
            category: category,
            kind: .temperature,
            classification: .heuristic
        )
    }
}
