import Foundation
import XCTest
@testable import BatteryMonitorShared
@testable import BatteryMonitorThermal

final class IOKitThermalCollectorTests: XCTestCase {
    func testBatteryMapperUsesSourceSpecificTemperatureConversionsAndLifetimeIdentity() throws {
        let root = AppleSmartBatteryThermalCollector.map(
            properties: [
                "Temperature": 3095,
                "VirtualTemperature": 3025,
                "LifetimeData": [
                    "AverageTemperature": 239,
                    "MaximumTemperature": 42,
                    "MinimumTemperature": 14
                ]
            ],
            source: .rootBattery
        )
        let pack = AppleSmartBatteryThermalCollector.map(
            properties: ["Temperature": 3589, "VirtualTemperature": 3612],
            source: .batteryPack
        )

        XCTAssertEqual(try value("root.Temperature", in: root), 36.35, accuracy: 0.01)
        XCTAssertEqual(try value("root.VirtualTemperature", in: root), 29.35, accuracy: 0.01)
        XCTAssertEqual(try value("pack.Temperature", in: pack), 35.89, accuracy: 0.01)
        XCTAssertEqual(try value("pack.VirtualTemperature", in: pack), 36.12, accuracy: 0.01)
        XCTAssertEqual(try value("root.LifetimeData.AverageTemperature", in: root), 23.9)
        XCTAssertEqual(try value("root.LifetimeData.MaximumTemperature", in: root), 42)
        XCTAssertEqual(try value("root.LifetimeData.MinimumTemperature", in: root), 14)
        XCTAssertEqual(
            root.first { $0.identifier.contains("AverageTemperature") }?.label,
            "Battery lifetime average"
        )
    }

    func testBatteryCollectorReportsUnavailablePartialFailedAndTruePropertyCounts() {
        let absent = AppleSmartBatteryThermalCollector(provider: FixtureBatteryProvider(
            batch: BatteryPropertyBatch(propertySets: [], discoveredServiceCount: 0, scannedPropertyCount: 0)
        )).collect(at: .distantPast)
        XCTAssertEqual(absent.status.state, .unavailable)

        let partial = AppleSmartBatteryThermalCollector(provider: FixtureBatteryProvider(
            batch: BatteryPropertyBatch(
                propertySets: [BatteryPropertySet(source: .rootBattery, properties: ["Temperature": 3095, "Voltage": 12_000])],
                discoveredServiceCount: 2,
                scannedPropertyCount: 7,
                warnings: ["pack properties unavailable"]
            )
        )).collect(at: .distantPast)
        XCTAssertEqual(partial.status.state, .partial)
        XCTAssertEqual(partial.status.readingCount, 1)
        XCTAssertEqual(partial.status.scannedRecordCount, 7)

        let failed = AppleSmartBatteryThermalCollector(provider: FixtureBatteryProvider(
            batch: BatteryPropertyBatch(
                propertySets: [BatteryPropertySet(source: .rootBattery, properties: ["Voltage": 12_000])],
                discoveredServiceCount: 1,
                scannedPropertyCount: 1,
                warnings: Array(repeating: "property failure", count: 40)
            )
        )).collect(at: .distantPast)
        XCTAssertEqual(failed.status.state, .failed)
        XCTAssertEqual(failed.status.scannedRecordCount, 1)
        XCTAssertLessThanOrEqual(failed.status.warnings.count, 21)
    }

    func testProcessInfoMapsEveryThermalStateToPressureText() {
        let cases: [(ProcessThermalState, String)] = [
            (.nominal, "nominal"), (.fair, "fair"), (.serious, "serious"),
            (.critical, "critical"), (.unknown, "unknown")
        ]

        for (state, expected) in cases {
            let result = ProcessInfoThermalCollector(provider: FixtureProcessProvider(state: state))
                .collect(at: .distantPast)
            XCTAssertEqual(result.status.state, .success)
            XCTAssertEqual(result.readings.first?.source, "processInfo")
            XCTAssertEqual(result.readings.first?.identifier, "thermalState")
            XCTAssertEqual(result.readings.first?.kind, .thermalPressure)
            XCTAssertEqual(result.readings.first?.textValue, expected)
        }
    }

    func testRegistryFlattenerPreservesNestedPathsAndTypedLeaves() {
        let flattened = RegistryPropertyFlattener.flatten([
            "Thermal": ["CPU": ["Temperature": 44.5], "Pressure": "fair"],
            "Labels": ["CPU", "GPU"],
            "Enabled": true
        ])

        XCTAssertEqual(flattened["Thermal.CPU.Temperature"], .number(44.5))
        XCTAssertEqual(flattened["Thermal.Pressure"], .string("fair"))
        XCTAssertEqual(flattened["Labels.1"], .string("GPU"))
        XCTAssertEqual(flattened["Enabled"], .bool(true))
    }

    func testRegistryMapperEmitsOnlyGenuineCelsiusAndPressureWithPathCategories() {
        let snapshots = [
            RegistryServiceSnapshot(
                name: "thermal-zone",
                serviceClass: "AppleThermal",
                path: "IOService:/CPU/GPU/NAND",
                properties: [
                    "CPU Temperature": 61.5,
                    "GPU": ["temperature": "54 C"],
                    "NANDTemperature": 47,
                    "RawTemperature": 3_095,
                    "ThermalPressure": "serious",
                    "Power": 12.0,
                    "TemperatureTarget": 3_000,
                    "defaultTemperatureCorrectionValue": -1,
                    "set0DTempSensorValue": -1
                ]
            ),
            RegistryServiceSnapshot(
                name: "memory-pmu",
                serviceClass: "sensor",
                path: "IOService:/PMU/Memory/Enclosure/Battery",
                properties: ["MemoryTemp": 52, "EnclosureTemp": 39, "BatteryTemp": 34]
            )
        ]

        let readings = IORegistryThermalCollector.map(snapshots: snapshots)

        XCTAssertEqual(readings.filter { $0.kind == .temperature }.count, 6)
        XCTAssertFalse(readings.contains { $0.numericValue == 3_095 || $0.numericValue == 3_000 })
        XCTAssertFalse(readings.contains { $0.identifier.contains("Correction") })
        XCTAssertFalse(readings.contains { $0.identifier.contains("set0D") })
        XCTAssertEqual(readings.first { $0.identifier.contains("CPU Temperature") }?.category, .cpu)
        XCTAssertEqual(readings.first { $0.identifier.contains("GPU.temperature") }?.category, .gpu)
        XCTAssertEqual(readings.first { $0.identifier.contains("NANDTemperature") }?.category, .storage)
        XCTAssertEqual(readings.first { $0.identifier.contains("BatteryTemp") }?.category, .battery)
        XCTAssertEqual(readings.first { $0.identifier.contains("MemoryTemp") }?.category, .memory)
        XCTAssertEqual(readings.first { $0.identifier.contains("EnclosureTemp") }?.category, .enclosure)
        XCTAssertEqual(readings.first { $0.kind == .thermalPressure }?.textValue, "serious")
        XCTAssertTrue(readings.allSatisfy { $0.source == "ioRegistry" })
    }

    func testRegistryZeroMatchesIsSuccessfulAndProviderCountsAreTruthful() {
        let collector = IORegistryThermalCollector(provider: FixtureRegistryProvider(batch: RegistrySnapshotBatch(
            snapshots: [RegistryServiceSnapshot(
                name: "display",
                serviceClass: "AppleDisplay",
                path: "IOService:/Display",
                properties: ["Brightness": 80]
            )],
            scannedServiceCount: 4,
            scannedPropertyCount: 17,
            warnings: []
        )))

        let result = collector.collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .success)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(result.status.scannedRecordCount, 17)
        XCTAssertTrue(result.status.warnings.contains { $0.contains("4 services") && $0.contains("17 properties") })
    }

    func testRegistryTemperatureMatchingUsesLeafTokensInsteadOfTempSubstrings() {
        let falseContext = RegistryServiceSnapshot(
            name: "statistics",
            serviceClass: "monitor",
            path: "IOService:/Statistics",
            properties: [
                "Statistics": ["Number of failed attempts": 12],
                "attemptCount": 4
            ]
        )
        let genuine = RegistryServiceSnapshot(
            name: "thermal-zone",
            serviceClass: "AppleThermal",
            path: "IOService:/CPU",
            properties: [
                "CPU Temperature": 71,
                "DieTemp": 68,
                "VirtualTemperature": 64
            ]
        )

        let falseReadings = IORegistryThermalCollector.map(snapshots: [falseContext])
        let genuineReadings = IORegistryThermalCollector.map(snapshots: [genuine])

        XCTAssertTrue(falseReadings.isEmpty)
        XCTAssertTrue(ThermalSummaryBuilder.build(from: falseReadings).isEmpty)
        XCTAssertEqual(
            Set(genuineReadings.map(\.label)),
            Set(["CPU Temperature", "DieTemp", "VirtualTemperature"])
        )
    }

    func testBatteryReadingWarningsMakeSourcePartialAndPreserveProviderWarnings() {
        let collector = AppleSmartBatteryThermalCollector(provider: FixtureBatteryProvider(
            batch: BatteryPropertyBatch(
                propertySets: [BatteryPropertySet(
                    source: .rootBattery,
                    properties: ["Temperature": 2_000]
                )],
                discoveredServiceCount: 1,
                scannedPropertyCount: 1,
                warnings: ["provider warning"]
            )
        ))

        let result = collector.collect(at: .distantPast)

        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.status.state, .partial)
        XCTAssertTrue(result.status.warnings.contains("provider warning"))
        XCTAssertTrue(result.status.warnings.contains { $0.contains("plausibility range") })
    }

    private func value(_ identifier: String, in readings: [DetailedThermalReading]) throws -> Double {
        try XCTUnwrap(readings.first { $0.identifier == identifier }?.numericValue)
    }
}

private struct FixtureBatteryProvider: BatteryPropertyProviding {
    var batch: BatteryPropertyBatch
    func propertyBatch() throws -> BatteryPropertyBatch { batch }
}

private struct FixtureProcessProvider: ProcessThermalStateProviding {
    var state: ProcessThermalState
    func thermalState() -> ProcessThermalState { state }
}

private struct FixtureRegistryProvider: RegistrySnapshotProviding {
    var batch: RegistrySnapshotBatch
    func snapshotBatch() throws -> RegistrySnapshotBatch { batch }
}
