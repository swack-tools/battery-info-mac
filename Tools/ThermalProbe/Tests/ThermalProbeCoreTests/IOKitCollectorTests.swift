import Foundation
import XCTest
@testable import ThermalProbeCore

final class IOKitCollectorTests: XCTestCase {
    func testBatteryTemperatureUnitsRemainSourceSpecific() throws {
        let properties: [String: Any] = [
            "Temperature": 3095,
            "VirtualTemperature": 3095,
            "LifetimeData": [
                "AverageTemperature": 239,
                "MaximumTemperature": 42,
                "MinimumTemperature": 14
            ],
            "TimeChargingThermallyLimited": 120
        ]

        let readings = BatteryCollector.map(
            properties: properties,
            source: .rootBattery,
            timestamp: .distantPast
        )

        XCTAssertEqual(
            try XCTUnwrap(readings.first { $0.identifier == "Temperature" }?.number),
            36.35,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(readings.first { $0.identifier == "VirtualTemperature" }?.number),
            36.35,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(readings.first { $0.identifier == "LifetimeData.AverageTemperature" }?.number),
            23.9,
            accuracy: 0.01
        )
        XCTAssertEqual(
            readings.first { $0.identifier == "TimeChargingThermallyLimited" }?.unit,
            "s"
        )
    }

    func testBatteryPackUsesCentiCelsius() throws {
        let readings = BatteryCollector.map(
            properties: ["Temperature": 3589],
            source: .batteryPack,
            timestamp: .distantPast
        )

        XCTAssertEqual(try XCTUnwrap(readings.first?.number), 35.89, accuracy: 0.01)
    }

    func testRegistryWalkerRetainsTypedNestedPath() {
        let flattened = RegistryFlattener.flatten([
            "Thermal": ["Limit": 72, "Enabled": true],
            "Labels": ["CPU", "GPU"]
        ])

        XCTAssertEqual(flattened["Thermal.Limit"], .number(72))
        XCTAssertEqual(flattened["Thermal.Enabled"], .bool(true))
        XCTAssertEqual(flattened["Labels.0"], .string("CPU"))
        XCTAssertEqual(flattened["Labels.1"], .string("GPU"))
    }

    func testRegistryFilterIncludesThermalPropertiesAndRawCLPCLimits() {
        let ordinary = RegistryServiceSnapshot(
            name: "Display",
            serviceClass: "AppleDisplay",
            path: "IOService:/Display",
            properties: ["PanelTemperature": 31, "Brightness": 80]
        )
        let clpc = RegistryServiceSnapshot(
            name: "AppleCLPC",
            serviceClass: "AppleCLPC",
            path: "IOService:/AppleCLPC",
            properties: ["CPU_Power_Limit": 90, "Unrelated": 1]
        )

        let readings = IORegistryThermalCollector.map(
            snapshots: [ordinary, clpc],
            timestamp: .distantPast
        )

        XCTAssertTrue(readings.contains { $0.identifier.contains("PanelTemperature") })
        XCTAssertFalse(readings.contains { $0.identifier.contains("Brightness") })
        let limit = readings.first { $0.identifier.contains("CPU_Power_Limit") }
        XCTAssertEqual(limit?.kind, .rawContext)
        XCTAssertNil(limit?.unit)
        XCTAssertFalse(readings.contains { $0.identifier.contains("Unrelated") })
    }

    func testProcessThermalStateIsPressureNotTemperature() {
        let reading = ProcessThermalStateCollector.map(.serious, timestamp: .distantPast)

        XCTAssertEqual(reading.value, .text("serious"))
        XCTAssertEqual(reading.kind, .thermalPressure)
        XCTAssertNil(reading.unit)
    }
}
