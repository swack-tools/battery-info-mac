import Foundation
import XCTest
@testable import ThermalProbeCore

final class CommandRunnerTests: XCTestCase {
    func testRunnerCapturesBothStreamsAndExitStatus() throws {
        let result = try ProcessCommandRunner(maximumBytes: 1024).run(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"],
            timeout: 2
        )

        XCTAssertEqual(result.stdoutString, "out")
        XCTAssertEqual(result.stderrString, "err")
        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.truncated)
    }

    func testRunnerTimesOutAndReturnsPromptly() throws {
        let started = Date()
        let result = try ProcessCommandRunner(maximumBytes: 1024).run(
            executable: "/bin/sleep",
            arguments: ["2"],
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testRunnerBoundsNoisyOutputWhileContinuingToDrain() throws {
        let result = try ProcessCommandRunner(maximumBytes: 128).run(
            executable: "/usr/bin/yes",
            arguments: ["thermal"],
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.stdout.count + result.stderr.count, 128)
    }
}
