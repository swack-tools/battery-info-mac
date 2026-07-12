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

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
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
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let output = BoundedCommandOutput(maximumBytes: maximumBytes)
        let readers = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        drain(stdoutPipe.fileHandleForReading, stream: .stdout, output: output, group: readers)
        drain(stderrPipe.fileHandleForReading, stream: .stderr, output: output, group: readers)
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        var timedOut = false
        if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        process.waitUntilExit()
        readers.wait()

        let captured = output.snapshot()
        return CommandResult(
            executable: executable,
            arguments: arguments,
            terminationStatus: process.terminationStatus,
            stdout: captured.stdout,
            stderr: captured.stderr,
            timedOut: timedOut,
            truncated: captured.truncated,
            durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )
    }

    private func drain(
        _ handle: FileHandle,
        stream: BoundedCommandOutput.Stream,
        output: BoundedCommandOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let data = handle.readData(ofLength: 8 * 1_024)
                guard !data.isEmpty else { return }
                output.append(data, stream: stream)
            }
        }
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

    public init(
        readings: [DetailedThermalReading] = [],
        componentPowers: [ComponentPowerReading] = [],
        throttling: ThrottlingStatus? = nil,
        thermalPressure: String? = nil
    ) {
        self.readings = readings
        self.componentPowers = componentPowers
        self.throttling = throttling
        self.thermalPressure = thermalPressure
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
            case let .number(number) where lower.contains("temp")
                && number.isFinite && (-40...150).contains(number):
                telemetry.readings.append(.temperature(
                    source: "powermetrics",
                    identifier: path,
                    label: path,
                    category: category(for: path),
                    celsius: number,
                    classification: .heuristic
                ))
            case let .number(number) where isPowerField(leaf):
                let watts = leaf.hasSuffix("_mw") || ["cpu_power", "gpu_power", "ane_power", "combined_power"].contains(leaf)
                    ? number / 1_000
                    : number
                telemetry.componentPowers.append(ComponentPowerReading(
                    name: componentName(for: path),
                    watts: watts,
                    source: "powermetrics"
                ))
            case let .number(number) where lower.contains("limit")
                || lower.contains("forced") || lower.contains("sfi"):
                strongestThrottle = max(strongestThrottle, Int(number.rounded()))
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
                "--show-plimits", "-n", "1", "-i", "1000"
            ]
            let plistResult = try runner.run(
                executable: "/usr/bin/powermetrics",
                arguments: baseArguments + ["--format", "plist"],
                timeout: 15
            )
            var telemetry = PowermetricsOutputParser.parsePlist(plistResult.stdout)
            var finalResult = plistResult
            var warnings: [String] = []

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
    if let pressure, !pressure.isEmpty { return normalizedTitle(pressure) }
    if percentage >= 80 { return "Heavy" }
    if percentage >= 40 { return "Moderate" }
    if percentage > 0 { return "Light" }
    return "Nominal"
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
