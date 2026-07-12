import Foundation
import XCTest
@testable import ThermalProbeCore

final class CommandCollectorTests: XCTestCase {
    private let context = CollectionContext(clock: CommandFixedClock(), includeRaw: true)

    func testPowermetricsIntersectsSamplersAndReportsMissingSMCSampler() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["thermal_pressure": "nominal", "cpu_power_mw": 900],
            format: .xml,
            options: 0
        ) + Data([0])
        let runner = FixtureCommandRunner(results: [
            .fixture(stdout: """
            The following samplers are supported by --samplers:
                battery           battery info
                cpu_power         cpu power info
                thermal           pressure
                sfi               forced idle
            and the following sampler groups are supported by --samplers:
                all               battery,cpu_power,thermal,sfi
            """),
            .fixture(stdoutData: plist)
        ])

        let result = PowermetricsCollector(runner: runner).collect(context: context)

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.capabilities["smcSamplerAvailable"], .bool(false))
        XCTAssertTrue(result.warnings.contains { $0.contains("smc sampler") })
        XCTAssertEqual(result.readings.first { $0.identifier == "cpu_power_mw" }?.number, 0.9)
        let sampleArguments = try XCTUnwrap(runner.calls.last?.arguments)
        XCTAssertTrue(sampleArguments.contains("thermal,cpu_power,battery,sfi"))
        XCTAssertFalse(sampleArguments.contains { $0 == "smc" || $0.contains(",smc") })
        XCTAssertTrue(sampleArguments.contains("plist"))
    }

    func testPowermetricsFallsBackToTextWhenPlistHasNoReadableRecord() {
        let runner = FixtureCommandRunner(results: [
            .fixture(stdout: """
            The following samplers are supported by --samplers:
                cpu_power         cpu power info
                thermal           pressure
            and the following sampler groups are supported by --samplers:
            """),
            .fixture(stdout: "not a plist"),
            .fixture(stdout: "CPU Power: 1000 mW\nThermal pressure: fair\n")
        ])

        let result = PowermetricsCollector(runner: runner).collect(context: context)

        XCTAssertEqual(result.readings.first { $0.identifier == "CPU Power" }?.number, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("text fallback") })
        XCTAssertEqual(runner.calls.count, 3)
        XCTAssertTrue(runner.calls[2].arguments.contains("text"))
    }

    func testPMSetTimeoutIsSourceTimeout() {
        let runner = FixtureCommandRunner(results: [.fixture(timedOut: true)])

        let result = PMSetCollector(runner: runner).collect(context: context)

        XCTAssertEqual(result.status, .timedOut)
        XCTAssertEqual(result.error?.code, "timeout")
    }

    func testCapabilityProbeCanSucceedWithNoThermalFields() {
        let runner = FixtureCommandRunner(results: [.fixture(stdout: "hw.model: Mac16,12\n")])
        let collector = CapabilityProbeCollector(
            source: "sysctl",
            executable: "/usr/sbin/sysctl",
            arguments: ["-a"],
            format: .keyValue,
            runner: runner
        )

        let result = collector.collect(context: context)

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(result.capabilities["relevantFieldCount"], .number(0))
    }
}

private final class CommandFixedClock: ProbeClock {
    var wallNow: Date { Date(timeIntervalSince1970: 100) }
    var monotonicNow: TimeInterval { 10 }
    func sleep(milliseconds _: Int) {}
}

private final class FixtureCommandRunner: CommandRunning {
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
            startedAt: .distantPast,
            durationMilliseconds: 1
        )
    }
}
