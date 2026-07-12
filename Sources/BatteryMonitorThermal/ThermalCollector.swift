import BatteryMonitorShared
import Foundation

public protocol ThermalCollector: Sendable {
    var source: String { get }
    func collect(at timestamp: Date) -> ThermalCollectionResult
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
