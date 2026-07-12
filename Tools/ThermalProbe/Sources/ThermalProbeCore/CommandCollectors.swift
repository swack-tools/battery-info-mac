import Foundation

private func commandCapabilities(
    _ base: [String: JSONValue] = [:],
    result: CommandResult,
    includeRaw: Bool
) -> [String: JSONValue] {
    guard includeRaw else { return base }
    var capabilities = base
    capabilities["rawStdout"] = .string(result.stdoutString)
    capabilities["rawStderr"] = .string(result.stderrString)
    capabilities["rawCommandExitStatus"] = .number(Double(result.terminationStatus))
    capabilities["rawCommandTimedOut"] = .bool(result.timedOut)
    capabilities["rawCommandTruncated"] = .bool(result.truncated)
    return capabilities
}

public enum PMSetParser {
    public static func parse(_ output: String, timestamp: Date) -> [Reading] {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var readings: [Reading] = []

        if lines.contains(where: { $0.localizedCaseInsensitiveContains("No thermal warning level") }) {
            readings.append(
                Reading(
                    source: "pmset",
                    identifier: "thermalPressure",
                    label: "Thermal pressure",
                    category: .system,
                    kind: .thermalPressure,
                    value: .text("nominal"),
                    unit: nil,
                    timestamp: timestamp,
                    classification: .known
                )
            )
        }

        let fields: [(label: String, identifier: String, kind: ReadingKind)] = [
            ("Thermal Warning Level", "thermalWarningLevel", .thermalPressure),
            ("Performance Warning Level", "performanceWarningLevel", .rawContext),
            ("CPU Power Status", "cpuPowerStatus", .powerLimit)
        ]
        for field in fields {
            guard let line = lines.first(where: { $0.localizedCaseInsensitiveContains(field.label) }),
                  let value = number(afterColonIn: line) else { continue }
            readings.append(
                Reading(
                    source: "pmset",
                    identifier: field.identifier,
                    label: field.label,
                    category: field.identifier.hasPrefix("cpu") ? .cpu : .system,
                    kind: field.kind,
                    value: .number(value),
                    unit: field.kind == .powerLimit ? "%" : nil,
                    timestamp: timestamp,
                    classification: .known,
                    metadata: ["rawLine": .string(line)]
                )
            )
        }

        return readings
    }

    private static func number(afterColonIn line: String) -> Double? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let suffix = line[line.index(after: colon)...]
        return Double(suffix.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum PowermetricsParser {
    public static func supportedSamplers(fromHelp output: String) -> [String] {
        var inSamplerSection = false
        var samplers: [String] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.contains("The following samplers are supported by --samplers") {
                inSamplerSection = true
                continue
            }
            if line.contains("sampler groups are supported by --samplers") {
                break
            }
            guard inSamplerSection else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let name = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
                continue
            }
            samplers.append(name)
        }
        return samplers
    }

    public static func parseText(_ output: String, timestamp: Date) -> [Reading] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            parseTextLine(
                String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: timestamp
            )
        }
    }

    public static func parsePlist(_ data: Data, timestamp: Date) -> [Reading] {
        data.split(separator: 0).flatMap { segment -> [Reading] in
            guard !segment.isEmpty,
                  let propertyList = try? PropertyListSerialization.propertyList(
                    from: Data(segment),
                    options: [],
                    format: nil
                  ),
                  let dictionary = propertyList as? [String: Any] else {
                return []
            }

            return RegistryFlattener.flatten(dictionary)
                .sorted { $0.key < $1.key }
                .compactMap { path, value in
                    mapPlist(path: path, value: value, timestamp: timestamp)
                }
        }
    }

    private static func parseTextLine(_ line: String, timestamp: Date) -> Reading? {
        guard !line.isEmpty else { return nil }

        if let fields = captures(
            pattern: "^(.+? Power):\\s*(-?[0-9]+(?:\\.[0-9]+)?)\\s*(mW|W)$",
            in: line,
            options: [.caseInsensitive]
        ), let rawValue = Double(fields[1]) {
            let watts = fields[2].lowercased() == "mw" ? rawValue / 1_000 : rawValue
            return reading(
                identifier: fields[0],
                category: componentCategory(fields[0]),
                kind: .power,
                value: .number(watts),
                unit: "W",
                timestamp: timestamp,
                rawLine: line
            )
        }

        if let fields = captures(
            pattern: "^(Thermal pressure):\\s*(.+)$",
            in: line,
            options: [.caseInsensitive]
        ) {
            return reading(
                identifier: "Thermal pressure",
                category: .system,
                kind: .thermalPressure,
                value: .text(fields[1].lowercased()),
                unit: nil,
                timestamp: timestamp,
                rawLine: line
            )
        }

        if let fields = captures(
            pattern: "^(.+?):\\s*(-?[0-9]+(?:\\.[0-9]+)?)%\\s*forced idle$",
            in: line,
            options: [.caseInsensitive]
        ), let value = Double(fields[1]) {
            return reading(
                identifier: fields[0],
                category: .system,
                kind: .forcedIdle,
                value: .number(value),
                unit: "%",
                timestamp: timestamp,
                rawLine: line
            )
        }

        if let fields = captures(
            pattern: "^(.+? Power limit):\\s*(-?[0-9]+(?:\\.[0-9]+)?)%$",
            in: line,
            options: [.caseInsensitive]
        ), let value = Double(fields[1]) {
            return reading(
                identifier: fields[0],
                category: componentCategory(fields[0]),
                kind: .powerLimit,
                value: .number(value),
                unit: "%",
                timestamp: timestamp,
                rawLine: line
            )
        }

        if let fields = captures(
            pattern: "^(.+?(?:temperature|temp))\\s*:?\\s*(-?[0-9]+(?:\\.[0-9]+)?)\\s*(?:°?C|Celsius)$",
            in: line,
            options: [.caseInsensitive]
        ), let value = Double(fields[1]) {
            return reading(
                identifier: fields[0],
                category: componentCategory(fields[0]),
                kind: .temperature,
                value: .number(value),
                unit: "C",
                timestamp: timestamp,
                rawLine: line
            )
        }

        return nil
    }

    private static func mapPlist(path: String, value: JSONValue, timestamp: Date) -> Reading? {
        let lowered = path.lowercased()
        let leaf = lowered.split(separator: ".").last.map(String.init) ?? lowered
        guard ["temp", "thermal", "pressure", "power", "limit", "forced", "sfi"]
            .contains(where: lowered.contains) else { return nil }

        let category = componentCategory(path)
        let kind: ReadingKind
        let mappedValue: ReadingValue
        let unit: String?

        switch value {
        case let .number(number):
            if lowered.contains("temp") {
                kind = .temperature
                mappedValue = .number(number)
                unit = "C"
            } else if lowered.contains("limit") {
                kind = .powerLimit
                mappedValue = .number(number)
                unit = "%"
            } else if lowered.contains("forced") || lowered.contains("sfi") {
                kind = .forcedIdle
                mappedValue = .number(number)
                unit = "%"
            } else if lowered.contains("power") {
                let milliwattFields = ["cpu_power", "gpu_power", "ane_power", "combined_power"]
                if milliwattFields.contains(leaf) || leaf.hasSuffix("_mw") {
                    kind = .power
                    mappedValue = .number(number / 1_000)
                    unit = "W"
                } else if leaf.hasSuffix("_w") || leaf.hasSuffix("_watts") {
                    kind = .power
                    mappedValue = .number(number)
                    unit = "W"
                } else {
                    kind = .rawContext
                    mappedValue = .number(number)
                    unit = nil
                }
            } else {
                kind = .rawContext
                mappedValue = .number(number)
                unit = nil
            }
        case let .string(string):
            kind = lowered.contains("pressure") ? .thermalPressure : .rawContext
            mappedValue = .text(string.lowercased())
            unit = nil
        case let .bool(flag):
            kind = .rawContext
            mappedValue = .text(flag ? "true" : "false")
            unit = nil
        case .null, .array, .object:
            return nil
        }

        return Reading(
            source: "powermetrics",
            identifier: path,
            label: path,
            category: category,
            kind: kind,
            value: mappedValue,
            unit: unit,
            timestamp: timestamp,
            classification: kind == .thermalPressure ? .known : .heuristic,
            metadata: ["format": .string("plist")]
        )
    }

    private static func reading(
        identifier: String,
        category: ReadingCategory,
        kind: ReadingKind,
        value: ReadingValue,
        unit: String?,
        timestamp: Date,
        rawLine: String
    ) -> Reading {
        Reading(
            source: "powermetrics",
            identifier: identifier,
            label: identifier,
            category: category,
            kind: kind,
            value: value,
            unit: unit,
            timestamp: timestamp,
            classification: .known,
            metadata: ["format": .string("text"), "rawLine": .string(rawLine)]
        )
    }

    private static func componentCategory(_ text: String) -> ReadingCategory {
        let lowered = text.lowercased()
        if lowered.contains("cpu") { return .cpu }
        if lowered.contains("gpu") { return .gpu }
        if lowered.contains("battery") { return .battery }
        if lowered.contains("ane") { return .system }
        if lowered.contains("dram") || lowered.contains("memory") { return .memory }
        return .system
    }

    private static func captures(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}

public struct PowermetricsCollector: ThermalCollector {
    public let source = "powermetrics"
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let start = context.clock.monotonicNow

        do {
            let help = try runner.run(
                executable: "/usr/bin/powermetrics",
                arguments: ["--help"],
                timeout: 5
            )
            if help.timedOut {
                return .timedOut(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    message: "powermetrics --help timed out",
                    capabilities: commandCapabilities(
                        ["phase": .string("help")],
                        result: help,
                        includeRaw: context.includeRaw
                    )
                )
            }
            guard help.terminationStatus == 0 else {
                return .failed(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    code: "powermetrics_help_failed",
                    message: help.stderrString.isEmpty ? "exit \(help.terminationStatus)" : help.stderrString,
                    capabilities: commandCapabilities(
                        ["phase": .string("help")],
                        result: help,
                        includeRaw: context.includeRaw
                    )
                )
            }

            let supported = PowermetricsParser.supportedSamplers(fromHelp: help.stdoutString)
            let desired = ["thermal", "cpu_power", "gpu_power", "ane_power", "battery", "sfi"]
            let requested = desired.filter(supported.contains)
            guard !requested.isEmpty else {
                return .unavailable(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    code: "no_supported_samplers",
                    message: "none of the requested thermal or power samplers are supported",
                    capabilities: commandCapabilities(
                        capabilities(supported: supported, requested: []),
                        result: help,
                        includeRaw: context.includeRaw
                    )
                )
            }

            var warnings: [String] = []

            let baseArguments = [
                "--samplers", requested.joined(separator: ","),
                "--show-plimits",
                "--handle-invalid-values",
                "--sample-count", "1",
                "--sample-rate", "1000"
            ]
            let plistResult = try runner.run(
                executable: "/usr/bin/powermetrics",
                arguments: baseArguments + ["--format", "plist"],
                timeout: 15
            )
            if plistResult.timedOut {
                return .timedOut(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    message: "powermetrics plist sample timed out",
                    capabilities: commandCapabilities(
                        capabilities(supported: supported, requested: requested),
                        result: plistResult,
                        includeRaw: context.includeRaw
                    )
                )
            }

            var readings = PowermetricsParser.parsePlist(
                plistResult.stdout,
                timestamp: context.clock.wallNow
            )
            var format = "plist"
            var finalResult = plistResult
            if readings.isEmpty {
                warnings.append("plist output had no readable telemetry; used text fallback")
                let textResult = try runner.run(
                    executable: "/usr/bin/powermetrics",
                    arguments: baseArguments + ["--format", "text"],
                    timeout: 15
                )
                if textResult.timedOut {
                    return .timedOut(
                        source: source,
                        startedAt: startedAt,
                        durationMilliseconds: elapsed(start, clock: context.clock),
                        message: "powermetrics text fallback timed out",
                        capabilities: commandCapabilities(
                            capabilities(supported: supported, requested: requested),
                            result: textResult,
                            includeRaw: context.includeRaw
                        )
                    )
                }
                readings = PowermetricsParser.parseText(
                    textResult.stdoutString,
                    timestamp: context.clock.wallNow
                )
                format = "text"
                finalResult = textResult
            }

            if finalResult.truncated {
                warnings.append("powermetrics output exceeded the capture limit")
            }
            if finalResult.terminationStatus != 0 {
                warnings.append("powermetrics exited with status \(finalResult.terminationStatus)")
            }
            var sourceCapabilities = capabilities(supported: supported, requested: requested)
            sourceCapabilities["format"] = .string(format)
            sourceCapabilities = commandCapabilities(
                sourceCapabilities,
                result: finalResult,
                includeRaw: context.includeRaw
            )
            guard !readings.isEmpty || finalResult.terminationStatus == 0 else {
                return .failed(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    code: "powermetrics_sample_failed",
                    message: finalResult.stderrString.isEmpty
                        ? "exit \(finalResult.terminationStatus)"
                        : finalResult.stderrString,
                    warnings: warnings,
                    capabilities: sourceCapabilities
                )
            }

            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                readings: readings,
                warnings: warnings,
                capabilities: sourceCapabilities
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                code: "powermetrics_execution_failed",
                message: String(describing: error)
            )
        }
    }

    private func capabilities(supported: [String], requested: [String]) -> [String: JSONValue] {
        [
            "supportedSamplers": .array(supported.map(JSONValue.string)),
            "requestedSamplers": .array(requested.map(JSONValue.string)),
            "smcSamplerAvailable": .bool(supported.contains("smc"))
        ]
    }

    private func elapsed(_ start: TimeInterval, clock: any ProbeClock) -> Double {
        max(0, (clock.monotonicNow - start) * 1_000)
    }
}

public struct PMSetCollector: ThermalCollector {
    public let source = "pmset"
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let start = context.clock.monotonicNow
        do {
            let result = try runner.run(
                executable: "/usr/bin/pmset",
                arguments: ["-g", "therm"],
                timeout: 5
            )
            let sourceCapabilities = commandCapabilities(
                result: result,
                includeRaw: context.includeRaw
            )
            if result.timedOut {
                return .timedOut(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    message: "pmset -g therm timed out",
                    capabilities: sourceCapabilities
                )
            }

            let readings = PMSetParser.parse(result.stdoutString, timestamp: context.clock.wallNow)
            guard result.terminationStatus == 0 || !readings.isEmpty else {
                return .failed(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    code: "pmset_failed",
                    message: result.stderrString.isEmpty
                        ? "exit \(result.terminationStatus)"
                        : result.stderrString,
                    capabilities: sourceCapabilities
                )
            }

            var warnings: [String] = []
            if result.terminationStatus != 0 {
                warnings.append("pmset exited with status \(result.terminationStatus)")
            }
            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                readings: readings,
                warnings: warnings,
                capabilities: sourceCapabilities
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                code: "pmset_execution_failed",
                message: String(describing: error)
            )
        }
    }

    private func elapsed(_ start: TimeInterval, clock: any ProbeClock) -> Double {
        max(0, (clock.monotonicNow - start) * 1_000)
    }
}

public struct CapabilityProbeCollector: ThermalCollector {
    public enum Format {
        case keyValue
        case json
    }

    public let source: String
    private let executable: String
    private let arguments: [String]
    private let format: Format
    private let runner: any CommandRunning

    public init(
        source: String,
        executable: String,
        arguments: [String],
        format: Format,
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.source = source
        self.executable = executable
        self.arguments = arguments
        self.format = format
        self.runner = runner
    }

    public func collect(context: CollectionContext) -> SourceResult {
        let startedAt = context.clock.wallNow
        let start = context.clock.monotonicNow
        do {
            let result = try runner.run(executable: executable, arguments: arguments, timeout: 5)
            let rawCapabilities = commandCapabilities(
                result: result,
                includeRaw: context.includeRaw
            )
            if result.timedOut {
                return .timedOut(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    message: "\(source) capability probe timed out",
                    capabilities: rawCapabilities
                )
            }
            let readings = parse(result: result, timestamp: context.clock.wallNow)
            guard result.terminationStatus == 0 || !readings.isEmpty else {
                return .failed(
                    source: source,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed(start, clock: context.clock),
                    code: "capability_probe_failed",
                    message: result.stderrString.isEmpty
                        ? "exit \(result.terminationStatus)"
                        : result.stderrString,
                    capabilities: rawCapabilities
                )
            }

            var capabilities: [String: JSONValue] = rawCapabilities
            capabilities.merge([
                "relevantFieldCount": .number(Double(readings.count)),
                "exitStatus": .number(Double(result.terminationStatus))
            ]) { _, new in new }
            return .completed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                readings: readings,
                warnings: result.truncated ? ["capability output exceeded the capture limit"] : [],
                capabilities: capabilities
            )
        } catch {
            return .failed(
                source: source,
                startedAt: startedAt,
                durationMilliseconds: elapsed(start, clock: context.clock),
                code: "capability_probe_execution_failed",
                message: String(describing: error)
            )
        }
    }

    private func parse(result: CommandResult, timestamp: Date) -> [Reading] {
        switch format {
        case .keyValue:
            return result.stdoutString.split(whereSeparator: \.isNewline).compactMap { rawLine in
                let line = String(rawLine)
                let lowered = line.lowercased()
                guard lowered.contains("temp") || lowered.contains("thermal") else { return nil }
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2 else { return nil }
                let value = Double(parts[1]).map(ReadingValue.number) ?? .text(parts[1])
                return capabilityReading(
                    identifier: parts[0],
                    value: value,
                    timestamp: timestamp
                )
            }
        case .json:
            guard let object = try? JSONSerialization.jsonObject(with: result.stdout),
                  let dictionary = object as? [String: Any] else { return [] }
            return RegistryFlattener.flatten(dictionary)
                .sorted { $0.key < $1.key }
                .compactMap { path, value in
                    let lowered = path.lowercased()
                    guard lowered.contains("temp") || lowered.contains("thermal") else { return nil }
                    let readingValue: ReadingValue
                    switch value {
                    case let .number(number): readingValue = .number(number)
                    case let .string(string): readingValue = .text(string)
                    case let .bool(flag): readingValue = .text(flag ? "true" : "false")
                    case .null, .array, .object: return nil
                    }
                    return capabilityReading(
                        identifier: path,
                        value: readingValue,
                        timestamp: timestamp
                    )
                }
        }
    }

    private func capabilityReading(
        identifier: String,
        value: ReadingValue,
        timestamp: Date
    ) -> Reading {
        Reading(
            source: source,
            identifier: identifier,
            label: identifier,
            category: .system,
            kind: .rawContext,
            value: value,
            unit: nil,
            timestamp: timestamp,
            classification: .unclassified
        )
    }

    private func elapsed(_ start: TimeInterval, clock: any ProbeClock) -> Double {
        max(0, (clock.monotonicNow - start) * 1_000)
    }
}
