import BatteryMonitorShared
import Foundation

public protocol ThermalCollector: Sendable {
    var source: String { get }
    func collect(at timestamp: Date) -> ThermalCollectionResult
}

public struct ThermalCollectionResult: Sendable {
    public var readings: [DetailedThermalReading]
    public var status: ThermalSourceStatus

    public init(readings: [DetailedThermalReading], status: ThermalSourceStatus) {
        self.readings = readings
        self.status = status
    }

    public static func completed(
        source: String,
        readings: [DetailedThermalReading],
        durationMilliseconds: Double,
        warnings: [String] = [],
        scannedRecordCount: Int? = nil
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
            )
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
