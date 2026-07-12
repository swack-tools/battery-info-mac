import BatteryMonitorShared
import Foundation
import IOKit

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPowerLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuLimit: UInt32 = 0
    var gpuLimit: UInt32 = 0
    var memoryLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    var versionPadding: (UInt8, UInt8) = (0, 0)
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32Padding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

enum SMCReadBytesRequest {
    static func make(key: UInt32, dataSize: UInt32) throws -> SMCKeyData {
        guard (1...32).contains(dataSize) else {
            throw SMCProviderError(
                message: "SMC key returned invalid data size \(dataSize)",
                code: nil
            )
        }

        var request = SMCKeyData()
        request.key = key
        request.keyInfo.dataSize = dataSize
        request.data8 = 5
        return request
    }
}

enum SMCOutputSizeValidator {
    static func validate(_ outputSize: Int) throws {
        let expected = MemoryLayout<SMCKeyData>.size
        guard outputSize == expected else {
            throw SMCProviderError(
                message: "AppleSMC returned output size \(outputSize), expected \(expected)",
                code: nil
            )
        }
    }
}

enum SMCFourCCError: Error, Equatable {
    case requiresFourASCIIBytes
}

enum SMCFourCC {
    static func value(from string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, string.unicodeScalars.allSatisfy(\.isASCII) else {
            throw SMCFourCCError.requiresFourASCIIBytes
        }
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    static func string(from value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

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
        let descriptor = Array(type)
        guard let integerBits = Int(String(descriptor[2]), radix: 16),
              let fractionalBits = Int(String(descriptor[3]), radix: 16) else {
            return nil
        }
        let expectedBitCount = type.hasPrefix("sp") ? 15 : 16
        guard integerBits + fractionalBits == expectedBitCount else {
            return nil
        }

        let raw = try unsigned16(bytes)
        let divisor = pow(2, Double(fractionalBits))
        return type.hasPrefix("sp")
            ? Double(Int16(bitPattern: raw)) / divisor
            : Double(raw) / divisor
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

struct SMCSensorClassification: Equatable {
    var label: String?
    var category: ThermalCategory
    var classification: ThermalClassification
    var isTemperature: Bool
}

enum SMCSensorClassifier {
    private struct KnownSensor {
        let label: String
        let category: ThermalCategory
    }

    private static let knownSensors: [String: KnownSensor] = [
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

    static func classify(key: String) -> SMCSensorClassification {
        if let sensor = knownSensors[key] {
            return SMCSensorClassification(
                label: sensor.label,
                category: sensor.category,
                classification: .known,
                isTemperature: true
            )
        }

        guard key.hasPrefix("T") else {
            return SMCSensorClassification(
                label: nil,
                category: .unknown,
                classification: .unclassified,
                isTemperature: false
            )
        }

        let category: ThermalCategory
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

        return SMCSensorClassification(
            label: nil,
            category: category,
            classification: .heuristic,
            isTemperature: true
        )
    }
}

public struct SMCRawRecord: Equatable, Sendable {
    public var key: String
    public var dataType: String
    public var data: [UInt8]
    public var status: Int32

    public init(key: String, dataType: String, data: [UInt8], status: Int32) {
        self.key = key
        self.dataType = dataType
        self.data = data
        self.status = status
    }
}

public struct SMCRecordBatch: Equatable, Sendable {
    public var records: [SMCRawRecord]
    public var attemptedCount: Int
    public var warnings: [String]

    public init(records: [SMCRawRecord], attemptedCount: Int, warnings: [String] = []) {
        self.records = records
        self.attemptedCount = attemptedCount
        self.warnings = warnings
    }
}

public protocol SMCRecordProviding: Sendable {
    func recordBatch() throws -> SMCRecordBatch
}

enum SMCReadingMappingError: Error, Equatable, CustomStringConvertible {
    case unsupportedTemperatureEncoding(String)

    var description: String {
        switch self {
        case let .unsupportedTemperatureEncoding(type):
            return "unsupported temperature encoding \(type)"
        }
    }
}

enum SMCReadingMapper {
    static func map(_ raw: SMCRawRecord, timestamp: Date) throws -> DetailedThermalReading? {
        _ = timestamp
        let classification = SMCSensorClassifier.classify(key: raw.key)
        guard classification.isTemperature else { return nil }
        guard let value = try SMCDecoder.decode(type: raw.dataType, bytes: raw.data) else {
            throw SMCReadingMappingError.unsupportedTemperatureEncoding(raw.dataType)
        }

        var warnings: [String] = []
        if !(-40...150).contains(value) {
            warnings.append("temperature is outside the -40...150 C plausibility range")
        }
        if raw.status != 0 {
            warnings.append("SMC returned status \(raw.status)")
        }

        return .temperature(
            source: "smc",
            identifier: raw.key,
            label: classification.label ?? raw.key,
            category: classification.category,
            celsius: value,
            classification: classification.classification,
            warnings: warnings
        )
    }
}

enum SMCProviderErrorKind: Equatable, Sendable {
    case unavailable
    case failed
}

struct SMCProviderError: Error, CustomStringConvertible {
    var kind: SMCProviderErrorKind = .failed
    var message: String
    var code: kern_return_t?

    var description: String {
        guard let code else { return message }
        return "\(message) (IOKit \(code))"
    }
}

public struct LiveSMCRecordProvider: SMCRecordProviding {
    private static let kernelSelector: UInt32 = 2
    private static let readIndexCommand: UInt8 = 8
    private static let readKeyInfoCommand: UInt8 = 9

    public init() {}

    public func recordBatch() throws -> SMCRecordBatch {
        let connection = try openConnection()
        defer { IOServiceClose(connection) }

        let keyCountRecord = try readKey("#KEY", connection: connection)
        guard keyCountRecord.data.count >= 4 else {
            throw SMCProviderError(message: "SMC #KEY returned fewer than four bytes", code: nil)
        }
        let keyCount = UInt32(keyCountRecord.data[0]) << 24
            | UInt32(keyCountRecord.data[1]) << 16
            | UInt32(keyCountRecord.data[2]) << 8
            | UInt32(keyCountRecord.data[3])
        guard (1...65_536).contains(keyCount) else {
            throw SMCProviderError(message: "SMC returned invalid key count \(keyCount)", code: nil)
        }

        var records: [SMCRawRecord] = []
        var warnings: [String] = []
        records.reserveCapacity(Int(keyCount))
        for index in 0..<keyCount {
            do {
                let key = try key(at: index, connection: connection)
                do {
                    records.append(try readKey(key, connection: connection))
                } catch {
                    warnings.append("SMC key \(key): \(error)")
                }
            } catch {
                warnings.append("SMC index \(index): \(error)")
            }
        }
        return SMCRecordBatch(
            records: records,
            attemptedCount: Int(keyCount),
            warnings: warnings
        )
    }

    private func openConnection() throws -> io_connect_t {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCProviderError(
                kind: .unavailable,
                message: "AppleSMC matching dictionary could not be created",
                code: nil
            )
        }
        let matchingResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchingResult == KERN_SUCCESS else {
            throw SMCProviderError(message: "AppleSMC services could not be matched", code: matchingResult)
        }
        defer { IOObjectRelease(iterator) }

        var fallback: io_connect_t = 0
        var foundService = false
        var lastOpenError: kern_return_t?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            foundService = true

            var candidate: io_connect_t = 0
            let openResult = IOServiceOpen(service, mach_task_self_, 0, &candidate)
            guard openResult == KERN_SUCCESS, candidate != 0 else {
                if openResult != KERN_SUCCESS {
                    lastOpenError = openResult
                }
                continue
            }

            if serviceName(service) == "AppleSMCKeysEndpoint" {
                if fallback != 0 { IOServiceClose(fallback) }
                return candidate
            }
            if fallback == 0 {
                fallback = candidate
            } else {
                IOServiceClose(candidate)
            }
        }

        guard fallback != 0 else {
            if !foundService {
                throw SMCProviderError(
                    kind: .unavailable,
                    message: "AppleSMC service was not found",
                    code: nil
                )
            }
            throw SMCProviderError(
                message: "AppleSMCKeysEndpoint could not be opened",
                code: lastOpenError
            )
        }
        return fallback
    }

    private func serviceName(_ service: io_service_t) -> String? {
        var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        let result = name.withUnsafeMutableBufferPointer {
            IORegistryEntryGetName(service, $0.baseAddress)
        }
        guard result == KERN_SUCCESS else { return nil }
        return name.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    private func key(at index: UInt32, connection: io_connect_t) throws -> String {
        var input = SMCKeyData()
        input.data8 = Self.readIndexCommand
        input.data32 = index
        return SMCFourCC.string(from: try call(input, connection: connection).key)
    }

    private func readKey(_ key: String, connection: io_connect_t) throws -> SMCRawRecord {
        let keyValue = try SMCFourCC.value(from: key)
        var infoInput = SMCKeyData()
        infoInput.key = keyValue
        infoInput.data8 = Self.readKeyInfoCommand
        let info = try call(infoInput, connection: connection).keyInfo

        let bytesInput = try SMCReadBytesRequest.make(key: keyValue, dataSize: info.dataSize)
        let value = try call(bytesInput, connection: connection)
        let byteCount = Int(info.dataSize)
        var rawBytes = value.bytes
        let data = withUnsafeBytes(of: &rawBytes) { Array($0.prefix(byteCount)) }
        return SMCRawRecord(
            key: key,
            dataType: SMCFourCC.string(from: info.dataType),
            data: data,
            status: Int32(value.status)
        )
    }

    private func call(_ input: SMCKeyData, connection: io_connect_t) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let result = withUnsafeBytes(of: &input) { inputBuffer in
            withUnsafeMutableBytes(of: &output) { outputBuffer in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelSelector,
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    outputBuffer.baseAddress,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw SMCProviderError(message: "AppleSMC call failed", code: result)
        }
        try SMCOutputSizeValidator.validate(outputSize)
        guard output.result == 0 else {
            throw SMCProviderError(message: "AppleSMC returned result \(output.result)", code: nil)
        }
        return output
    }
}

public struct SMCThermalCollector: ThermalCollector {
    private static let maximumFailureWarnings = 20

    public let source = "smc"
    private let provider: any SMCRecordProviding

    public init(provider: any SMCRecordProviding = LiveSMCRecordProvider()) {
        self.provider = provider
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let batch = try provider.recordBatch()
            guard !batch.records.isEmpty else {
                return noReadableRecordsResult(
                    batch: batch,
                    durationMilliseconds: elapsedMilliseconds(since: start)
                )
            }
            var readings: [DetailedThermalReading] = []
            var warnings = batch.warnings
            for record in batch.records {
                do {
                    if let reading = try SMCReadingMapper.map(record, timestamp: timestamp) {
                        readings.append(reading)
                    }
                } catch {
                    warnings.append("\(record.key): \(error)")
                }
            }
            return .completed(
                source: source,
                readings: readings,
                durationMilliseconds: elapsedMilliseconds(since: start),
                warnings: warnings,
                scannedRecordCount: batch.attemptedCount
            )
        } catch let error as SMCProviderError where error.kind == .unavailable {
            return unavailableResult(
                durationMilliseconds: elapsedMilliseconds(since: start),
                error: String(describing: error)
            )
        } catch {
            return .failed(
                source: source,
                durationMilliseconds: elapsedMilliseconds(since: start),
                error: String(describing: error)
            )
        }
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private func unavailableResult(
        durationMilliseconds: Double,
        error: String
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: .unavailable,
                readingCount: 0,
                durationMilliseconds: durationMilliseconds,
                error: error,
                scannedRecordCount: 0
            )
        )
    }

    private func noReadableRecordsResult(
        batch: SMCRecordBatch,
        durationMilliseconds: Double
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: .failed,
                readingCount: 0,
                durationMilliseconds: durationMilliseconds,
                warnings: boundedFailureWarnings(batch.warnings),
                error: "SMC scanned \(batch.attemptedCount) keys but produced no readable records",
                scannedRecordCount: batch.attemptedCount
            )
        )
    }

    private func boundedFailureWarnings(_ warnings: [String]) -> [String] {
        guard warnings.count > Self.maximumFailureWarnings else { return warnings }
        let retainedCount = Self.maximumFailureWarnings - 1
        return Array(warnings.prefix(retainedCount)) + [
            "\(warnings.count - retainedCount) additional SMC warnings omitted"
        ]
    }
}
