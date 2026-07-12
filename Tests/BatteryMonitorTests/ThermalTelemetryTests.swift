import XCTest
@testable import BatteryMonitorShared

final class ThermalTelemetryTests: XCTestCase {
    func testPmsetParserMapsNoWarningsToNominalZeroThrottle() {
        let output = """
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        Note: No CPU power status has been recorded
        """

        let status = PMSetThermalParser.parse(output)

        XCTAssertEqual(status.level, "Nominal")
        XCTAssertEqual(status.percentage, 0)
        XCTAssertEqual(status.source, "pmset")
    }

    func testPowermetricsParserExtractsPowerAndThermalPressure() {
        let output = """
        CPU Power: 1234 mW
        GPU Power: 456 mW
        ANE Power: 78 mW
        DRAM Power: 910 mW
        Thermal pressure: moderate
        SFI Class 2: 37% forced idle
        CPU Power limit: 68%
        """

        let snapshot = PowermetricsThermalParser.parse(
            output,
            generatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.componentPowers.first { $0.name == "CPU" }?.watts), 1.234, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.componentPowers.first { $0.name == "GPU" }?.watts), 0.456, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.componentPowers.first { $0.name == "ANE" }?.watts), 0.078, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.componentPowers.first { $0.name == "DRAM" }?.watts), 0.910, accuracy: 0.001)
        XCTAssertEqual(snapshot.thermalPressure, "Moderate")
        XCTAssertEqual(snapshot.throttling.percentage, 68)
        XCTAssertEqual(snapshot.throttling.level, "Moderate")
    }

    func testTemperatureColorBandsAreComponentAware() {
        XCTAssertEqual(ThermalBand.band(for: 39, component: "Battery"), .green)
        XCTAssertEqual(ThermalBand.band(for: 44, component: "Battery"), .orange)
        XCTAssertEqual(ThermalBand.band(for: 46, component: "Battery"), .red)
        XCTAssertEqual(ThermalBand.band(for: 75, component: "CPU"), .orange)
        XCTAssertEqual(ThermalBand.band(for: 91, component: "GPU"), .red)
    }

    func testPowermetricsParserExtractsTemperatureReadingsWhenPresent() throws {
        let output = """
        CPU die temperature: 72.5 C
        GPU temperature: 68 C
        """

        let snapshot = PowermetricsThermalParser.parse(output)

        let cpu = try XCTUnwrap(snapshot.thermalReadings.first { $0.name == "CPU Die" })
        XCTAssertEqual(cpu.celsius, 72.5, accuracy: 0.001)
        XCTAssertEqual(cpu.band, .orange)

        let gpu = try XCTUnwrap(snapshot.thermalReadings.first { $0.name == "GPU" })
        XCTAssertEqual(gpu.celsius, 68, accuracy: 0.001)
        XCTAssertEqual(gpu.band, .green)
    }

    func testPowermetricsParserExtractsTemperatureReadingsWithoutColon() throws {
        let output = """
        CPU die temperature 72.5 C
        GPU temperature 68 C
        """

        let snapshot = PowermetricsThermalParser.parse(output)

        let cpu = try XCTUnwrap(snapshot.thermalReadings.first { $0.name == "CPU Die" })
        XCTAssertEqual(cpu.celsius, 72.5, accuracy: 0.001)

        let gpu = try XCTUnwrap(snapshot.thermalReadings.first { $0.name == "GPU" })
        XCTAssertEqual(gpu.celsius, 68, accuracy: 0.001)
    }

    func testPowermetricsParserIgnoresDecorativeThermalPressureHeader() {
        let output = """
        **** Thermal pressure ****
        """

        let snapshot = PowermetricsThermalParser.parse(output)

        XCTAssertNil(snapshot.thermalPressure)
        XCTAssertEqual(snapshot.throttling.level, "Nominal")
    }

    func testPowermetricsParserDeduplicatesComponentPowerRows() {
        let output = """
        CPU Power: 0 mW
        GPU Power: 547 mW
        ANE Power: 0 mW
        GPU Power: 547 mW
        """

        let snapshot = PowermetricsThermalParser.parse(output)

        XCTAssertEqual(snapshot.componentPowers.map(\.name), ["CPU", "GPU", "ANE"])
    }
}
