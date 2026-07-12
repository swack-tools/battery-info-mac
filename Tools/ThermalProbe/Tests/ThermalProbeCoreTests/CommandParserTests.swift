import Foundation
import XCTest
@testable import ThermalProbeCore

final class CommandParserTests: XCTestCase {
    func testPMSetNominalOutputDoesNotInventTemperature() {
        let result = PMSetParser.parse(
            """
            Note: No thermal warning level has been recorded
            Note: No performance warning level has been recorded
            Note: No CPU power status has been recorded
            """,
            timestamp: .distantPast
        )

        XCTAssertEqual(
            result.first { $0.kind == .thermalPressure }?.value,
            .text("nominal")
        )
        XCTAssertFalse(result.contains { $0.kind == .temperature })
    }

    func testPMSetExtractsWarningAndPowerStatus() {
        let result = PMSetParser.parse(
            """
            Thermal Warning Level: 2
            Performance Warning Level: 1
            CPU Power Status: 75
            """,
            timestamp: .distantPast
        )

        XCTAssertEqual(result.first { $0.identifier == "thermalWarningLevel" }?.number, 2)
        XCTAssertEqual(result.first { $0.identifier == "performanceWarningLevel" }?.number, 1)
        XCTAssertEqual(result.first { $0.identifier == "cpuPowerStatus" }?.number, 75)
    }

    func testPowermetricsTextExtractsContextFields() throws {
        let readings = PowermetricsParser.parseText(
            """
            CPU Power: 1234 mW
            GPU Power: 456 mW
            ANE Power: 78 mW
            Thermal pressure: moderate
            SFI Class 2: 37% forced idle
            CPU Power limit: 68%
            """,
            timestamp: .distantPast
        )

        XCTAssertEqual(
            try XCTUnwrap(readings.first { $0.identifier == "CPU Power" }?.number),
            1.234,
            accuracy: 0.001
        )
        XCTAssertEqual(readings.first { $0.identifier == "Thermal pressure" }?.value, .text("moderate"))
        XCTAssertEqual(readings.first { $0.kind == .forcedIdle }?.number, 37)
        XCTAssertEqual(readings.first { $0.kind == .powerLimit }?.number, 68)
    }

    func testPowermetricsFindsSupportedSamplersWithoutTreatingGroupsAsSamplers() {
        let samplers = PowermetricsParser.supportedSamplers(
            fromHelp: """
            The following samplers are supported by --samplers:
                battery           battery info
                cpu_power         cpu power info
                thermal           thermal pressure notifications
                sfi               forced idle

            and the following sampler groups are supported by --samplers:
                all               battery,cpu_power,thermal,sfi
            """
        )

        XCTAssertEqual(samplers, ["battery", "cpu_power", "thermal", "sfi"])
    }

    func testPowermetricsParsesNULSeparatedPlists() throws {
        let first = try PropertyListSerialization.data(
            fromPropertyList: [
                "thermal_pressure": "fair",
                "cpu_power_mw": 1250,
                "die_temperature_c": 66.5
            ],
            format: .xml,
            options: 0
        )
        let second = try PropertyListSerialization.data(
            fromPropertyList: ["cpu_power_limit_percent": 75],
            format: .xml,
            options: 0
        )
        var input = first
        input.append(0)
        input.append(second)
        input.append(0)

        let readings = PowermetricsParser.parsePlist(input, timestamp: .distantPast)

        XCTAssertEqual(
            try XCTUnwrap(readings.first { $0.identifier == "cpu_power_mw" }?.number),
            1.25,
            accuracy: 0.001
        )
        XCTAssertEqual(readings.first { $0.identifier == "thermal_pressure" }?.value, .text("fair"))
        XCTAssertEqual(readings.first { $0.identifier == "die_temperature_c" }?.kind, .temperature)
        XCTAssertEqual(readings.first { $0.identifier == "cpu_power_limit_percent" }?.kind, .powerLimit)
    }
}
