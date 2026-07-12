import BatteryMonitorShared
import Foundation

public protocol ThermalCollector: Sendable {
    var source: String { get }
    func collect(at timestamp: Date) throws -> ThermalCollectionResult
}

public struct ThermalCaptureCoordinator: Sendable {
    private static let maximumMessages = 20
    private static let maximumMessageLength = 240

    private let collectors: [any ThermalCollector]

    public init(collectors: [any ThermalCollector]) {
        self.collectors = collectors
    }

    public static let `default` = ThermalCaptureCoordinator(collectors: [
        SMCThermalCollector(),
        HIDThermalCollector(),
        AppleSmartBatteryThermalCollector(),
        ProcessInfoThermalCollector(),
        IOReportThermalCollector(),
        PowermetricsThermalCollector(),
        PMSetThermalCollector(),
        IORegistryThermalCollector()
    ])

    public var sources: [String] { collectors.map(\.source) }

    public func collect(generatedAt: Date = Date()) -> ThermalSnapshot {
        var results: [ThermalCollectionResult] = []
        results.reserveCapacity(collectors.count)

        for collector in collectors {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                results.append(try collector.collect(at: generatedAt))
            } catch {
                results.append(ThermalCollectionResult(
                    readings: [],
                    status: ThermalSourceStatus(
                        source: collector.source,
                        state: .failed,
                        readingCount: 0,
                        durationMilliseconds: Double(
                            DispatchTime.now().uptimeNanoseconds - started
                        ) / 1_000_000,
                        error: String(describing: error),
                        scannedRecordCount: 0
                    )
                ))
            }
        }

        let detailedReadings = results.flatMap(\.readings)
        let throttling = results.compactMap(\.throttling).max { lhs, rhs in
            lhs.percentage < rhs.percentage
        } ?? .nominal(source: "coordinator")
        let explicitPressures = results.flatMap { result -> [String] in
            var pressures = [result.thermalPressure].compactMap { $0 }
            pressures.append(contentsOf: result.readings.compactMap { reading in
                reading.kind == .thermalPressure ? reading.textValue : nil
            })
            return pressures
        }
        var pressureCandidates = explicitPressures
        if throttling.percentage > 0 {
            pressureCandidates.append(throttling.level)
        }
        let pressure = pressureCandidates.max { lhs, rhs in
            pressureRank(lhs) < pressureRank(rhs)
        }

        return ThermalSnapshot(
            generatedAt: generatedAt,
            thermalReadings: ThermalSummaryBuilder.build(from: detailedReadings),
            componentPowers: deduplicatedComponentPowers(results.flatMap(\.componentPowers)),
            throttling: throttling,
            thermalPressure: pressure.map(normalizedPressure),
            messages: boundedMessages(from: results.map(\.status)),
            detailedReadings: detailedReadings,
            sourceStatuses: results.map(\.status)
        )
    }

    private func deduplicatedComponentPowers(
        _ powers: [ComponentPowerReading]
    ) -> [ComponentPowerReading] {
        var order: [String] = []
        var values: [String: ComponentPowerReading] = [:]
        for power in powers {
            let key = normalizedComponentName(power.name)
            guard !key.isEmpty else { continue }
            if values[key] == nil { order.append(key) }
            if let existing = values[key], existing.watts > 0, power.watts == 0 { continue }
            values[key] = power
        }
        return order.compactMap { values[$0] }
    }

    private func normalizedComponentName(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func boundedMessages(from statuses: [ThermalSourceStatus]) -> [String] {
        var messages: [String] = []
        for status in statuses {
            if let error = status.error, !error.isEmpty {
                messages.append("\(status.source): \(error)")
            }
            messages.append(contentsOf: status.warnings.map { "\(status.source): \($0)" })
        }
        let shortened = messages.map { message in
            message.count <= Self.maximumMessageLength
                ? message
                : String(message.prefix(Self.maximumMessageLength - 3)) + "..."
        }
        guard shortened.count > Self.maximumMessages else { return shortened }
        let retained = Self.maximumMessages - 1
        return Array(shortened.prefix(retained)) + [
            "\(shortened.count - retained) additional thermal messages omitted"
        ]
    }

    private func pressureRank(_ pressure: String) -> Int {
        let value = pressure.lowercased()
        if value.contains("critical") || value.contains("heavy") { return 3 }
        if value.contains("serious") || value.contains("moderate") { return 2 }
        if value.contains("fair") || value.contains("light") { return 1 }
        return 0
    }

    private func normalizedPressure(_ pressure: String) -> String {
        let value = pressure.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first else { return "Unknown" }
        return first.uppercased() + value.dropFirst().lowercased()
    }
}

public struct ThermalCollectionResult: Sendable {
    public var readings: [DetailedThermalReading]
    public var status: ThermalSourceStatus
    public var componentPowers: [ComponentPowerReading]
    public var throttling: ThrottlingStatus?
    public var thermalPressure: String?

    public init(
        readings: [DetailedThermalReading],
        status: ThermalSourceStatus,
        componentPowers: [ComponentPowerReading] = [],
        throttling: ThrottlingStatus? = nil,
        thermalPressure: String? = nil
    ) {
        self.readings = readings
        self.status = status
        self.componentPowers = componentPowers
        self.throttling = throttling
        self.thermalPressure = thermalPressure
    }

    public static func completed(
        source: String,
        readings: [DetailedThermalReading],
        durationMilliseconds: Double,
        warnings: [String] = [],
        scannedRecordCount: Int? = nil,
        componentPowers: [ComponentPowerReading] = [],
        throttling: ThrottlingStatus? = nil,
        thermalPressure: String? = nil
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: readings,
            status: ThermalSourceStatus(
                source: source,
                state: warnings.isEmpty ? .success : .partial,
                readingCount: readings.count,
                durationMilliseconds: durationMilliseconds,
                warnings: warnings,
                scannedRecordCount: scannedRecordCount
            ),
            componentPowers: componentPowers,
            throttling: throttling,
            thermalPressure: thermalPressure
        )
    }

    public static func failed(
        source: String,
        durationMilliseconds: Double,
        error: String
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: .failed,
                readingCount: 0,
                durationMilliseconds: durationMilliseconds,
                error: error,
                scannedRecordCount: 0
            )
        )
    }
}
