import BatteryMonitorShared
import Darwin
import Foundation

public protocol ThermalCollector: Sendable {
    var source: String { get }
    func collect(at timestamp: Date) throws -> ThermalCollectionResult
}

public struct AtomicThermalSnapshotWriter {
    typealias Renamer = (URL, URL) throws -> Void
    private let renamer: Renamer

    public init() {
        renamer = Self.renameReplacingDestination
    }

    init(renamer: @escaping Renamer) {
        self.renamer = renamer
    }

    public func write(snapshot: ThermalSnapshot, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        try data.write(to: temporary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: temporary.path
        )
        try renamer(temporary, destination)
    }

    private static func renameReplacingDestination(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "rename \(source.lastPathComponent) to \(destination.lastPathComponent): "
                        + String(cString: strerror(code))
                ]
            )
        }
    }
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
        var thermalStatus: ThermalStatusCandidate?
        for result in results {
            guard let candidate = thermalStatusCandidate(for: result) else { continue }
            if let current = thermalStatus {
                let candidateRank = pressureRank(candidate.level)
                let currentRank = pressureRank(current.level)
                if candidateRank > currentRank
                    || (candidateRank == currentRank && candidate.percentage > current.percentage) {
                    thermalStatus = candidate
                }
            } else {
                thermalStatus = candidate
            }
        }
        let throttling = thermalStatus.map {
            ThrottlingStatus(level: $0.level, percentage: $0.percentage, source: $0.source)
        } ?? .nominal(source: "coordinator")

        return ThermalSnapshot(
            generatedAt: generatedAt,
            thermalReadings: ThermalSummaryBuilder.build(from: detailedReadings),
            componentPowers: deduplicatedComponentPowers(results.flatMap(\.componentPowers)),
            throttling: throttling,
            thermalPressure: thermalStatus?.level,
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

    private func defaultPercentage(forPressure pressure: String) -> Int {
        switch pressureRank(pressure) {
        case 3: return 90
        case 2: return 60
        case 1: return 30
        default: return 0
        }
    }

    private func thermalStatusCandidate(
        for result: ThermalCollectionResult
    ) -> ThermalStatusCandidate? {
        var explicit: ThermalStatusCandidate?
        if let pressure = result.thermalPressure {
            explicit = ThermalStatusCandidate(
                level: normalizedPressure(pressure),
                percentage: defaultPercentage(forPressure: pressure),
                source: result.status.source
            )
        }
        for reading in result.readings
        where reading.kind == .thermalPressure && reading.textValue != nil {
            let text = reading.textValue ?? ""
            let candidate = ThermalStatusCandidate(
                level: normalizedPressure(text),
                percentage: defaultPercentage(forPressure: text),
                source: reading.source
            )
            if explicit == nil || pressureRank(candidate.level) > pressureRank(explicit?.level ?? "") {
                explicit = candidate
            }
        }

        guard let throttle = result.throttling else { return explicit }
        let throttleCandidate = ThermalStatusCandidate(
            level: normalizedPressure(throttle.level),
            percentage: throttle.percentage,
            source: throttle.source
        )
        guard let explicit else { return throttleCandidate }
        let explicitRank = pressureRank(explicit.level)
        let throttleRank = pressureRank(throttleCandidate.level)
        if explicitRank < throttleRank { return throttleCandidate }
        if explicitRank > throttleRank {
            return ThermalStatusCandidate(
                level: explicit.level,
                percentage: max(explicit.percentage, throttleCandidate.percentage),
                source: explicit.source
            )
        }
        return ThermalStatusCandidate(
            level: explicit.level,
            percentage: throttleCandidate.percentage > 0
                ? throttleCandidate.percentage
                : explicit.percentage,
            source: explicit.source
        )
    }

    private struct ThermalStatusCandidate {
        var level: String
        var percentage: Int
        var source: String
    }
}

public struct ThermalCollectionResult: Sendable {
    public static let maximumWarningCount = 20
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
        var normalizedStatus = status
        normalizedStatus.warnings = Self.boundedWarnings(status.warnings)
        self.status = normalizedStatus
        self.componentPowers = componentPowers
        self.throttling = throttling
        self.thermalPressure = thermalPressure
    }

    public static func boundedWarnings(_ warnings: [String]) -> [String] {
        guard warnings.count > maximumWarningCount else { return warnings }
        let retained = maximumWarningCount - 1
        return Array(warnings.prefix(retained)) + [
            "\(warnings.count - retained) additional warnings omitted"
        ]
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
