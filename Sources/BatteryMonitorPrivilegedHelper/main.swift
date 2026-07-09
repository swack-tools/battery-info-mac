import BatteryMonitorShared
import Darwin
import Foundation

private let defaultOutputPath = "/Library/Application Support/BatteryMonitor/privileged-telemetry.json"
private let defaultInterval: UInt32 = 10

struct HelperArguments {
    var runOnce = false
    var outputPath = defaultOutputPath
    var interval = defaultInterval
    var allowNonRootForFixture = false

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--once":
                runOnce = true
            case "--output":
                if index + 1 < arguments.count {
                    outputPath = arguments[index + 1]
                    index += 1
                }
            case "--interval":
                if index + 1 < arguments.count, let value = UInt32(arguments[index + 1]) {
                    interval = max(1, value)
                    index += 1
                }
            case "--test-fixture":
                allowNonRootForFixture = true
            default:
                break
            }
            index += 1
        }
    }
}

let helperArguments = HelperArguments(arguments: Array(CommandLine.arguments.dropFirst()))

guard getuid() == 0 || helperArguments.allowNonRootForFixture else {
    fputs("BatteryMonitorPrivilegedHelper must run as root.\n", stderr)
    exit(1)
}

repeat {
    do {
        let snapshot = collectSnapshot(generatedAt: Date())
        try write(snapshot: snapshot, to: URL(fileURLWithPath: helperArguments.outputPath))
    } catch {
        fputs("BatteryMonitorPrivilegedHelper failed: \(error)\n", stderr)
        if helperArguments.runOnce {
            exit(2)
        }
    }

    if helperArguments.runOnce {
        break
    }

    sleep(helperArguments.interval)
} while true

private func collectSnapshot(generatedAt: Date) -> ThermalSnapshot {
    let powermetricsOutput = runCommand(
        "/usr/bin/powermetrics",
        arguments: [
            "--samplers",
            supportedPowermetricsSamplers(),
            "--show-plimits",
            "-n",
            "1",
            "-i",
            "1000"
        ]
    )

    let pmsetOutput = runCommand("/usr/bin/pmset", arguments: ["-g", "therm"])
    var snapshot = PowermetricsThermalParser.parse(powermetricsOutput ?? "", generatedAt: generatedAt)

    if let pmsetOutput {
        let pmsetStatus = PMSetThermalParser.parse(pmsetOutput)
        if snapshot.throttling.percentage == 0 {
            snapshot.throttling = pmsetStatus
        }
        if snapshot.thermalPressure == nil {
            snapshot.thermalPressure = pmsetStatus.level
        }
    }

    if powermetricsOutput == nil {
        snapshot.messages.append("powermetrics did not return data")
    }
    if pmsetOutput == nil {
        snapshot.messages.append("pmset thermal data did not return data")
    }

    return snapshot
}

private func supportedPowermetricsSamplers() -> String {
    let preferredSamplers = ["cpu_power", "gpu_power", "ane_power", "thermal", "sfi", "smc"]

    guard let help = runCommand("/usr/bin/powermetrics", arguments: ["--help"]) else {
        return "cpu_power,gpu_power,ane_power,thermal,sfi"
    }

    let supportedSamplers = preferredSamplers.filter { help.contains($0) }
    if supportedSamplers.isEmpty {
        return "cpu_power,gpu_power,ane_power,thermal,sfi"
    }

    return supportedSamplers.joined(separator: ",")
}

private func runCommand(_ command: String, arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

private func write(snapshot: ThermalSnapshot, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let data = try encoder.encode(snapshot)
    let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
    try data.write(to: temporaryURL, options: .atomic)

    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    try FileManager.default.moveItem(at: temporaryURL, to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
}
