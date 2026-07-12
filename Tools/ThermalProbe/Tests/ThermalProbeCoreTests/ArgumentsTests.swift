import XCTest
@testable import ThermalProbeCore

final class ArgumentsTests: XCTestCase {
    func testParsesStreamingRepeatedRawCapture() throws {
        XCTAssertEqual(
            try ProbeOptions.parse(["--jsonl", "--samples", "3", "--interval", "250", "--raw"]),
            ProbeOptions(
                format: .jsonLines,
                samples: 3,
                intervalMilliseconds: 250,
                raw: true,
                help: false
            )
        )
    }

    func testRejectsMutuallyExclusiveJSONModes() {
        XCTAssertThrowsError(try ProbeOptions.parse(["--json", "--jsonl"])) { error in
            XCTAssertEqual(error as? ProbeArgumentError, .mutuallyExclusiveFormats)
        }
    }

    func testRejectsMissingAndNonPositiveNumericValues() {
        XCTAssertThrowsError(try ProbeOptions.parse(["--samples"]))
        XCTAssertThrowsError(try ProbeOptions.parse(["--samples", "0"]))
        XCTAssertThrowsError(try ProbeOptions.parse(["--interval", "-1"]))
    }

    func testRejectsUnknownOption() {
        XCTAssertThrowsError(try ProbeOptions.parse(["--unknown"])) { error in
            XCTAssertEqual(error as? ProbeArgumentError, .unknownOption("--unknown"))
        }
    }

    func testRuntimeDecisionAllowsHelpWithoutRoot() {
        var options = ProbeOptions.default
        options.help = true

        XCTAssertEqual(RuntimeDecision.evaluate(options: options, effectiveUserID: 501), .showHelp)
    }

    func testRuntimeDecisionRequiresRootBeforeCollection() {
        XCTAssertEqual(RuntimeDecision.evaluate(options: .default, effectiveUserID: 501), .exit(77))
        XCTAssertEqual(RuntimeDecision.evaluate(options: .default, effectiveUserID: 0), .collect)
    }
}
