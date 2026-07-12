import XCTest
@testable import ThermalProbeCore

final class CollectorFactoryTests: XCTestCase {
    func testDefaultFactoryIncludesEveryConfiguredSourceInDeterministicOrder() {
        let collectors = DefaultCollectorFactory.make(commandRunner: NeverRunCommandRunner())

        XCTAssertEqual(
            collectors.map(\.source),
            [
                "smc",
                "iohid",
                "appleSmartBattery",
                "processInfo",
                "ioreport",
                "powermetrics",
                "pmset",
                "ioRegistry",
                "sysctl",
                "systemProfiler"
            ]
        )
    }
}

private struct NeverRunCommandRunner: CommandRunning {
    func run(executable _: String, arguments _: [String], timeout _: TimeInterval) throws -> CommandResult {
        XCTFail("factory construction must not execute commands")
        throw FactoryFixtureError.executed
    }
}

private enum FactoryFixtureError: Error {
    case executed
}
