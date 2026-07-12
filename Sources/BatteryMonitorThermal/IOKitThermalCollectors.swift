import BatteryMonitorShared
import CoreFoundation
import Foundation
import IOKit

public enum RegistryPropertyValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
}

public enum RegistryPropertyFlattener {
    public static func flatten(_ dictionary: [String: Any]) -> [String: RegistryPropertyValue] {
        var result: [String: RegistryPropertyValue] = [:]
        for (key, value) in dictionary {
            flatten(value, path: key, into: &result)
        }
        return result
    }

    private static func flatten(
        _ value: Any,
        path: String,
        into result: inout [String: RegistryPropertyValue]
    ) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                flatten(nested, path: "\(path).\(key)", into: &result)
            }
            return
        }
        if let dictionary = value as? NSDictionary {
            for (key, nested) in dictionary {
                guard let key = key as? String else { continue }
                flatten(nested, path: "\(path).\(key)", into: &result)
            }
            return
        }
        if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                flatten(nested, path: "\(path).\(index)", into: &result)
            }
            return
        }
        if let array = value as? NSArray {
            for (index, nested) in array.enumerated() {
                flatten(nested, path: "\(path).\(index)", into: &result)
            }
            return
        }
        if let flag = value as? Bool {
            result[path] = .bool(flag)
        } else if let number = value as? NSNumber {
            result[path] = .number(number.doubleValue)
        } else if let number = value as? Double {
            result[path] = .number(number)
        } else if let string = value as? String {
            result[path] = .string(string)
        }
    }
}

public enum BatteryPropertySource: String, Equatable, Sendable {
    case rootBattery
    case batteryPack

    fileprivate var identifierPrefix: String {
        self == .rootBattery ? "root" : "pack"
    }
}

public struct BatteryPropertySet: @unchecked Sendable {
    public var source: BatteryPropertySource
    public var properties: [String: Any]

    public init(source: BatteryPropertySource, properties: [String: Any]) {
        self.source = source
        self.properties = properties
    }
}

public struct BatteryPropertyBatch: @unchecked Sendable {
    public var propertySets: [BatteryPropertySet]
    public var discoveredServiceCount: Int
    public var scannedPropertyCount: Int
    public var warnings: [String]

    public init(
        propertySets: [BatteryPropertySet],
        discoveredServiceCount: Int,
        scannedPropertyCount: Int,
        warnings: [String] = []
    ) {
        self.propertySets = propertySets
        self.discoveredServiceCount = discoveredServiceCount
        self.scannedPropertyCount = scannedPropertyCount
        self.warnings = warnings
    }
}

public protocol BatteryPropertyProviding: Sendable {
    func propertyBatch() throws -> BatteryPropertyBatch
}

public struct LiveBatteryPropertyProvider: BatteryPropertyProviding {
    public init() {}

    public func propertyBatch() throws -> BatteryPropertyBatch {
        let classes: [(String, BatteryPropertySource)] = [
            ("AppleSmartBattery", .rootBattery),
            ("AppleSmartBatteryPack", .batteryPack)
        ]
        var sets: [BatteryPropertySet] = []
        var discovered = 0
        var scanned = 0
        var warnings: [String] = []

        for (serviceClass, source) in classes {
            var iterator: io_iterator_t = 0
            let status = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(serviceClass),
                &iterator
            )
            guard status == KERN_SUCCESS else {
                warnings.append("\(serviceClass) lookup failed with \(status)")
                continue
            }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != IO_OBJECT_NULL {
                discovered += 1
                if let properties = copyRegistryProperties(service) {
                    scanned += RegistryPropertyFlattener.flatten(properties).count
                    sets.append(BatteryPropertySet(source: source, properties: properties))
                } else {
                    warnings.append("\(serviceClass) service \(discovered) properties unavailable")
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }

        return BatteryPropertyBatch(
            propertySets: sets,
            discoveredServiceCount: discovered,
            scannedPropertyCount: scanned,
            warnings: warnings
        )
    }
}

public struct AppleSmartBatteryThermalCollector: ThermalCollector {
    public let source = "appleSmartBattery"
    private let provider: any BatteryPropertyProviding

    public init(provider: any BatteryPropertyProviding = LiveBatteryPropertyProvider()) {
        self.provider = provider
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let batch = try provider.propertyBatch()
            let warnings = boundedWarnings(batch.warnings)
            guard batch.discoveredServiceCount > 0 else {
                let state: ThermalSourceState = warnings.isEmpty ? .unavailable : .failed
                return statusResult(
                    state: state,
                    error: warnings.isEmpty
                        ? "AppleSmartBattery and AppleSmartBatteryPack were not found"
                        : "battery service lookup failed",
                    warnings: warnings,
                    scanned: batch.scannedPropertyCount,
                    start: start
                )
            }

            let readings = batch.propertySets.flatMap {
                Self.map(properties: $0.properties, source: $0.source)
            }
            guard !readings.isEmpty else {
                return statusResult(
                    state: .failed,
                    error: "battery services were found but no valid thermal properties were read",
                    warnings: warnings,
                    scanned: batch.scannedPropertyCount,
                    start: start
                )
            }
            return .completed(
                source: source,
                readings: readings,
                durationMilliseconds: elapsedMilliseconds(since: start),
                warnings: warnings,
                scannedRecordCount: batch.scannedPropertyCount
            )
        } catch {
            return .failed(
                source: source,
                durationMilliseconds: elapsedMilliseconds(since: start),
                error: String(describing: error)
            )
        }
    }

    public static func map(
        properties: [String: Any],
        source: BatteryPropertySource
    ) -> [DetailedThermalReading] {
        RegistryPropertyFlattener.flatten(properties)
            .sorted { $0.key < $1.key }
            .compactMap { path, value in
                guard case let .number(rawValue) = value, rawValue.isFinite else { return nil }
                let leaf = path.split(separator: ".").last.map(String.init) ?? path
                let celsius: Double
                let label: String
                switch leaf {
                case "Temperature" where !path.contains("LifetimeData"),
                     "VirtualTemperature" where !path.contains("LifetimeData"):
                    celsius = source == .rootBattery ? rawValue / 10 - 273.15 : rawValue / 100
                    label = leaf == "Temperature" ? "Battery" : "Battery virtual"
                case "AverageTemperature" where path.contains("LifetimeData"):
                    celsius = rawValue / 10
                    label = "Battery lifetime average"
                case "MaximumTemperature" where path.contains("LifetimeData"):
                    celsius = rawValue
                    label = "Battery lifetime maximum"
                case "MinimumTemperature" where path.contains("LifetimeData"):
                    celsius = rawValue
                    label = "Battery lifetime minimum"
                default:
                    return nil
                }
                let warnings = (-40...100).contains(celsius)
                    ? []
                    : ["battery temperature is outside the -40...100 C plausibility range"]
                return .temperature(
                    source: "appleSmartBattery",
                    identifier: "\(source.identifierPrefix).\(path)",
                    label: label,
                    category: .battery,
                    celsius: celsius,
                    warnings: warnings
                )
            }
    }

    private func statusResult(
        state: ThermalSourceState,
        error: String,
        warnings: [String],
        scanned: Int,
        start: UInt64
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: state,
                readingCount: 0,
                durationMilliseconds: elapsedMilliseconds(since: start),
                warnings: warnings,
                error: error,
                scannedRecordCount: scanned
            )
        )
    }
}

public enum ProcessThermalState: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public protocol ProcessThermalStateProviding: Sendable {
    func thermalState() -> ProcessThermalState
}

public struct LiveProcessThermalStateProvider: ProcessThermalStateProviding {
    public init() {}

    public func thermalState() -> ProcessThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

public struct ProcessInfoThermalCollector: ThermalCollector {
    public let source = "processInfo"
    private let provider: any ProcessThermalStateProviding

    public init(provider: any ProcessThermalStateProviding = LiveProcessThermalStateProvider()) {
        self.provider = provider
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let reading = DetailedThermalReading(
            source: source,
            identifier: "thermalState",
            label: "System thermal state",
            category: .system,
            kind: .thermalPressure,
            textValue: provider.thermalState().rawValue,
            classification: .known
        )
        return .completed(source: source, readings: [reading], durationMilliseconds: 0)
    }
}

public struct RegistryServiceSnapshot: @unchecked Sendable {
    public var name: String
    public var serviceClass: String
    public var path: String
    public var properties: [String: Any]

    public init(name: String, serviceClass: String, path: String, properties: [String: Any]) {
        self.name = name
        self.serviceClass = serviceClass
        self.path = path
        self.properties = properties
    }
}

public struct RegistrySnapshotBatch: @unchecked Sendable {
    public var snapshots: [RegistryServiceSnapshot]
    public var scannedServiceCount: Int
    public var scannedPropertyCount: Int
    public var warnings: [String]

    public init(
        snapshots: [RegistryServiceSnapshot],
        scannedServiceCount: Int,
        scannedPropertyCount: Int,
        warnings: [String] = []
    ) {
        self.snapshots = snapshots
        self.scannedServiceCount = scannedServiceCount
        self.scannedPropertyCount = scannedPropertyCount
        self.warnings = warnings
    }
}

public protocol RegistrySnapshotProviding: Sendable {
    func snapshotBatch() throws -> RegistrySnapshotBatch
}

public enum RegistrySnapshotError: Error, CustomStringConvertible, Sendable {
    case iterator(kern_return_t)

    public var description: String {
        switch self {
        case let .iterator(status): return "IORegistryCreateIterator failed with \(status)"
        }
    }
}

public struct LiveRegistrySnapshotProvider: RegistrySnapshotProviding {
    public init() {}

    public func snapshotBatch() throws -> RegistrySnapshotBatch {
        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else { throw RegistrySnapshotError.iterator(status) }
        defer { IOObjectRelease(iterator) }

        var snapshots: [RegistryServiceSnapshot] = []
        var serviceCount = 0
        var propertyCount = 0
        var warnings: [String] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            serviceCount += 1
            if let properties = copyRegistryProperties(entry) {
                propertyCount += RegistryPropertyFlattener.flatten(properties).count
                snapshots.append(RegistryServiceSnapshot(
                    name: registryName(entry),
                    serviceClass: registryClass(entry),
                    path: registryPath(entry),
                    properties: properties
                ))
            } else {
                warnings.append("IORegistry service \(serviceCount): properties unavailable")
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return RegistrySnapshotBatch(
            snapshots: snapshots,
            scannedServiceCount: serviceCount,
            scannedPropertyCount: propertyCount,
            warnings: warnings
        )
    }
}

public struct IORegistryThermalCollector: ThermalCollector {
    public let source = "ioRegistry"
    private let provider: any RegistrySnapshotProviding

    public init(provider: any RegistrySnapshotProviding = LiveRegistrySnapshotProvider()) {
        self.provider = provider
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let batch = try provider.snapshotBatch()
            let readings = Self.map(snapshots: batch.snapshots)
            var diagnostics = batch.warnings
            diagnostics.append(
                "scanned \(batch.scannedServiceCount) services and \(batch.scannedPropertyCount) properties; emitted \(readings.count) thermal readings"
            )
            let warnings = boundedWarnings(diagnostics)
            let state: ThermalSourceState = batch.warnings.isEmpty ? .success : .partial
            return ThermalCollectionResult(
                readings: readings,
                status: ThermalSourceStatus(
                    source: source,
                    state: state,
                    readingCount: readings.count,
                    durationMilliseconds: elapsedMilliseconds(since: start),
                    warnings: warnings,
                    scannedRecordCount: batch.scannedPropertyCount
                )
            )
        } catch {
            return .failed(
                source: source,
                durationMilliseconds: elapsedMilliseconds(since: start),
                error: String(describing: error)
            )
        }
    }

    public static func map(snapshots: [RegistryServiceSnapshot]) -> [DetailedThermalReading] {
        snapshots.flatMap { snapshot in
            RegistryPropertyFlattener.flatten(snapshot.properties)
                .sorted { $0.key < $1.key }
                .compactMap { propertyPath, value in
                    map(snapshot: snapshot, propertyPath: propertyPath, value: value)
                }
        }
    }

    private static func map(
        snapshot: RegistryServiceSnapshot,
        propertyPath: String,
        value: RegistryPropertyValue
    ) -> DetailedThermalReading? {
        let property = propertyPath.lowercased()
        let context = "\(propertyPath) \(snapshot.name) \(snapshot.serviceClass) \(snapshot.path)".lowercased()
        let identifier = "\(snapshot.path)#\(propertyPath)"

        if isPressureProperty(property), case let .string(text) = value,
           let pressure = normalizedPressure(text) {
            return DetailedThermalReading(
                source: "ioRegistry",
                identifier: identifier,
                label: propertyPath,
                category: category(for: propertyPath, fallback: context),
                kind: .thermalPressure,
                textValue: pressure,
                classification: .heuristic
            )
        }

        guard isTemperatureProperty(property), !isRawOrControlProperty(property) else { return nil }
        let celsius: Double?
        switch value {
        case let .number(number):
            celsius = number
        case let .string(text):
            celsius = celsiusValue(in: text)
        case .bool:
            celsius = nil
        }
        guard let celsius, celsius.isFinite, (-40...150).contains(celsius) else { return nil }
        return .temperature(
            source: "ioRegistry",
            identifier: identifier,
            label: propertyPath,
            category: category(for: propertyPath, fallback: context),
            celsius: celsius,
            classification: .heuristic
        )
    }

    private static func isPressureProperty(_ value: String) -> Bool {
        value.contains("thermalpressure")
            || value.contains("thermal pressure")
            || value.contains("thermalstate")
            || value.contains("thermal state")
    }

    private static func isTemperatureProperty(_ value: String) -> Bool {
        value.contains("temperature") || value.contains("temp")
    }

    private static func isRawOrControlProperty(_ value: String) -> Bool {
        let leaf = value.split(separator: ".").last.map(String.init) ?? value
        return ["raw", "target", "limit", "threshold", "calibration", "offset", "correction", "default"]
            .contains(where: value.contains) || leaf.hasPrefix("set")
    }

    private static func celsiusValue(in text: String) -> Double? {
        guard let range = text.range(
            of: #"-?[0-9]+(?:\.[0-9]+)?\s*(?:°\s*)?(?:c|celsius)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ), let numberRange = text[range].range(of: #"-?[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(text[range][numberRange])
    }

    private static func normalizedPressure(_ text: String) -> String? {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["nominal", "fair", "serious", "critical", "light", "moderate", "heavy"]
            .first(where: lowered.contains)
    }

    private static func category(for propertyPath: String, fallback: String) -> ThermalCategory {
        let propertyCategory = category(in: propertyPath.lowercased())
        return propertyCategory == .system ? category(in: fallback) : propertyCategory
    }

    private static func category(in text: String) -> ThermalCategory {
        if text.contains("cpu") || text.contains("ecpu") || text.contains("pcpu") { return .cpu }
        if text.contains("gpu") { return .gpu }
        if text.contains("battery") || text.contains("gas gauge") { return .battery }
        if text.contains("nand") || text.contains("storage") || text.contains("ssd") { return .storage }
        if text.contains("pmu") || text.contains("power management") { return .pmu }
        if text.contains("memory") || text.contains("dram") { return .memory }
        if text.contains("enclosure") || text.contains("chassis") || text.contains("skin") { return .enclosure }
        return .system
    }
}

private func copyRegistryProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(
        entry,
        &properties,
        kCFAllocatorDefault,
        0
    ) == KERN_SUCCESS, let properties else {
        return nil
    }
    return properties.takeRetainedValue() as NSDictionary as? [String: Any]
}

private func registryName(_ entry: io_registry_entry_t) -> String {
    var buffer = [CChar](repeating: 0, count: 128)
    return IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS ? String(cString: buffer) : ""
}

private func registryClass(_ entry: io_registry_entry_t) -> String {
    guard let value = IOObjectCopyClass(entry) else { return "" }
    return value.takeRetainedValue() as String
}

private func registryPath(_ entry: io_registry_entry_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4_096)
    return IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS
        ? String(cString: buffer)
        : ""
}

private func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func boundedWarnings(_ warnings: [String], maximum: Int = 20) -> [String] {
    guard warnings.count > maximum else { return warnings }
    return Array(warnings.prefix(maximum)) + ["\(warnings.count - maximum) additional warnings omitted"]
}
