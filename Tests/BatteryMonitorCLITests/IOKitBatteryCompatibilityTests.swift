import XCTest
@testable import BatteryMonitorCLI

final class IOKitBatteryCompatibilityTests: XCTestCase {
    func testLegacyRootPropertiesTakePrecedenceOverNestedFallbacks() {
        var battery = BatteryData()
        let rootProps: [String: Any] = [
            "DesignCapacity": 5000,
            "AppleRawMaxCapacity": 4500,
            "NominalChargeCapacity": 4600,
            "Temperature": 3015,
            "VirtualTemperature": 3025,
            "PackReserve": 120,
            "BatteryHealth": "Normal",
            "LifetimeData": [
                "TotalOperatingTime": 1234,
                "AverageTemperature": 239,
                "MaximumTemperature": 42,
                "MinimumTemperature": 14
            ],
            "BatteryData": [
                "DesignCapacity": 3900,
                "FullChargeCapacity": 3800,
                "NominalChargeCapacity": 3950,
                "Temperature": 3589,
                "VirtualTemperature": 3589,
                "PackReserve": 80
            ]
        ]

        IOKitBattery.enrichBatteryData(&battery, fromProperties: rootProps, source: .rootBattery)

        XCTAssertEqual(battery.designCapacity, 5000)
        XCTAssertEqual(battery.actualMaxCapacityMah, 4500)
        XCTAssertEqual(battery.nominalChargeCapacity, 4600)
        XCTAssertEqual(battery.packReserve, 120)
        XCTAssertEqual(battery.condition, "Normal")
        XCTAssertEqual(battery.temperature, 28.35, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(battery.virtualTemperature), 29.35, accuracy: 0.01)
        XCTAssertEqual(battery.totalOperatingTime, 1234)
        XCTAssertEqual(try XCTUnwrap(battery.averageTemperature), 23.9, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(battery.maximumTemperature), 42.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(battery.minimumTemperature), 14.0, accuracy: 0.01)
        XCTAssertEqual(battery.healthPercent, 90)
    }

    func testBatteryPackFallbackRestoresMacOS27NestedMetrics() {
        var battery = BatteryData()
        let rootProps: [String: Any] = [
            "CycleCount": 305,
            "BatteryData": [
                "DesignCapacity": 4629,
                "FullChargeCapacity": 4020,
                "NominalChargeCapacity": 4147
            ],
            "BatteryInvalidWakeSeconds": 30
        ]
        let packProps: [String: Any] = [
            "CarrierMode": [
                "CarrierModeStatus": 0,
                "CarrierModeLowVoltage": 3600,
                "CarrierModeHighVoltage": 4100
            ],
            "BatteryData": [
                "AppleRawMaxCapacity": 4020,
                "ChemID": 29961,
                "DataFlashWriteCount": 10031,
                "DailyMinSoc": 0,
                "DailyMaxSoc": 100,
                "GasGaugeFirmwareVersion": 2,
                "LifetimeData": [
                    "AverageTemperature": 239,
                    "CycleCountLastQmax": 304,
                    "MaximumTemperature": 42,
                    "MinimumTemperature": 14,
                    "TotalOperatingTime": 12634
                ],
                "ManufactureDate": Int64(59589201507123),
                "PackReserve": 127,
                "Temperature": 3589,
                "VirtualTemperature": 3589
            ]
        ]

        IOKitBattery.enrichBatteryData(&battery, fromProperties: rootProps, source: .rootBattery)
        IOKitBattery.enrichBatteryData(&battery, fromProperties: packProps, source: .batteryPack)

        XCTAssertEqual(battery.designCapacity, 4629)
        XCTAssertEqual(battery.actualMaxCapacityMah, 4020)
        XCTAssertEqual(battery.nominalChargeCapacity, 4147)
        XCTAssertEqual(battery.healthPercent, 86)
        XCTAssertEqual(battery.temperature, 35.89, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(battery.virtualTemperature), 35.89, accuracy: 0.01)
        XCTAssertEqual(battery.packReserve, 127)
        XCTAssertEqual(battery.gaugeWriteCount, 10031)
        XCTAssertEqual(battery.invalidWakeSeconds, 30)
        XCTAssertEqual(battery.chemID, 29961)
        XCTAssertEqual(battery.chemistry, "Li-ion (High Energy) (ID: 29961)")
        XCTAssertEqual(battery.gasGaugeFirmwareVersion, "v2")
        XCTAssertEqual(battery.totalOperatingTime, 12634)
        XCTAssertEqual(try XCTUnwrap(battery.averageTemperature), 23.9, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(battery.maximumTemperature), 42.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(battery.minimumTemperature), 14.0, accuracy: 0.01)
        XCTAssertEqual(battery.cycleCountLastQmax, 304)
        XCTAssertFalse(battery.shippingModeActive)
        XCTAssertEqual(try XCTUnwrap(battery.shippingModeVoltageMin), 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(battery.shippingModeVoltageMax), 4.1, accuracy: 0.001)
        XCTAssertEqual(battery.estimatedCyclesTo80Percent, 130)
    }
}
