import CThermalProbeShim
import Darwin
import Foundation
import XCTest
@testable import ThermalProbeCore

final class CommandRunnerTests: XCTestCase {
    func testRegistryMakesSpawnAndRegistrationAtomic() {
        let registry = ActiveProcessRegistry()
        let spawnEntered = DispatchSemaphore(value: 0)
        let allowRegistration = DispatchSemaphore(value: 0)
        let spawnCompleted = DispatchSemaphore(value: 0)
        let terminationCompleted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let value: Int = registry.spawnAndRegister {
                spawnEntered.signal()
                allowRegistration.wait()
                return (processGroupID: Int32.max, value: 42)
            }
            XCTAssertEqual(value, 42)
            spawnCompleted.signal()
        }
        XCTAssertEqual(spawnEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            registry.terminateAll()
            terminationCompleted.signal()
        }
        XCTAssertEqual(terminationCompleted.wait(timeout: .now() + 0.05), .timedOut)

        allowRegistration.signal()
        XCTAssertEqual(spawnCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(terminationCompleted.wait(timeout: .now() + 1), .success)
        registry.reapAndUnregister(processGroupID: Int32.max) {}
    }

    func testRegistryMakesReapAndUnregisterAtomicWithTermination() {
        let registry = ActiveProcessRegistry()
        let _: Int = registry.spawnAndRegister {
            (processGroupID: Int32.max, value: 42)
        }
        let reapEntered = DispatchSemaphore(value: 0)
        let allowReap = DispatchSemaphore(value: 0)
        let reapCompleted = DispatchSemaphore(value: 0)
        let terminationCompleted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let value: Int = registry.reapAndUnregister(processGroupID: Int32.max) {
                reapEntered.signal()
                allowReap.wait()
                return 7
            }
            XCTAssertEqual(value, 7)
            reapCompleted.signal()
        }
        XCTAssertEqual(reapEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            registry.terminateAll()
            terminationCompleted.signal()
        }
        XCTAssertEqual(terminationCompleted.wait(timeout: .now() + 0.05), .timedOut)

        allowReap.signal()
        XCTAssertEqual(reapCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(terminationCompleted.wait(timeout: .now() + 1), .success)
    }


    func testExitObservationLeavesProcessGroupLeaderWaitable() {
        let executable = strdup("/usr/bin/true")
        XCTAssertNotNil(executable)
        guard let executable else { return }
        defer { free(executable) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
        var process = TPSpawnedProcess()
        var error = [CChar](repeating: 0, count: 256)
        let spawnStatus = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            error.withUnsafeMutableBufferPointer { errorBuffer in
                tp_spawn_process_group(
                    executable,
                    argumentBuffer.baseAddress,
                    &process,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }
        XCTAssertEqual(spawnStatus, 0)
        guard spawnStatus == 0 else { return }
        close(process.stdout_fd)
        close(process.stderr_fd)
        let child = process.process_id
        var reaped = false
        defer {
            if !reaped {
                kill(child, SIGKILL)
                var cleanupStatus: Int32 = 0
                waitpid(child, &cleanupStatus, 0)
            }
        }

        var hasExited: Int32 = 0
        var observationStatus: Int32 = 0
        for _ in 0..<100 {
            observationStatus = tp_process_has_exited(child, &hasExited)
            if observationStatus != 0 || hasExited != 0 { break }
            usleep(1_000)
        }

        XCTAssertEqual(observationStatus, 0)
        XCTAssertEqual(hasExited, 1)
        var waitStatus: Int32 = 0
        XCTAssertEqual(waitpid(child, &waitStatus, WNOHANG), child)
        reaped = true
    }

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

    func testRunnerCapturesStreamsWhenParentStandardDescriptorsAreClosed() throws {
        let savedOutput = dup(STDOUT_FILENO)
        let savedError = dup(STDERR_FILENO)
        XCTAssertGreaterThan(savedOutput, STDERR_FILENO)
        XCTAssertGreaterThan(savedError, STDERR_FILENO)
        guard savedOutput > STDERR_FILENO, savedError > STDERR_FILENO else { return }

        close(STDOUT_FILENO)
        close(STDERR_FILENO)
        let outcome = Result {
            try ProcessCommandRunner(maximumBytes: 1024).run(
                executable: "/bin/sh",
                arguments: ["-c", "printf out; printf err >&2"],
                timeout: 2
            )
        }
        dup2(savedOutput, STDOUT_FILENO)
        dup2(savedError, STDERR_FILENO)
        close(savedOutput)
        close(savedError)

        let result = try outcome.get()
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdoutString, "out")
        XCTAssertEqual(result.stderrString, "err")
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

    func testSpawnedCommandRestoresDefaultTerminationSignal() throws {
        let previousHandler = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previousHandler) }
        let started = Date()

        let result = try ProcessCommandRunner(maximumBytes: 1024).run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
    }

    func testRunnerTimeoutTerminatesDescendantsHoldingOutputPipes() throws {
        let started = Date()
        let result = try ProcessCommandRunner(maximumBytes: 1024).run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "(trap '' TERM HUP; sleep 5) & child=$!; printf '%s\\n' \"$child\"; wait"
            ],
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        let child = try XCTUnwrap(Int32(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<50 {
            if kill(child, 0) == -1, errno == ESRCH { return }
            usleep(10_000)
        }
        XCTFail("descendant process \(child) survived timeout cleanup")
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
