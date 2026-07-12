import BatteryMonitorShared
import CoreFoundation
import Foundation

public struct HIDRawRecord: Equatable, Sendable {
    public var index: UInt32
    public var product: String
    public var location: String
    public var registryID: UInt64
    public var celsius: Double

    public init(index: UInt32, product: String, location: String, registryID: UInt64, celsius: Double) {
        self.index = index
        self.product = product
        self.location = location
        self.registryID = registryID
        self.celsius = celsius
    }
}

public struct HIDRecordBatch: Equatable, Sendable {
    public var records: [HIDRawRecord]
    public var attemptedCount: Int
    public var warnings: [String]

    public init(records: [HIDRawRecord], attemptedCount: Int, warnings: [String] = []) {
        self.records = records
        self.attemptedCount = attemptedCount
        self.warnings = warnings
    }
}

public protocol HIDRecordProviding: Sendable {
    func recordBatch() throws -> HIDRecordBatch
}

enum HIDProviderErrorKind: Equatable, Sendable {
    case unavailable
    case failed
}

struct HIDProviderError: Error, Equatable, CustomStringConvertible, Sendable {
    var kind: HIDProviderErrorKind
    var message: String

    var description: String { message }
}

enum HIDReadingMappingError: Error, Equatable {
    case nonFiniteTemperature
}

enum HIDSensorClassifier {
    static func category(for product: String) -> ThermalCategory {
        let value = product.lowercased()
        if value.contains("battery") || value.contains("gas gauge") {
            return .battery
        }
        if value.contains("nand") || value.contains("storage") || value.contains("ssd") {
            return .storage
        }
        if value.contains("pmu") || value.contains("power management") {
            return .pmu
        }
        if value.contains("gpu") {
            return .gpu
        }
        if value.contains("cpu") {
            return .cpu
        }
        if value.contains("enclosure") || value.contains("chassis") || value.contains("skin") {
            return .enclosure
        }
        return .system
    }
}

enum HIDReadingMapper {
    static func map(_ raw: HIDRawRecord) throws -> DetailedThermalReading {
        guard raw.celsius.isFinite else { throw HIDReadingMappingError.nonFiniteTemperature }

        let category = HIDSensorClassifier.category(for: raw.product)
        let components = [slug(raw.product), slug(raw.location)].filter { !$0.isEmpty }
        let suffix = components.isEmpty ? "temperature" : components.joined(separator: ":")
        let identifier: String
        if raw.registryID != 0 {
            identifier = "registry-\(raw.registryID):\(suffix)"
        } else if !components.isEmpty {
            identifier = "sensor:\(components.joined(separator: ":"))"
        } else {
            identifier = "sensor:unidentified"
        }
        let label: String
        if !raw.product.isEmpty {
            label = raw.product
        } else if !raw.location.isEmpty {
            label = "IOHID temperature \(raw.location)"
        } else {
            label = "Unidentified IOHID temperature"
        }
        var warnings: [String] = []
        if !(-40...150).contains(raw.celsius) {
            warnings.append("temperature is outside the -40...150 C plausibility range")
        }
        if raw.registryID == 0, components.isEmpty {
            warnings.append("stable hardware identity unavailable")
        }

        return .temperature(
            source: "iohid",
            identifier: identifier,
            label: label,
            category: category,
            celsius: raw.celsius,
            classification: category == .system ? .unclassified : .heuristic,
            warnings: warnings
        )
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

struct HIDDynamicAPI {
    typealias ClientCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias SetMatching = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Int32
    typealias CopyServices = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias CopyProperty = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias CopyEvent = @convention(c) (UnsafeRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    typealias GetFloatValue = @convention(c) (UnsafeRawPointer?, Int32) -> Double

    private let library: DynamicSystemLibrary
    let createClient: ClientCreate
    let setMatching: SetMatching
    let copyServices: CopyServices
    let copyProperty: CopyProperty
    let copyEvent: CopyEvent
    let getFloatValue: GetFloatValue

    init(library: DynamicSystemLibrary) throws {
        self.library = library
        createClient = try library.resolve("IOHIDEventSystemClientCreate")
        setMatching = try library.resolve("IOHIDEventSystemClientSetMatching")
        copyServices = try library.resolve("IOHIDEventSystemClientCopyServices")
        copyProperty = try library.resolve("IOHIDServiceClientCopyProperty")
        copyEvent = try library.resolve("IOHIDServiceClientCopyEvent")
        getFloatValue = try library.resolve("IOHIDEventGetFloatValue")
    }
}

public struct LiveHIDRecordProvider: HIDRecordProviding {
    private let libraryFactory: @Sendable () throws -> DynamicSystemLibrary

    public init() {
        libraryFactory = {
            let framework = "/System/Library/Frameworks/IOKit.framework/IOKit"
            if let library = try? DynamicSystemLibrary(source: "iohid", path: framework) {
                return library
            }
            return try DynamicSystemLibrary(source: "iohid", path: nil)
        }
    }

    init(libraryFactory: @escaping @Sendable () throws -> DynamicSystemLibrary) {
        self.libraryFactory = libraryFactory
    }

    public func recordBatch() throws -> HIDRecordBatch {
        do {
            let library = try libraryFactory()
            let api = try HIDDynamicAPI(library: library)
            return try collect(api: api)
        } catch let error as DynamicSystemLibraryError {
            throw HIDProviderError(kind: .unavailable, message: error.description)
        } catch let error as HIDProviderError {
            throw error
        } catch {
            throw HIDProviderError(kind: .failed, message: String(describing: error))
        }
    }

    private func collect(api: HIDDynamicAPI) throws -> HIDRecordBatch {
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        guard let client = api.createClient(nil) else {
            throw HIDProviderError(kind: .failed, message: "IOHID event system client could not be created")
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(client).release() }

        _ = api.setMatching(client, Unmanaged.passUnretained(matching).toOpaque())
        guard let servicesPointer = api.copyServices(client) else {
            throw HIDProviderError(kind: .failed, message: "IOHID returned no temperature service array")
        }
        let services = Unmanaged<CFArray>.fromOpaque(servicesPointer).takeRetainedValue()
        let count = CFArrayGetCount(services)
        guard count > 0 else {
            throw HIDProviderError(kind: .unavailable, message: "IOHID found no matching temperature services")
        }

        var records: [HIDRawRecord] = []
        var warnings: [String] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            guard let service = CFArrayGetValueAtIndex(services, index) else {
                warnings.append("IOHID service \(index): service reference unavailable")
                continue
            }
            guard let event = api.copyEvent(service, 15, 0, 0) else {
                warnings.append("IOHID service \(index): event unavailable")
                continue
            }
            let celsius = api.getFloatValue(event, 15 << 16)
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            guard celsius.isFinite else {
                warnings.append("IOHID service \(index): nonfinite temperature")
                continue
            }

            let product = stringProperty("Product", service: service, api: api)
            let location = stringProperty("LocationID", service: service, api: api)
                ?? stringProperty("SensorID", service: service, api: api)
            let registryID = integerProperty("RegistryID", service: service, api: api)
                ?? integerProperty("IORegistryEntryID", service: service, api: api)
            records.append(HIDRawRecord(
                index: UInt32(index),
                product: product ?? "",
                location: location ?? "",
                registryID: registryID ?? 0,
                celsius: celsius
            ))
        }
        return HIDRecordBatch(records: records, attemptedCount: count, warnings: warnings)
    }

    private func copiedProperty(_ name: String, service: UnsafeRawPointer, api: HIDDynamicAPI) -> CFTypeRef? {
        let key = name as CFString
        guard let pointer = api.copyProperty(service, Unmanaged.passUnretained(key).toOpaque()) else {
            return nil
        }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue()
    }

    private func stringProperty(_ name: String, service: UnsafeRawPointer, api: HIDDynamicAPI) -> String? {
        guard let property = copiedProperty(name, service: service, api: api) else {
            return nil
        }
        if let string = property as? String {
            return string
        }
        return (property as? NSNumber)?.stringValue
    }

    private func integerProperty(_ name: String, service: UnsafeRawPointer, api: HIDDynamicAPI) -> UInt64? {
        (copiedProperty(name, service: service, api: api) as? NSNumber)?.uint64Value
    }
}

public struct HIDThermalCollector: ThermalCollector {
    public let source = "iohid"
    private static let maximumWarnings = 20
    private let provider: any HIDRecordProviding

    public init(provider: any HIDRecordProviding = LiveHIDRecordProvider()) {
        self.provider = provider
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let batch = try provider.recordBatch()
            var readings: [DetailedThermalReading] = []
            var warnings = batch.warnings
            for record in batch.records {
                do {
                    let reading = try HIDReadingMapper.map(record)
                    readings.append(reading)
                    warnings.append(contentsOf: reading.warnings.map { "IOHID service \(record.index): \($0)" })
                } catch HIDReadingMappingError.nonFiniteTemperature {
                    warnings.append("IOHID service \(record.index): nonfinite temperature")
                } catch {
                    warnings.append("IOHID service \(record.index): \(error)")
                }
            }

            let boundedWarnings = bounded(warnings)
            if readings.isEmpty, batch.attemptedCount > 0 {
                return failedEmptyBatch(batch: batch, warnings: boundedWarnings, start: start)
            }
            return .completed(
                source: source,
                readings: readings,
                durationMilliseconds: elapsed(since: start),
                warnings: boundedWarnings,
                scannedRecordCount: batch.attemptedCount
            )
        } catch let error as HIDProviderError where error.kind == .unavailable {
            return result(state: .unavailable, error: error.description, start: start)
        } catch {
            return result(state: .failed, error: String(describing: error), start: start)
        }
    }

    private func failedEmptyBatch(batch: HIDRecordBatch, warnings: [String], start: UInt64) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: .failed,
                readingCount: 0,
                durationMilliseconds: elapsed(since: start),
                warnings: warnings,
                error: "IOHID scanned \(batch.attemptedCount) services but produced no readable events",
                scannedRecordCount: batch.attemptedCount
            )
        )
    }

    private func result(state: ThermalSourceState, error: String, start: UInt64) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: state,
                readingCount: 0,
                durationMilliseconds: elapsed(since: start),
                error: error,
                scannedRecordCount: 0
            )
        )
    }

    private func bounded(_ warnings: [String]) -> [String] {
        guard warnings.count > Self.maximumWarnings else { return warnings }
        let retained = Self.maximumWarnings - 1
        return Array(warnings.prefix(retained)) + [
            "\(warnings.count - retained) additional IOHID warnings omitted"
        ]
    }

    private func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
