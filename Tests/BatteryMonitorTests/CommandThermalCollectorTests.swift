import Foundation
import XCTest
@testable import BatteryMonitorThermal

final class CommandThermalCollectorTests: XCTestCase {
    func testProcessRunnerReportsSuccessNonzeroAndSeparatedStreams() throws {
        let runner = ProcessCommandRunner(maximumBytes: 1_024)
        let success = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf stdout-value; printf stderr-value >&2"],
            timeout: 2
        )
        XCTAssertEqual(success.terminationStatus, 0)
        XCTAssertEqual(success.stdoutString, "stdout-value")
        XCTAssertEqual(success.stderrString, "stderr-value")
        XCTAssertFalse(success.timedOut)
        XCTAssertFalse(success.truncated)

        let nonzero = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf failed >&2; exit 7"],
            timeout: 2
        )
        XCTAssertEqual(nonzero.terminationStatus, 7)
        XCTAssertEqual(nonzero.stderrString, "failed")
        XCTAssertFalse(nonzero.timedOut)
    }

    func testProcessRunnerTimesOutAndBoundsCombinedOutput() throws {
        let timeout = try ProcessCommandRunner(maximumBytes: 1_024).run(
            executable: "/bin/sleep",
            arguments: ["2"],
            timeout: 0.05
        )
        XCTAssertTrue(timeout.timedOut)
        XCTAssertNotEqual(timeout.terminationStatus, 0)

        let truncated = try ProcessCommandRunner(maximumBytes: 8).run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 1234567890; printf abcdef >&2"],
            timeout: 2
        )
        XCTAssertTrue(truncated.truncated)
        XCTAssertEqual(truncated.stdout.count + truncated.stderr.count, 8)
    }

    func testProcessRunnerTimeoutIncludesDescendantPipeDrain() throws {
        let started = ProcessInfo.processInfo.systemUptime

        let result = try ProcessCommandRunner(maximumBytes: 1_024).run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 3 & exit 0"],
            timeout: 0.1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    }

    func testPowermetricsSamplerDiscoveryIsSectionBoundedAndIncludesSMCOnlyWhenListed() {
        let help = """
        Usage mentions cpu_power outside the list.
        The following samplers are supported by --samplers:
            battery       battery information
            cpu_power     processor power
            thermal       pressure
            smc           sensors
        and the following sampler groups are supported by --samplers:
            all           everything
            gpu_power     not an individual sampler here
        """

        XCTAssertEqual(
            PowermetricsOutputParser.supportedSamplers(fromHelp: help),
            ["battery", "cpu_power", "thermal", "smc"]
        )
    }

    func testPowermetricsUsesAvailableSamplersAndParsesPlistTelemetry() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "thermal_pressure": "serious",
                "cpu_power_mw": 900,
                "gpu_power_w": 1.25,
                "cpu_temperature": 73.5,
                "cpu_power_limit": 62
            ],
            format: .xml,
            options: 0
        ) + Data([0])
        let runner = FixtureCommandRunner(results: [
            .fixture(stdout: """
            The following samplers are supported by --samplers:
                thermal pressure
                cpu_power power
                gpu_power power
                battery battery
                sfi forced-idle
            and the following sampler groups are supported by --samplers:
            """),
            .fixture(stdoutData: plist)
        ])

        let result = PowermetricsThermalCollector(runner: runner).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .success)
        XCTAssertEqual(result.readings.first { $0.identifier == "cpu_temperature" }?.numericValue, 73.5)
        XCTAssertEqual(result.componentPowers.first { $0.name == "CPU" }?.watts, 0.9)
        XCTAssertEqual(result.componentPowers.first { $0.name == "GPU" }?.watts, 1.25)
        XCTAssertEqual(result.thermalPressure, "Serious")
        XCTAssertEqual(result.throttling?.percentage, 62)
        XCTAssertEqual(runner.calls.map(\.timeout), [5, 15])
        let sampleArguments = runner.calls[1].arguments
        XCTAssertTrue(sampleArguments.contains("thermal,cpu_power,gpu_power,battery,sfi"))
        XCTAssertFalse(sampleArguments.contains { $0 == "smc" || $0.contains(",smc") })
        XCTAssertTrue(sampleArguments.contains("--show-plimits"))
        XCTAssertTrue(sampleArguments.contains("--handle-invalid-values"))
        XCTAssertTrue(sampleArguments.contains("plist"))
    }

    func testPowermetricsRejectsNonfinitePlistLimitsWithoutTrapping() {
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>cpu_temperature</key><real>70</real>
          <key>cpu_power_limit</key><real>nan</real>
          <key>gpu_forced_idle</key><real>+infinity</real>
        </dict></plist>
        """.utf8) + Data([0])
        let runner = FixtureCommandRunner(results: [
            .fixture(stdout: """
            The following samplers are supported by --samplers:
                thermal pressure
                cpu_power power
                sfi forced-idle
            and the following sampler groups are supported by --samplers:
            """),
            .fixture(stdoutData: plist)
        ])

        let result = PowermetricsThermalCollector(runner: runner).collect(at: .distantPast)

        XCTAssertEqual(result.readings.first { $0.identifier == "cpu_temperature" }?.numericValue, 70)
        XCTAssertEqual(result.status.state, .partial)
        XCTAssertTrue(result.status.warnings.contains { $0.contains("nonfinite") })
        XCTAssertEqual(result.throttling?.percentage, 0)
    }

    func testPowermetricsFallsBackToTextAndPreservesUsefulPartialNonzeroData() {
        let runner = FixtureCommandRunner(results: [
            .fixture(stdout: """
            The following samplers are supported by --samplers:
                thermal pressure
                cpu_power power
            and the following sampler groups are supported by --samplers:
            """),
            .fixture(stdout: "not a plist"),
            .fixture(
                stdout: "CPU Power: 1000 mW\nCPU temperature 67 C\nThermal pressure: fair\nCPU Power limit: 30%\n",
                stderr: "partial sample",
                status: 2
            )
        ])

        let result = PowermetricsThermalCollector(runner: runner).collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.readings.first?.numericValue, 67)
        XCTAssertEqual(result.componentPowers.first?.watts, 1)
        XCTAssertEqual(result.thermalPressure, "Fair")
        XCTAssertEqual(result.throttling?.percentage, 30)
        XCTAssertTrue(result.status.warnings.contains { $0.contains("text fallback") })
        XCTAssertTrue(result.status.warnings.contains { $0.contains("status 2") })
        XCTAssertTrue(runner.calls[2].arguments.contains("text"))
    }

    func testPowermetricsTimeoutAndEmptyNonzeroAreFailedTruthfully() {
        let timedOut = PowermetricsThermalCollector(runner: FixtureCommandRunner(results: [
            .fixture(status: 15, timedOut: true)
        ])).collect(at: .distantPast)
        XCTAssertEqual(timedOut.status.state, .failed)
        XCTAssertTrue(timedOut.status.error?.contains("timed out") == true)

        let failed = PowermetricsThermalCollector(runner: FixtureCommandRunner(results: [
            .fixture(stdout: """
            The following samplers are supported by --samplers:
                thermal pressure
            and the following sampler groups are supported by --samplers:
            """),
            .fixture(stderr: "permission denied", status: 1),
            .fixture(stderr: "permission denied", status: 1)
        ])).collect(at: .distantPast)
        XCTAssertEqual(failed.status.state, .failed)
        XCTAssertTrue(failed.status.error?.contains("permission denied") == true)
    }

    func testPMSetEmitsPressureAndThrottlingWithTimeoutAndFailureTruth() {
        let success = PMSetThermalCollector(runner: FixtureCommandRunner(results: [
            .fixture(stdout: "CPU Power Status: 55\nThermal Warning Level: 1\n")
        ])).collect(at: .distantPast)
        XCTAssertEqual(success.status.state, .success)
        XCTAssertEqual(success.readings.first?.kind, .thermalPressure)
        XCTAssertEqual(success.throttling?.percentage, 55)
        XCTAssertEqual(success.thermalPressure, success.throttling?.level)

        let timeout = PMSetThermalCollector(runner: FixtureCommandRunner(results: [
            .fixture(stderr: "late", status: 15, timedOut: true)
        ])).collect(at: .distantPast)
        XCTAssertEqual(timeout.status.state, .failed)
        XCTAssertTrue(timeout.status.error?.contains("timed out") == true)

        let failure = PMSetThermalCollector(runner: FixtureCommandRunner(results: [
            .fixture(stderr: "not permitted", status: 1)
        ])).collect(at: .distantPast)
        XCTAssertEqual(failure.status.state, .failed)
        XCTAssertTrue(failure.status.error?.contains("not permitted") == true)
    }
}

private final class FixtureCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        var executable: String
        var arguments: [String]
        var timeout: TimeInterval
    }

    private var results: [CommandResult]
    private(set) var calls: [Call] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        return results.removeFirst()
    }
}

private extension CommandResult {
    static func fixture(
        stdout: String = "",
        stdoutData: Data? = nil,
        stderr: String = "",
        status: Int32 = 0,
        timedOut: Bool = false,
        truncated: Bool = false
    ) -> CommandResult {
        CommandResult(
            executable: "/fixture",
            arguments: [],
            terminationStatus: status,
            stdout: stdoutData ?? Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            timedOut: timedOut,
            truncated: truncated,
            durationMilliseconds: 1
        )
    }
}
