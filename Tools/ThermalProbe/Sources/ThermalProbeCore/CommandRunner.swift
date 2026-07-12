import CThermalProbeShim
import Darwin
import Foundation

public struct CommandResult {
    public var executable: String
    public var arguments: [String]
    public var terminationStatus: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var truncated: Bool
    public var startedAt: Date
    public var durationMilliseconds: Double

    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

public protocol CommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public final class ActiveProcessRegistry {
    public static let shared = ActiveProcessRegistry()

    private let lock = NSLock()
    private var processGroups: Set<Int32> = []

    public init() {}

    func spawnAndRegister<T>(
        _ spawn: () throws -> (processGroupID: Int32, value: T)
    ) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let spawned = try spawn()
        processGroups.insert(spawned.processGroupID)
        return spawned.value
    }

    func reapAndUnregister<T>(
        processGroupID: Int32,
        _ reap: () throws -> T
    ) rethrows -> T {
        lock.lock()
        defer {
            processGroups.remove(processGroupID)
            lock.unlock()
        }
        return try reap()
    }

    public func terminateAll() {
        lock.lock()
        defer { lock.unlock() }
        for processGroupID in processGroups where processGroupID > 0 {
            Darwin.kill(-processGroupID, SIGTERM)
            Darwin.kill(-processGroupID, SIGKILL)
        }
    }
}

public final class ProcessCommandRunner: CommandRunning {
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024

    private let maximumBytes: Int
    private let registry: ActiveProcessRegistry

    public init(
        maximumBytes: Int = ProcessCommandRunner.defaultMaximumBytes,
        registry: ActiveProcessRegistry = .shared
    ) {
        self.maximumBytes = max(0, maximumBytes)
        self.registry = registry
    }

    public func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        let accumulator = BoundedOutputAccumulator(maximumBytes: maximumBytes)
        let drainControl = DrainControl()
        let readers = DispatchGroup()
        let startedAt = Date()
        let monotonicStart = ProcessInfo.processInfo.systemUptime
        let process = try registry.spawnAndRegister {
            let process = try spawn(executable: executable, arguments: arguments)
            return (processGroupID: process.process_id, value: process)
        }
        let processGroupID = process.process_id

        drain(
            process.stdout_fd,
            stream: .stdout,
            into: accumulator,
            control: drainControl,
            group: readers
        )
        drain(
            process.stderr_fd,
            stream: .stderr,
            into: accumulator,
            control: drainControl,
            group: readers
        )

        var timedOut = false
        var waitStatus: Int32 = 0
        var waitError: Int32?
        let deadline = monotonicStart + max(0, timeout)
        switch waitUntilExit(processID: processGroupID, deadline: deadline) {
        case .exited:
            Darwin.kill(-processGroupID, SIGTERM)
            Darwin.kill(-processGroupID, SIGKILL)
        case .deadlineReached:
            timedOut = true
            Darwin.kill(-processGroupID, SIGTERM)
            switch waitUntilExit(
                processID: processGroupID,
                deadline: ProcessInfo.processInfo.systemUptime + 0.5
            ) {
            case .exited:
                break
            case .deadlineReached:
                Darwin.kill(-processGroupID, SIGKILL)
            case let .failed(code):
                waitError = code
            }
            Darwin.kill(-processGroupID, SIGKILL)
        case let .failed(code):
            waitError = code
            Darwin.kill(-processGroupID, SIGKILL)
        }

        let reapOutcome = registry.reapAndUnregister(processGroupID: processGroupID) {
            waitForExit(processID: processGroupID)
        }
        switch reapOutcome {
        case let .reaped(status): waitStatus = status
        case let .failed(code): waitError = waitError ?? code
        }
        drainControl.stop()
        readers.wait()

        if let waitError {
            throw posixError(waitError, operation: "waitpid")
        }

        let captured = accumulator.snapshot()
        return CommandResult(
            executable: executable,
            arguments: arguments,
            terminationStatus: tp_wait_status_exit_code(waitStatus),
            stdout: captured.stdout,
            stderr: captured.stderr,
            timedOut: timedOut,
            truncated: captured.truncated,
            startedAt: startedAt,
            durationMilliseconds: max(
                0,
                (ProcessInfo.processInfo.systemUptime - monotonicStart) * 1_000
            )
        )
    }

    private enum ExitObservation {
        case exited
        case deadlineReached
        case failed(Int32)
    }

    private enum ReapOutcome {
        case reaped(Int32)
        case failed(Int32)
    }

    private func spawn(executable: String, arguments: [String]) throws -> TPSpawnedProcess {
        let command = [executable] + arguments
        var allocatedArguments: [UnsafeMutablePointer<CChar>?] = command.map { value in
            value.withCString { pointer in strdup(pointer) }
        }
        guard allocatedArguments.allSatisfy({ $0 != nil }) else {
            allocatedArguments.forEach { pointer in
                if let pointer { free(pointer) }
            }
            throw posixError(ENOMEM, operation: "strdup")
        }
        defer {
            allocatedArguments.forEach { pointer in
                if let pointer { free(pointer) }
            }
        }
        allocatedArguments.append(nil)

        var process = TPSpawnedProcess()
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = executable.withCString { executablePointer in
            allocatedArguments.withUnsafeMutableBufferPointer { argumentBuffer in
                errorBuffer.withUnsafeMutableBufferPointer { errorPointer in
                    tp_spawn_process_group(
                        executablePointer,
                        argumentBuffer.baseAddress,
                        &process,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
        }
        guard status == 0 else {
            let message = errorBuffer.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map(String.init(cString:)) ?? "process spawn failed"
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return process
    }

    private func waitUntilExit(processID: Int32, deadline: TimeInterval) -> ExitObservation {
        while true {
            switch pollExit(processID: processID) {
            case .deadlineReached:
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    return .deadlineReached
                }
                usleep(5_000)
            case let outcome:
                return outcome
            }
        }
    }

    private func pollExit(processID: Int32) -> ExitObservation {
        var hasExited: Int32 = 0
        let status = tp_process_has_exited(processID, &hasExited)
        if status != 0 { return .failed(status) }
        return hasExited == 0 ? .deadlineReached : .exited
    }

    private func waitForExit(processID: Int32) -> ReapOutcome {
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(processID, &status, 0)
            if result == processID { return .reaped(status) }
            if result < 0, errno == EINTR { continue }
            return .failed(errno)
        }
    }

    private func posixError(_ code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }

    private func drain(
        _ descriptor: Int32,
        stream: BoundedOutputAccumulator.Stream,
        into accumulator: BoundedOutputAccumulator,
        control: DrainControl,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                Darwin.close(descriptor)
                group.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    accumulator.append(Data(buffer.prefix(Int(count))), stream: stream)
                } else if count == 0 {
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    if control.isStopped { return }
                    usleep(1_000)
                } else {
                    return
                }
            }
        }
    }
}

private final class DrainControl {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class BoundedOutputAccumulator {
    enum Stream {
        case stdout
        case stderr
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data, stream: Stream) {
        lock.lock()
        defer { lock.unlock() }

        let used = stdout.count + stderr.count
        let remaining = max(0, maximumBytes - used)
        if data.count > remaining {
            truncated = true
        }
        guard remaining > 0 else { return }

        let captured = data.prefix(remaining)
        switch stream {
        case .stdout:
            stdout.append(captured)
        case .stderr:
            stderr.append(captured)
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr, truncated)
    }
}
