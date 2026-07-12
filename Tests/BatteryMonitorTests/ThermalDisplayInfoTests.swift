import BatteryMonitorShared
import XCTest
@testable import BatteryMonitor

final class ThermalDisplayInfoTests: XCTestCase {
    func testLocalBatteryTelemetryKeepsLifetimeValuesOutOfGeneralSummary() {
        var battery = BatteryData()
        battery.temperature = 31
        battery.virtualTemperature = 32
        battery.minimumTemperature = 14
        battery.averageTemperature = 24
        battery.maximumTemperature = 42

        let telemetry = BatteryDisplayInfo.localThermalTelemetry(from: battery)

        XCTAssertEqual(telemetry.summary.map(\.name), ["Battery"])
        XCTAssertEqual(
            Set(telemetry.detailed.map(\.label)),
            Set([
                "Battery",
                "Battery Virtual",
                "Battery Lifetime Min",
                "Battery Lifetime Average",
                "Battery Lifetime Max"
            ])
        )
    }

    func testPrivilegedSnapshotReplacesDuplicateSummaryAndSuppliesAdvancedData() {
        var info = BatteryDisplayInfo()
        info.thermalReadings = [
            ThermalReading(name: "Battery", celsius: 31, source: "IOKit")
        ]
        info.detailedThermalReadings = [
            .temperature(
                source: "iokitLocal",
                identifier: "battery",
                label: "Battery",
                category: .battery,
                celsius: 31,
                classification: .known
            )
        ]
        let sourceStatus = ThermalSourceStatus(
            source: "smc",
            state: .success,
            readingCount: 1,
            durationMilliseconds: 5,
            scannedRecordCount: 500
        )
        let snapshot = ThermalSnapshot(
            generatedAt: .distantPast,
            thermalReadings: [
                ThermalReading(name: "CPU", celsius: 72, source: "smc"),
                ThermalReading(name: "Battery", celsius: 33, source: "appleSmartBattery")
            ],
            detailedReadings: [
                .temperature(
                    source: "smc",
                    identifier: "Tp01",
                    label: "CPU performance core 1",
                    category: .cpu,
                    celsius: 72,
                    classification: .known
                )
            ],
            sourceStatuses: [sourceStatus]
        )

        info.applyPrivilegedThermalSnapshot(snapshot)

        XCTAssertEqual(info.thermalReadings.map(\.name), ["CPU", "Battery"])
        XCTAssertEqual(info.thermalReadings.last?.celsius, 33)
        XCTAssertEqual(info.detailedThermalReadings, snapshot.detailedReadings)
        XCTAssertEqual(info.thermalSourceStatuses, [sourceStatus])
    }

    func testEmptyPrivilegedSummaryPreservesLocalBatteryFallback() {
        var info = BatteryDisplayInfo()
        let local = ThermalReading(name: "Battery", celsius: 30, source: "IOKit")
        info.thermalReadings = [local]

        info.applyPrivilegedThermalSnapshot(ThermalSnapshot(generatedAt: .distantPast))

        XCTAssertEqual(info.thermalReadings, [local])
    }
}
