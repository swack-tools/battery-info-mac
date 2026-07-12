import BatteryMonitorShared
import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var terminationStatus: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var truncated: Bool
    public var durationMilliseconds: Double

    public init(
        executable: String,
        arguments: [String],
        terminationStatus: Int32,
        stdout: Data,
        stderr: Data,
        timedOut: Bool,
        truncated: Bool,
        durationMilliseconds: Double
    ) {
        self.executable = executable
        self.arguments = arguments
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
        self.durationMilliseconds = durationMilliseconds
    }

    public var stdoutString: String { String(bytes: stdout, encoding: .utf8) ?? "" }
    public var stderrString: String { String(bytes: stderr, encoding: .utf8) ?? "" }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024

    private let maximumBytes: Int

    public init(maximumBytes: Int = ProcessCommandRunner.defaultMaximumBytes) {
        self.maximumBytes = max(0, maximumBytes)
    }

    public func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let output = BoundedCommandOutput(maximumBytes: maximumBytes)
        let deadline = DispatchTime.now() + max(0, timeout)
        let spawned = try spawn(executable: executable, arguments: arguments)
        let stdoutHandle = FileHandle(fileDescriptor: spawned.stdoutDescriptor, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: spawned.stderrDescriptor, closeOnDealloc: true)
        let stdoutDrain = CommandPipeDrain(
            handle: stdoutHandle,
            stream: .stdout,
            output: output
        )
        let stderrDrain = CommandPipeDrain(
            handle: stderrHandle,
            stream: .stderr,
            output: output
        )
        var waitStatus: Int32 = 0
        var childReaped = false
        defer {
            stdoutDrain.stop()
            stderrDrain.stop()
            if !childReaped {
                _ = Darwin.kill(-spawned.processID, SIGKILL)
                reap(processID: spawned.processID, status: &waitStatus)
            }
        }

        childReaped = try waitForExit(
            processID: spawned.processID,
            status: &waitStatus,
            deadline: deadline
        )
        var timedOut = false
        if !childReaped
            || !stdoutDrain.wait(until: deadline)
            || !stderrDrain.wait(until: deadline) {
            timedOut = true
            _ = Darwin.kill(-spawned.processID, SIGTERM)
            usleep(20_000)
            _ = Darwin.kill(-spawned.processID, SIGKILL)
            stdoutDrain.stop()
            stderrDrain.stop()
            if !childReaped {
                reap(processID: spawned.processID, status: &waitStatus)
                childReaped = true
            }
            waitForProcessGroupExit(processGroupID: spawned.processID)
        }

        let captured = output.snapshot()
        return CommandResult(
            executable: executable,
            arguments: arguments,
            terminationStatus: exitCode(fromWaitStatus: waitStatus),
            stdout: captured.stdout,
            stderr: captured.stderr,
            timedOut: timedOut,
            truncated: captured.truncated,
            durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )
    }

    private func spawn(executable: String, arguments: [String]) throws -> SpawnedCommand {
        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        var stderrDescriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&stdoutDescriptors) == 0 else {
            throw posixError(errno, operation: "pipe stdout")
        }
        guard Darwin.pipe(&stderrDescriptors) == 0 else {
            closeDescriptors(stdoutDescriptors)
            throw posixError(errno, operation: "pipe stderr")
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var processID: pid_t = 0
        do {
            try check(posix_spawn_file_actions_init(&fileActions), operation: "posix_spawn_file_actions_init")
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            try check(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
            defer { posix_spawnattr_destroy(&attributes) }

            try check(
                posix_spawn_file_actions_adddup2(&fileActions, stdoutDescriptors[1], STDOUT_FILENO),
                operation: "posix_spawn stdout dup2"
            )
            try check(
                posix_spawn_file_actions_adddup2(&fileActions, stderrDescriptors[1], STDERR_FILENO),
                operation: "posix_spawn stderr dup2"
            )
            for descriptor in stdoutDescriptors + stderrDescriptors {
                try check(
                    posix_spawn_file_actions_addclose(&fileActions, descriptor),
                    operation: "posix_spawn close"
                )
            }

            var defaultSignals = sigset_t()
            sigemptyset(&defaultSignals)
            for signal in 1..<NSIG where signal != SIGKILL && signal != SIGSTOP {
                sigaddset(&defaultSignals, signal)
            }
            var signalMask = sigset_t()
            sigemptyset(&signalMask)
            try check(
                posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
                operation: "posix_spawnattr_setsigdefault"
            )
            try check(
                posix_spawnattr_setsigmask(&attributes, &signalMask),
                operation: "posix_spawnattr_setsigmask"
            )
            try check(
                posix_spawnattr_setpgroup(&attributes, 0),
                operation: "posix_spawnattr_setpgroup"
            )
            let flags = Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            )
            try check(
                posix_spawnattr_setflags(&attributes, flags),
                operation: "posix_spawnattr_setflags"
            )

            var argumentPointers = ([executable] + arguments).map { strdup($0) }
            guard argumentPointers.allSatisfy({ $0 != nil }) else {
                argumentPointers.forEach { free($0) }
                throw posixError(ENOMEM, operation: "strdup")
            }
            argumentPointers.append(nil)
            defer { argumentPointers.forEach { free($0) } }

            let spawnStatus = executable.withCString { executablePath in
                argumentPointers.withUnsafeMutableBufferPointer { buffer in
                    posix_spawn(
                        &processID,
                        executablePath,
                        &fileActions,
                        &attributes,
                        buffer.baseAddress,
                        environ
                    )
                }
            }
            try check(spawnStatus, operation: "posix_spawn")
        } catch {
            closeDescriptors(stdoutDescriptors + stderrDescriptors)
            throw error
        }

        Darwin.close(stdoutDescriptors[1])
        Darwin.close(stderrDescriptors[1])
        return SpawnedCommand(
            processID: processID,
            stdoutDescriptor: stdoutDescriptors[0],
            stderrDescriptor: stderrDescriptors[0]
        )
    }

    private func waitForExit(
        processID: pid_t,
        status: inout Int32,
        deadline: DispatchTime
    ) throws -> Bool {
        while true {
            let result = Darwin.waitpid(processID, &status, WNOHANG)
            if result == processID { return true }
            if result < 0 {
                if errno == EINTR { continue }
                throw posixError(errno, operation: "waitpid")
            }
            guard DispatchTime.now() < deadline else { return false }
            usleep(1_000)
        }
    }

    private func reap(processID: pid_t, status: inout Int32) {
        while true {
            let result = Darwin.waitpid(processID, &status, 0)
            if result == processID || (result < 0 && errno == ECHILD) { return }
            if result < 0 && errno == EINTR { continue }
            return
        }
    }

    private func waitForProcessGroupExit(processGroupID: pid_t) {
        let deadline = DispatchTime.now() + 0.25
        while Darwin.kill(-processGroupID, 0) == 0 || errno == EPERM {
            guard DispatchTime.now() < deadline else { return }
            usleep(1_000)
        }
    }

    private func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private func check(_ status: Int32, operation: String) throws {
        guard status == 0 else { throw posixError(status, operation: operation) }
    }

    private func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func posixError(_ code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

private struct SpawnedCommand {
    var processID: pid_t
    var stdoutDescriptor: Int32
    var stderrDescriptor: Int32
}

private final class CommandPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var finished = false

    init(
        handle: FileHandle,
        stream: BoundedCommandOutput.Stream,
        output: BoundedCommandOutput
    ) {
        self.handle = handle
        completion.enter()
        handle.readabilityHandler = { [weak self] readable in
            let data = readable.availableData
            if data.isEmpty {
                self?.finish()
            } else {
                output.append(data, stream: stream)
            }
        }
    }

    func wait(until deadline: DispatchTime) -> Bool {
        completion.wait(timeout: deadline) == .success
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
        finish()
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        handle.readabilityHandler = nil
        lock.unlock()
        completion.leave()
    }
}

private final class BoundedCommandOutput: @unchecked Sendable {
    enum Stream { case stdout, stderr }

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
        let remaining = max(0, maximumBytes - stdout.count - stderr.count)
        if data.count > remaining { truncated = true }
        guard remaining > 0 else { return }
        switch stream {
        case .stdout: stdout.append(data.prefix(remaining))
        case .stderr: stderr.append(data.prefix(remaining))
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr, truncated)
    }
}

public struct ParsedCommandTelemetry: Equatable, Sendable {
    public var readings: [DetailedThermalReading]
    public var componentPowers: [ComponentPowerReading]
    public var throttling: ThrottlingStatus?
    public var thermalPressure: String?
    public var warnings: [String]

    public init(
        readings: [DetailedThermalReading] = [],
        componentPowers: [ComponentPowerReading] = [],
        throttling: ThrottlingStatus? = nil,
        thermalPressure: String? = nil,
        warnings: [String] = []
    ) {
        self.readings = readings
        self.componentPowers = componentPowers
        self.throttling = throttling
        self.thermalPressure = thermalPressure
        self.warnings = warnings
    }

    public var hasUsefulTelemetry: Bool {
        !readings.isEmpty || !componentPowers.isEmpty || thermalPressure != nil
            || (throttling?.percentage ?? 0) > 0
    }
}

public enum PowermetricsOutputParser {
    public static func supportedSamplers(fromHelp output: String) -> [String] {
        var inSection = false
        var samplers: [String] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let lower = rawLine.lowercased()
            if lower.contains("samplers are supported by --samplers")
                && !lower.contains("sampler groups") {
                inSection = true
                continue
            }
            if lower.contains("sampler groups are supported by --samplers") { break }
            guard inSection else { continue }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = trimmed.split(whereSeparator: \Character.isWhitespace).first.map(String.init),
                  name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
                continue
            }
            samplers.append(name)
        }
        return samplers
    }

    public static func parsePlist(_ data: Data) -> ParsedCommandTelemetry {
        var aggregate = ParsedCommandTelemetry()
        for segment in data.split(separator: 0) where !segment.isEmpty {
            guard let object = try? PropertyListSerialization.propertyList(
                from: Data(segment), options: [], format: nil
            ), let dictionary = object as? [String: Any] else { continue }
            merge(parse(dictionary: dictionary), into: &aggregate)
        }
        return aggregate
    }

    public static func parseText(_ output: String) -> ParsedCommandTelemetry {
        let snapshot = PowermetricsThermalParser.parse(output, generatedAt: .distantPast)
        let readings = snapshot.thermalReadings.map { reading in
            DetailedThermalReading.temperature(
                source: "powermetrics",
                identifier: slug(reading.name),
                label: reading.name,
                category: category(for: reading.name),
                celsius: reading.celsius,
                classification: .known
            )
        }
        let pressureReading = snapshot.thermalPressure.map { pressure in
            DetailedThermalReading(
                source: "powermetrics",
                identifier: "thermalPressure",
                label: "Thermal pressure",
                category: .system,
                kind: .thermalPressure,
                textValue: pressure.lowercased(),
                classification: .known
            )
        }
        return ParsedCommandTelemetry(
            readings: readings + [pressureReading].compactMap { $0 },
            componentPowers: snapshot.componentPowers,
            throttling: snapshot.throttling,
            thermalPressure: snapshot.thermalPressure
        )
    }

    private static func parse(dictionary: [String: Any]) -> ParsedCommandTelemetry {
        var telemetry = ParsedCommandTelemetry()
        var strongestThrottle = 0
        for (path, value) in RegistryPropertyFlattener.flatten(dictionary).sorted(by: { $0.key < $1.key }) {
            let lower = path.lowercased()
            let leaf = lower.split(separator: ".").last.map(String.init) ?? lower
            switch value {
            case let .string(text) where lower.contains("pressure"):
                telemetry.thermalPressure = normalizedTitle(text)
                telemetry.readings.append(DetailedThermalReading(
                    source: "powermetrics",
                    identifier: path,
                    label: path,
                    category: .system,
                    kind: .thermalPressure,
                    textValue: text.lowercased(),
                    classification: .known
                ))
            case let .number(number) where lower.contains("temp"):
                if number.isFinite, (-40...150).contains(number) {
                    telemetry.readings.append(.temperature(
                        source: "powermetrics",
                        identifier: path,
                        label: path,
                        category: category(for: path),
                        celsius: number,
                        classification: .heuristic
                    ))
                } else {
                    telemetry.warnings.append("\(path): nonfinite or implausible temperature omitted")
                }
            case let .number(number) where isPowerField(leaf):
                if number.isFinite, number >= 0 {
                    let watts = leaf.hasSuffix("_mw") || ["cpu_power", "gpu_power", "ane_power", "combined_power"].contains(leaf)
                        ? number / 1_000
                        : number
                    telemetry.componentPowers.append(ComponentPowerReading(
                        name: componentName(for: path),
                        watts: watts,
                        source: "powermetrics"
                    ))
                } else {
                    telemetry.warnings.append("\(path): nonfinite or negative power omitted")
                }
            case let .number(number) where lower.contains("limit")
                || lower.contains("forced") || lower.contains("sfi"):
                if number.isFinite, (0...100).contains(number) {
                    strongestThrottle = max(strongestThrottle, Int(number.rounded()))
                } else {
                    telemetry.warnings.append("\(path): nonfinite or out-of-range percentage omitted")
                }
            default:
                break
            }
        }
        let pressurePercent = pressurePercentage(telemetry.thermalPressure)
        strongestThrottle = max(strongestThrottle, pressurePercent)
        telemetry.componentPowers = deduplicatedPowers(telemetry.componentPowers)
        telemetry.throttling = ThrottlingStatus(
            level: throttleLevel(strongestThrottle, pressure: telemetry.thermalPressure),
            percentage: strongestThrottle,
            source: "powermetrics"
        )
        return telemetry
    }

    private static func merge(_ source: ParsedCommandTelemetry, into target: inout ParsedCommandTelemetry) {
        target.readings.append(contentsOf: source.readings)
        target.warnings.append(contentsOf: source.warnings)
        target.componentPowers = deduplicatedPowers(target.componentPowers + source.componentPowers)
        if let pressure = source.thermalPressure { target.thermalPressure = pressure }
        if let throttling = source.throttling,
           throttling.percentage >= (target.throttling?.percentage ?? -1) {
            target.throttling = throttling
        }
    }
}

public struct PowermetricsThermalCollector: ThermalCollector {
    public let source = "powermetrics"
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let help = try runner.run(
                executable: "/usr/bin/powermetrics",
                arguments: ["--help"],
                timeout: 5
            )
            if help.timedOut {
                return failure("powermetrics --help timed out", result: help, start: start)
            }
            let supported = PowermetricsOutputParser.supportedSamplers(
                fromHelp: help.stdoutString + "\n" + help.stderrString
            )
            if help.terminationStatus != 0, supported.isEmpty {
                return failure(commandError(help, fallback: "powermetrics --help failed"), result: help, start: start)
            }

            let preferred = ["thermal", "cpu_power", "gpu_power", "ane_power", "battery", "sfi"]
            var requested = preferred.filter(supported.contains)
            if supported.contains("smc") { requested.append("smc") }
            guard !requested.isEmpty else {
                return statusResult(
                    state: .unavailable,
                    error: "powermetrics exposes none of the requested thermal or power samplers",
                    start: start
                )
            }

            let baseArguments = [
                "--samplers", requested.joined(separator: ","),
                "--show-plimits", "--handle-invalid-values", "-n", "1", "-i", "1000"
            ]
            let plistResult = try runner.run(
                executable: "/usr/bin/powermetrics",
                arguments: baseArguments + ["--format", "plist"],
                timeout: 15
            )
            var telemetry = PowermetricsOutputParser.parsePlist(plistResult.stdout)
            var finalResult = plistResult
            var warnings = telemetry.warnings

            if plistResult.timedOut {
                if telemetry.hasUsefulTelemetry {
                    warnings.append("powermetrics plist sample timed out after returning partial telemetry")
                } else {
                    return failure("powermetrics plist sample timed out", result: plistResult, start: start)
                }
            } else if !telemetry.hasUsefulTelemetry {
                warnings.append("powermetrics plist output had no useful telemetry; used text fallback")
                let textResult = try runner.run(
                    executable: "/usr/bin/powermetrics",
                    arguments: baseArguments + ["--format", "text"],
                    timeout: 15
                )
                telemetry = PowermetricsOutputParser.parseText(textResult.stdoutString)
                warnings.append(contentsOf: telemetry.warnings)
                finalResult = textResult
                if textResult.timedOut, !telemetry.hasUsefulTelemetry {
                    return failure("powermetrics text sample timed out", result: textResult, start: start)
                }
                if textResult.timedOut {
                    warnings.append("powermetrics text sample timed out after returning partial telemetry")
                }
            }

            if finalResult.truncated { warnings.append("powermetrics output exceeded the capture limit") }
            if finalResult.terminationStatus != 0 {
                warnings.append("powermetrics exited with status \(finalResult.terminationStatus)")
            }
            guard telemetry.hasUsefulTelemetry || finalResult.terminationStatus == 0 else {
                return failure(
                    commandError(finalResult, fallback: "powermetrics sample failed"),
                    result: finalResult,
                    warnings: warnings,
                    start: start
                )
            }

            let bounded = bound(warnings)
            let state: ThermalSourceState = bounded.isEmpty ? .success : .partial
            return ThermalCollectionResult(
                readings: telemetry.readings,
                status: ThermalSourceStatus(
                    source: source,
                    state: state,
                    readingCount: telemetry.readings.count,
                    durationMilliseconds: elapsed(since: start),
                    warnings: bounded,
                    scannedRecordCount: telemetry.readings.count + telemetry.componentPowers.count
                ),
                componentPowers: telemetry.componentPowers,
                throttling: telemetry.throttling,
                thermalPressure: telemetry.thermalPressure
            )
        } catch {
            return statusResult(state: .failed, error: String(describing: error), start: start)
        }
    }

    private func failure(
        _ error: String,
        result: CommandResult,
        warnings: [String] = [],
        start: UInt64
    ) -> ThermalCollectionResult {
        var details = warnings
        if result.truncated { details.append("command output exceeded the capture limit") }
        return statusResult(state: .failed, error: error, warnings: details, start: start)
    }

    private func statusResult(
        state: ThermalSourceState,
        error: String,
        warnings: [String] = [],
        start: UInt64
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [],
            status: ThermalSourceStatus(
                source: source,
                state: state,
                readingCount: 0,
                durationMilliseconds: elapsed(since: start),
                warnings: bound(warnings),
                error: error,
                scannedRecordCount: 0
            )
        )
    }
}

public struct PMSetThermalCollector: ThermalCollector {
    public let source = "pmset"
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func collect(at timestamp: Date) -> ThermalCollectionResult {
        _ = timestamp
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let command = try runner.run(
                executable: "/usr/bin/pmset",
                arguments: ["-g", "therm"],
                timeout: 5
            )
            let throttling = pmsetThrottling(command.stdoutString)
            let useful = pmsetOutputIsRecognized(command.stdoutString)
            let reading = DetailedThermalReading(
                source: source,
                identifier: "thermalPressure",
                label: "Thermal pressure",
                category: .system,
                kind: .thermalPressure,
                textValue: throttling.level.lowercased(),
                classification: .known
            )
            if command.timedOut {
                return failedCommand(
                    "pmset -g therm timed out",
                    command: command,
                    reading: useful ? reading : nil,
                    throttling: useful ? throttling : nil,
                    start: start
                )
            }
            if command.terminationStatus != 0, !useful {
                return failedCommand(
                    commandError(command, fallback: "pmset -g therm failed"),
                    command: command,
                    start: start
                )
            }
            if !useful {
                return ThermalCollectionResult(
                    readings: [],
                    status: ThermalSourceStatus(
                        source: source,
                        state: .unavailable,
                        readingCount: 0,
                        durationMilliseconds: elapsed(since: start),
                        error: "pmset returned no recognizable thermal fields",
                        scannedRecordCount: 0
                    )
                )
            }

            let warnings = command.terminationStatus == 0
                ? []
                : ["pmset exited with status \(command.terminationStatus)"]
            return ThermalCollectionResult(
                readings: [reading],
                status: ThermalSourceStatus(
                    source: source,
                    state: warnings.isEmpty ? .success : .partial,
                    readingCount: 1,
                    durationMilliseconds: elapsed(since: start),
                    warnings: warnings,
                    scannedRecordCount: 1
                ),
                throttling: throttling,
                thermalPressure: throttling.level
            )
        } catch {
            return ThermalCollectionResult.failed(
                source: source,
                durationMilliseconds: elapsed(since: start),
                error: String(describing: error)
            )
        }
    }

    private func failedCommand(
        _ error: String,
        command: CommandResult,
        reading: DetailedThermalReading? = nil,
        throttling: ThrottlingStatus? = nil,
        start: UInt64
    ) -> ThermalCollectionResult {
        ThermalCollectionResult(
            readings: [reading].compactMap { $0 },
            status: ThermalSourceStatus(
                source: source,
                state: .failed,
                readingCount: reading == nil ? 0 : 1,
                durationMilliseconds: elapsed(since: start),
                warnings: command.truncated ? ["command output exceeded the capture limit"] : [],
                error: error,
                scannedRecordCount: reading == nil ? 0 : 1
            ),
            throttling: throttling,
            thermalPressure: throttling?.level
        )
    }
}

private func category(for text: String) -> ThermalCategory {
    let lower = text.lowercased()
    if lower.contains("cpu") { return .cpu }
    if lower.contains("gpu") { return .gpu }
    if lower.contains("battery") { return .battery }
    if lower.contains("dram") || lower.contains("memory") { return .memory }
    if lower.contains("nand") || lower.contains("storage") || lower.contains("ssd") { return .storage }
    return .system
}

private func componentName(for text: String) -> String {
    let lower = text.lowercased()
    if lower.contains("cpu") { return "CPU" }
    if lower.contains("gpu") { return "GPU" }
    if lower.contains("ane") { return "ANE" }
    if lower.contains("dram") || lower.contains("memory") { return "DRAM" }
    if lower.contains("battery") { return "Battery" }
    return text.split(separator: ".").last.map(String.init) ?? text
}

private func isPowerField(_ leaf: String) -> Bool {
    guard leaf.contains("power") else { return false }
    return leaf.hasSuffix("_mw") || leaf.hasSuffix("_w") || leaf.hasSuffix("_watts")
        || ["cpu_power", "gpu_power", "ane_power", "combined_power"].contains(leaf)
}

private func deduplicatedPowers(_ powers: [ComponentPowerReading]) -> [ComponentPowerReading] {
    var order: [String] = []
    var values: [String: ComponentPowerReading] = [:]
    for power in powers {
        let key = power.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if values[key] == nil { order.append(key) }
        if let existing = values[key], existing.watts > 0, power.watts == 0 { continue }
        values[key] = power
    }
    return order.compactMap { values[$0] }
}

private func pressurePercentage(_ pressure: String?) -> Int {
    switch pressure?.lowercased() {
    case let value? where value.contains("critical") || value.contains("heavy"): return 90
    case let value? where value.contains("serious") || value.contains("moderate"): return 60
    case let value? where value.contains("fair") || value.contains("light"): return 30
    default: return 0
    }
}

private func throttleLevel(_ percentage: Int, pressure: String?) -> String {
    let percentageLevel: String
    if percentage >= 80 {
        percentageLevel = "Heavy"
    } else if percentage >= 40 {
        percentageLevel = "Moderate"
    } else if percentage > 0 {
        percentageLevel = "Light"
    } else {
        percentageLevel = "Nominal"
    }
    guard let pressure, !pressure.isEmpty else { return percentageLevel }
    let explicit = normalizedTitle(pressure)
    return pressurePercentage(explicit) >= pressurePercentage(percentageLevel)
        ? explicit
        : percentageLevel
}

private func normalizedTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "Unknown" }
    return first.uppercased() + trimmed.dropFirst().lowercased()
}

private func slug(_ value: String) -> String {
    value.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
}

private func pmsetOutputIsRecognized(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("thermal warning") || lower.contains("performance warning")
        || lower.contains("cpu power status")
}

private func pmsetThrottling(_ output: String) -> ThrottlingStatus {
    let shared = PMSetThermalParser.parse(output)
    for line in output.components(separatedBy: .newlines)
    where line.localizedCaseInsensitiveContains("CPU Power Status") {
        guard let colon = line.lastIndex(of: ":"),
              let percentage = Int(line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
        return ThrottlingStatus(
            level: throttleLevel(percentage, pressure: shared.level),
            percentage: percentage,
            source: "pmset"
        )
    }
    return shared
}

private func commandError(_ result: CommandResult, fallback: String) -> String {
    let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
    return stderr.isEmpty ? "\(fallback) (exit \(result.terminationStatus))" : stderr
}

private func elapsed(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func bound(_ warnings: [String], maximum: Int = 20) -> [String] {
    guard warnings.count > maximum else { return warnings }
    return Array(warnings.prefix(maximum)) + ["\(warnings.count - maximum) additional warnings omitted"]
}
