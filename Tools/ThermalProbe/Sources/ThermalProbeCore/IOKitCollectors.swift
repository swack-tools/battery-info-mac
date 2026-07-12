import Foundation
import IOKit

public enum RegistryFlattener {
    public static func flatten(_ dictionary: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            flatten(value, path: key, into: &result)
        }
        return result
    }

    private static func flatten(
        _ value: Any,
        path: String,
        into result: inout [String: JSONValue]
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
        if let converted = JSONValue.convert(value) {
            result[path] = converted
        }
    }
}

public enum BatteryPropertySource: String, Equatable {
    case rootBattery
    case batteryPack
}

public struct BatteryPropertySet {
    public var source: BatteryPropertySource
    public var properties: [String: Any]

    public init(source: BatteryPropertySource, properties: [String: Any]) {
        self.source = source
        self.properties = properties
    }
}

public protocol BatteryPropertyProviding {
    func propertySets() throws -> [BatteryPropertySet]
}

public struct LiveBatteryPropertyProvider: BatteryPropertyProviding {
    public init() {}

    public func propertySets() throws -> [BatteryPropertySet] {
        var results: [BatteryPropertySet] = []
        let classes: [(String, BatteryPropertySource)] = [
            ("AppleSmartBattery", .rootBattery),
            ("AppleSmartBatteryPack", .batteryPack)
        ]

        for (serviceClass, source) in classes {
            var iterator: io_iterator_t = 0
            let status = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(serviceClass),
                &iterator
            )
            guard status == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != IO_OBJECT_NULL {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                if let properties = copyProperties(service) {
                    results.append(BatteryPropertySet(source: source, properties: properties))
                }
            }
        }

        return results
    }
}

public struct BatteryCollector: ThermalCollector {
    public let source = "appleSmartBattery"
    private let provider: any BatteryPropertyProviding

    public init(provider: any BatteryPropertyProviding = LiveBatteryPropertyProvider()) {
        self.provider = provider
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let start = context.clock.monotonicNow
        do {
            let sets = try provider.propertySets()
            guard !sets.isEmpty else {
                return .unavailable(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    code: "battery_service_unavailable",
                    message: "AppleSmartBattery and AppleSmartBatteryPack were not found"
                )
            }
            let readings = sets.flatMap {
                Self.map(properties: $0.properties, source: $0.source, timestamp: context.clock.wallNow)
            }
            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                readings: readings,
                capabilities: ["serviceCount": .number(Double(sets.count))]
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                code: "battery_collection_failed",
                message: String(describing: error)
            )
        }
    }

    public static func map(
        properties: [String: Any],
        source: BatteryPropertySource,
        timestamp: Date
    ) -> [Reading] {
        RegistryFlattener.flatten(properties)
            .sorted { $0.key < $1.key }
            .compactMap { path, value in
                guard case let .number(rawValue) = value else { return nil }
                let leaf = path.split(separator: ".").last.map(String.init) ?? path
                let celsius: Double?
                let kind: ReadingKind
                let unit: String?
                let label: String

                switch leaf {
                case "Temperature", "VirtualTemperature":
                    guard !path.contains("LifetimeData") else { return nil }
                    celsius = source == .rootBattery
                        ? rawValue / 10 - 273.15
                        : rawValue / 100
                    kind = .temperature
                    unit = "C"
                    label = leaf == "Temperature" ? "Battery" : "Battery virtual"
                case "AverageTemperature" where path.contains("LifetimeData"):
                    celsius = rawValue / 10
                    kind = .temperature
                    unit = "C"
                    label = "Battery lifetime average"
                case "MaximumTemperature" where path.contains("LifetimeData"):
                    celsius = rawValue
                    kind = .temperature
                    unit = "C"
                    label = "Battery lifetime maximum"
                case "MinimumTemperature" where path.contains("LifetimeData"):
                    celsius = rawValue
                    kind = .temperature
                    unit = "C"
                    label = "Battery lifetime minimum"
                case "TimeChargingThermallyLimited":
                    celsius = rawValue
                    kind = .duration
                    unit = "s"
                    label = "Charging thermally limited"
                default:
                    return nil
                }

                let warnings: [String]
                if kind == .temperature, let celsius, !(-40...100).contains(celsius) {
                    warnings = ["battery temperature is outside the -40...100 C plausibility range"]
                } else {
                    warnings = []
                }

                return Reading(
                    source: "appleSmartBattery",
                    identifier: path,
                    label: label,
                    category: .battery,
                    kind: kind,
                    value: .number(celsius ?? rawValue),
                    unit: unit,
                    timestamp: timestamp,
                    classification: .known,
                    metadata: [
                        "propertySource": .string(source.rawValue),
                        "rawValue": .number(rawValue)
                    ],
                    warnings: warnings
                )
            }
    }

    private func elapsed(_ start: TimeInterval, clock: any ProbeClock) -> Double {
        max(0, (clock.monotonicNow - start) * 1_000)
    }
}

public struct ProcessThermalStateCollector: ThermalCollector {
    public let source = "processInfo"

    public init() {}

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        return .completed(
            source: source,
            startedAt: startedAt,
            durationMilliseconds: 0,
            readings: [Self.map(ProcessInfo.processInfo.thermalState, timestamp: startedAt)]
        )
    }

    public static func map(_ state: ProcessInfo.ThermalState, timestamp: Date) -> Reading {
        let value: String
        switch state {
        case .nominal: value = "nominal"
        case .fair: value = "fair"
        case .serious: value = "serious"
        case .critical: value = "critical"
        @unknown default: value = "unknown"
        }
        return Reading(
            source: "processInfo",
            identifier: "thermalState",
            label: "System thermal state",
            category: .system,
            kind: .thermalPressure,
            value: .text(value),
            unit: nil,
            timestamp: timestamp,
            classification: .known
        )
    }
}

public struct RegistryServiceSnapshot {
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

public protocol RegistrySnapshotProviding {
    func snapshots() throws -> [RegistryServiceSnapshot]
}

public enum RegistrySnapshotError: Error, CustomStringConvertible {
    case iterator(kern_return_t)

    public var description: String {
        switch self {
        case let .iterator(status):
            return "IORegistryCreateIterator failed with \(status)"
        }
    }
}

public struct LiveRegistrySnapshotProvider: RegistrySnapshotProviding {
    public init() {}

    public func snapshots() throws -> [RegistryServiceSnapshot] {
        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else { throw RegistrySnapshotError.iterator(status) }
        defer { IOObjectRelease(iterator) }

        var results: [RegistryServiceSnapshot] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let properties = copyProperties(entry) else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)

            let serviceClass: String
            if let unmanagedClass = IOObjectCopyClass(entry) {
                serviceClass = unmanagedClass.takeRetainedValue() as String
            } else {
                serviceClass = ""
            }

            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let path = IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer) == KERN_SUCCESS
                ? String(cString: pathBuffer)
                : ""

            results.append(
                RegistryServiceSnapshot(
                    name: name,
                    serviceClass: serviceClass,
                    path: path,
                    properties: properties
                )
            )
        }
        return results
    }
}

public struct IORegistryThermalCollector: ThermalCollector {
    public let source = "ioRegistry"
    private let provider: any RegistrySnapshotProviding

    public init(provider: any RegistrySnapshotProviding = LiveRegistrySnapshotProvider()) {
        self.provider = provider
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let start = context.clock.monotonicNow
        do {
            let snapshots = try provider.snapshots()
            let readings = Self.map(snapshots: snapshots, timestamp: context.clock.wallNow)
            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: max(0, (context.clock.monotonicNow - start) * 1_000),
                readings: readings,
                capabilities: [
                    "serviceCount": .number(Double(snapshots.count)),
                    "matchedPropertyCount": .number(Double(readings.count))
                ]
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: max(0, (context.clock.monotonicNow - start) * 1_000),
                code: "ioregistry_collection_failed",
                message: String(describing: error)
            )
        }
    }

    public static func map(snapshots: [RegistryServiceSnapshot], timestamp: Date) -> [Reading] {
        snapshots.flatMap { snapshot -> [Reading] in
            let isCLPC = snapshot.name.lowercased().contains("appleclpc")
                || snapshot.serviceClass.lowercased().contains("appleclpc")
            return RegistryFlattener.flatten(snapshot.properties)
                .sorted { $0.key < $1.key }
                .compactMap { propertyPath, value in
                    let lowered = propertyPath.lowercased()
                    let isThermal = lowered.contains("temp") || lowered.contains("thermal")
                    let isCLPCContext = isCLPC && ["limit", "target", "power", "cpu", "gpu", "die"]
                        .contains { lowered.contains($0) }
                    guard isThermal || isCLPCContext else { return nil }

                    let readingValue: ReadingValue
                    switch value {
                    case let .number(number): readingValue = .number(number)
                    case let .string(string): readingValue = .text(string)
                    case let .bool(flag): readingValue = .text(flag ? "true" : "false")
                    case .null: readingValue = .text("null")
                    case .array, .object: return nil
                    }

                    let category: ReadingCategory
                    if lowered.contains("cpu") {
                        category = .cpu
                    } else if lowered.contains("gpu") {
                        category = .gpu
                    } else if lowered.contains("battery") {
                        category = .battery
                    } else if lowered.contains("nand") {
                        category = .nand
                    } else if lowered.contains("pmu") {
                        category = .pmu
                    } else if lowered.contains("memory") || lowered.contains("dram") {
                        category = .memory
                    } else {
                        category = .system
                    }

                    return Reading(
                        source: "ioRegistry",
                        identifier: "\(snapshot.path)#\(propertyPath)",
                        label: propertyPath,
                        category: category,
                        kind: .rawContext,
                        value: readingValue,
                        unit: nil,
                        timestamp: timestamp,
                        classification: .unclassified,
                        metadata: [
                            "serviceName": .string(snapshot.name),
                            "serviceClass": .string(snapshot.serviceClass),
                            "registryPath": .string(snapshot.path),
                            "propertyPath": .string(propertyPath)
                        ]
                    )
                }
        }
    }
}

private func copyProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var unmanagedProperties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(
        entry,
        &unmanagedProperties,
        kCFAllocatorDefault,
        0
    ) == KERN_SUCCESS, let unmanagedProperties else {
        return nil
    }
    let dictionary = unmanagedProperties.takeRetainedValue() as NSDictionary
    return dictionary as? [String: Any]
}
