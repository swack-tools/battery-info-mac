import BatteryMonitorShared
import BatteryMonitorThermal
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

let coordinator = ThermalCaptureCoordinator.default
let snapshotWriter = AtomicThermalSnapshotWriter()

repeat {
    do {
        let snapshot = coordinator.collect(generatedAt: Date())
        try snapshotWriter.write(
            snapshot: snapshot,
            to: URL(fileURLWithPath: helperArguments.outputPath)
        )
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
