import XCTest
@testable import BatteryMonitorShared

final class DetailedThermalTelemetryTests: XCTestCase {
    func testOldSnapshotDecodesWithEmptyDetailedTelemetry() throws {
        let json = #"{"generatedAt":"2026-07-11T00:00:00Z","thermalReadings":[],"componentPowers":[],"throttling":{"level":"Nominal","percentage":0,"source":"pmset"},"messages":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(ThermalSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.detailedReadings, [])
        XCTAssertEqual(snapshot.sourceStatuses, [])
    }

    func testDetailedReadingCodableRoundTripPreservesEveryField() throws {
        let reading = DetailedThermalReading(
            source: "smc",
            identifier: "Tp01",
            label: "CPU performance core 1",
            category: .cpu,
            kind: .temperature,
            numericValue: 72.5,
            textValue: "warm",
            unit: "C",
            classification: .heuristic,
            warnings: ["mapped from an observed key"]
        )

        let data = try JSONEncoder().encode(reading)
        let decoded = try JSONDecoder().decode(DetailedThermalReading.self, from: data)

        XCTAssertEqual(decoded, reading)
    }

    func testThermalSnapshotCodableRoundTripPreservesLegacyAndDetailedFields() throws {
        let detailedReading = DetailedThermalReading.temperature(
            source: "smc",
            identifier: "Tp01",
            label: "CPU P1",
            category: .cpu,
            celsius: 72,
            classification: .heuristic,
            warnings: ["observed mapping"]
        )
        let sourceStatus = ThermalSourceStatus(
            source: "smc",
            state: .partial,
            readingCount: 1,
            durationMilliseconds: 12.5,
            warnings: ["one key was unreadable"],
            error: "read failure",
            scannedRecordCount: 186
        )
        let snapshot = ThermalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 123.5),
            thermalReadings: [ThermalReading(name: "CPU", celsius: 72, source: "smc")],
            componentPowers: [ComponentPowerReading(name: "CPU", watts: 4.25, source: "powermetrics")],
            throttling: ThrottlingStatus(level: "Moderate", percentage: 60, source: "pmset"),
            thermalPressure: "Moderate",
            messages: ["partial source data"],
            detailedReadings: [detailedReading],
            sourceStatuses: [sourceStatus]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ThermalSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    func testTemperatureFactoryProvidesCollectorDefaults() {
        let reading = DetailedThermalReading.temperature(
            source: "iohid",
            identifier: "sensor-1",
            label: "Enclosure",
            category: .enclosure,
            celsius: 41
        )

        XCTAssertEqual(reading.kind, .temperature)
        XCTAssertEqual(reading.numericValue, 41)
        XCTAssertNil(reading.textValue)
        XCTAssertEqual(reading.unit, "C")
        XCTAssertEqual(reading.classification, .known)
        XCTAssertEqual(reading.warnings, [])
    }

    func testSummaryUsesApprovedPreferredSources() {
        let readings = [
            temperature("iohid", "cpu-hid", "CPU HID", .cpu, 92),
            temperature("smc", "cpu-smc", "CPU SMC", .cpu, 71),
            temperature("powermetrics", "gpu-pm", "GPU", .gpu, 94),
            temperature("smc", "gpu-smc", "GPU SMC", .gpu, 70),
            temperature("iohid", "memory-hid", "Memory HID", .memory, 90),
            temperature("smc", "memory-smc", "Memory SMC", .memory, 69),
            temperature("smc", "battery-smc", "Battery SMC", .battery, 55),
            temperature("appleSmartBattery", "battery-current", "Battery", .battery, 38),
            temperature("smc", "storage-smc", "Storage SMC", .storage, 80),
            temperature("iohid", "storage-hid", "Storage HID", .storage, 49),
            temperature("smc", "pmu-smc", "PMU SMC", .pmu, 81),
            temperature("iohid", "pmu-hid", "PMU HID", .pmu, 50),
            temperature("smc", "case-smc", "Case SMC", .enclosure, 82),
            temperature("iohid", "case-hid", "Case HID", .enclosure, 51),
            temperature("smc", "system-smc", "System SMC", .system, 83),
            temperature("iohid", "system-hid", "System HID", .system, 52)
        ]

        let summary = ThermalSummaryBuilder.build(from: readings)

        XCTAssertEqual(summary.first { $0.name == "CPU" }?.source, "smc")
        XCTAssertEqual(summary.first { $0.name == "GPU" }?.source, "smc")
        XCTAssertEqual(summary.first { $0.name == "Memory" }?.source, "smc")
        XCTAssertEqual(summary.first { $0.name == "Battery" }?.source, "appleSmartBattery")
        XCTAssertEqual(summary.first { $0.name == "Storage" }?.source, "iohid")
        XCTAssertEqual(summary.first { $0.name == "PMU" }?.source, "iohid")
        XCTAssertEqual(summary.first { $0.name == "Enclosure" }?.source, "iohid")
        XCTAssertEqual(summary.first { $0.name == "System" }?.source, "iohid")
    }

    func testSummaryUsesHottestPlausibleReadingWithinSelectedSource() {
        let readings = [
            temperature("iohid", "cpu-hid", "CPU HID", .cpu, 61),
            temperature("smc", "Tp01", "CPU P1", .cpu, 72),
            temperature("smc", "Tp05", "CPU P2", .cpu, 78)
        ]

        let summary = ThermalSummaryBuilder.build(from: readings)

        XCTAssertEqual(summary.first?.celsius, 78)
        XCTAssertEqual(summary.first?.source, "smc")
    }

    func testSummaryAcceptsOnlyNormalizedCelsiusUnits() {
        let acceptedUnits = ["C", "c", "\u{00B0}C", "\u{00B0}c", "degC", "DEGC", "celsius", "CeLsIuS"]
        let rejectedUnits: [String?] = ["F", "K", nil, "watts"]

        for unit in acceptedUnits {
            let reading = detailedTemperature(source: "smc", identifier: unit, unit: unit, celsius: 72)
            XCTAssertEqual(ThermalSummaryBuilder.build(from: [reading]).map(\.celsius), [72], unit)
        }

        for unit in rejectedUnits {
            let reading = detailedTemperature(source: "smc", identifier: unit ?? "nil", unit: unit, celsius: 72)
            XCTAssertEqual(ThermalSummaryBuilder.build(from: [reading]), [], unit ?? "nil")
        }
    }

    func testEqualRankSourceSelectionIsStableAcrossInputPermutations() {
        let uppercaseSource = detailedTemperature(
            source: "Fallback",
            identifier: "uppercase",
            unit: "C",
            celsius: 40
        )
        let lowercaseSource = detailedTemperature(
            source: "fallback",
            identifier: "lowercase",
            unit: "C",
            celsius: 90
        )
        let laterSource = detailedTemperature(
            source: "z-source",
            identifier: "later",
            unit: "C",
            celsius: 100
        )
        let permutations = [
            [lowercaseSource, uppercaseSource, laterSource],
            [laterSource, uppercaseSource, lowercaseSource],
            [uppercaseSource, laterSource, lowercaseSource]
        ]

        for readings in permutations {
            let summary = ThermalSummaryBuilder.build(from: readings)
            XCTAssertEqual(summary.map(\.source), ["Fallback"])
            XCTAssertEqual(summary.map(\.celsius), [40])
        }
    }

    func testSummaryUsesStableCategoryOrderNamesAndOriginalSource() {
        let readings = [
            temperature("fallback-system", "unknown", "Mystery", .unknown, 25),
            temperature("fallback-system", "system", "SoC", .system, 26),
            temperature("iohid", "enclosure", "Palm Rest", .enclosure, 27),
            temperature("iohid", "pmu", "PMU Rail", .pmu, 28),
            temperature("iohid", "storage", "NAND", .storage, 29),
            temperature("smc", "memory", "DRAM", .memory, 30),
            temperature("appleSmartBattery", "battery", "Pack", .battery, 31),
            temperature("smc", "gpu", "GPU Die", .gpu, 32),
            temperature("smc", "cpu", "CPU Die", .cpu, 33)
        ]

        let summary = ThermalSummaryBuilder.build(from: readings)

        XCTAssertEqual(summary.map(\.name), [
            "CPU", "GPU", "Battery", "Memory", "Storage", "PMU", "Enclosure", "System"
        ])
        XCTAssertEqual(summary.map(\.source), [
            "smc", "smc", "appleSmartBattery", "smc", "iohid", "iohid", "iohid", "fallback-system"
        ])
    }

    func testSummaryExcludesBatteryLifetimeAndAggregateReadings() {
        let readings = [
            temperature("appleSmartBattery", "LifetimeData/Temperature", "Battery current", .battery, 99),
            temperature("appleSmartBattery", "MinimumTemperature", "Battery minimum", .battery, 1),
            temperature("appleSmartBattery", "MaximumTemperature", "Battery maximum", .battery, 98),
            temperature("appleSmartBattery", "AverageTemperature", "Battery average", .battery, 70),
            temperature("appleSmartBattery", "Temperature", "Battery current", .battery, 37)
        ]

        let summary = ThermalSummaryBuilder.build(from: readings)

        XCTAssertEqual(summary.map(\.name), ["Battery"])
        XCTAssertEqual(summary.first?.celsius, 37)
    }

    func testSummaryFiltersNonTemperatureNonfiniteAndImplausibleReadings() {
        let readings = [
            temperature("smc", "cpu-low", "CPU low", .cpu, -41),
            temperature("smc", "cpu-high", "CPU high", .cpu, 151),
            temperature("smc", "cpu-nan", "CPU NaN", .cpu, .nan),
            temperature("smc", "cpu-infinity", "CPU infinity", .cpu, .infinity),
            DetailedThermalReading(
                source: "processInfo",
                identifier: "thermal-pressure",
                label: "Thermal pressure",
                category: .system,
                kind: .thermalPressure,
                numericValue: 80,
                textValue: "serious",
                unit: nil,
                classification: .known,
                warnings: []
            ),
            temperature("appleSmartBattery", "battery-too-hot", "Battery", .battery, 101),
            temperature("smc", "cpu-valid", "CPU", .cpu, -40),
            temperature("appleSmartBattery", "battery-valid", "Battery", .battery, 100)
        ]

        let summary = ThermalSummaryBuilder.build(from: readings)

        XCTAssertEqual(summary.map(\.name), ["CPU", "Battery"])
        XCTAssertEqual(summary.map(\.celsius), [-40, 100])
    }

    private func temperature(
        _ source: String,
        _ identifier: String,
        _ label: String,
        _ category: ThermalCategory,
        _ celsius: Double
    ) -> DetailedThermalReading {
        .temperature(
            source: source,
            identifier: identifier,
            label: label,
            category: category,
            celsius: celsius
        )
    }

    private func detailedTemperature(
        source: String,
        identifier: String,
        unit: String?,
        celsius: Double
    ) -> DetailedThermalReading {
        DetailedThermalReading(
            source: source,
            identifier: identifier,
            label: identifier,
            category: .cpu,
            kind: .temperature,
            numericValue: celsius,
            unit: unit,
            classification: .known
        )
    }
}
