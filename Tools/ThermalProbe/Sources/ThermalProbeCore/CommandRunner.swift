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
    private var processes: [Int32: Process] = [:]

    public init() {}

    public func register(_ process: Process) {
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }

    public func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: process.processIdentifier)
        lock.unlock()
    }

    public func terminateAll() {
        lock.lock()
        let active = Array(processes.values)
        lock.unlock()

        for process in active where process.isRunning {
            process.terminate()
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
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let accumulator = BoundedOutputAccumulator(maximumBytes: maximumBytes)
        let readers = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)
        let startedAt = Date()
        let monotonicStart = ProcessInfo.processInfo.systemUptime

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        registry.register(process)

        drain(stdoutPipe.fileHandleForReading, stream: .stdout, into: accumulator, group: readers)
        drain(stderrPipe.fileHandleForReading, stream: .stderr, into: accumulator, group: readers)

        var timedOut = false
        if terminated.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if terminated.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        registry.unregister(process)
        readers.wait()

        let captured = accumulator.snapshot()
        return CommandResult(
            executable: executable,
            arguments: arguments,
            terminationStatus: process.terminationStatus,
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

    private func drain(
        _ handle: FileHandle,
        stream: BoundedOutputAccumulator.Stream,
        into accumulator: BoundedOutputAccumulator,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                accumulator.append(data, stream: stream)
            }
        }
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
