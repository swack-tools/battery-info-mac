import Darwin
import Dispatch
import Foundation
import ThermalProbeCore

private enum StandardIO {
    static func writeOut(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    static func writeOut(_ value: Data) {
        FileHandle.standardOutput.write(value)
    }

    static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}

private enum SignalCoordinator {
    private static var sources: [DispatchSourceSignal] = []

    static func install() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler {
                ActiveProcessRegistry.shared.terminateAll()
                Darwin.exit(128 + signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }
}

private func printHumanHeader(_ record: SampleStreamRecord) {
    StandardIO.writeOut("Thermal Probe schema \(record.schemaVersion)\n")
    StandardIO.writeOut("macOS \(record.host.osVersion) (\(record.host.osBuild))\n")
    StandardIO.writeOut("\(record.host.model) - \(record.host.chip)\n\n")
}

private func run() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let options: ProbeOptions
    do {
        options = try ProbeOptions.parse(arguments)
    } catch {
        StandardIO.writeError("thermal-probe: \(error)\n\n\(ProbeOptions.usage)\n")
        return 64
    }

    switch RuntimeDecision.evaluate(options: options, effectiveUserID: geteuid()) {
    case .showHelp:
        StandardIO.writeOut(ProbeOptions.usage + "\n")
        return 0
    case let .exit(code):
        StandardIO.writeError("thermal-probe must be run as root: sudo thermal-probe\n")
        return code
    case .collect:
        break
    }

    SignalCoordinator.install()
    let runner = ProcessCommandRunner()
    let collectors = DefaultCollectorFactory.make(commandRunner: runner)
    let coordinator = CaptureCoordinator()
    var renderingError: Error?
    var wroteHumanHeader = false

    let capture = coordinator.capture(
        options: options,
        arguments: arguments,
        isRoot: true,
        collectors: collectors,
        onSample: options.format == .json ? nil : { record in
            do {
                switch options.format {
                case .human:
                    if !wroteHumanHeader {
                        printHumanHeader(record)
                        wroteHumanHeader = true
                    }
                    StandardIO.writeOut(
                        HumanRenderer.renderSample(
                            record.sample,
                            includeRawMetadata: record.invocation.raw
                        )
                    )
                case .jsonLines:
                    let encoded = try ProbeJSON.encoder.encode(StreamRecord(sample: record))
                    StandardIO.writeOut(encoded)
                    StandardIO.writeOut("\n")
                case .json:
                    break
                }
            } catch {
                renderingError = error
            }
        }
    )

    if let renderingError {
        StandardIO.writeError("thermal-probe rendering failed: \(renderingError)\n")
        return 1
    }

    do {
        switch options.format {
        case .human:
            StandardIO.writeOut(
                HumanRenderer.renderSummary(
                    aggregates: capture.aggregates,
                    warnings: capture.warnings
                ) + "\n"
            )
            for diagnostic in HumanRenderer.diagnostics(capture: capture) {
                StandardIO.writeError("thermal-probe: \(diagnostic)\n")
            }
        case .json:
            StandardIO.writeOut(try JSONRenderer.render(capture: capture))
            StandardIO.writeOut("\n")
        case .jsonLines:
            let summary = try JSONLinesRenderer.renderSummary(
                schemaVersion: capture.schemaVersion,
                host: capture.host,
                invocation: capture.invocation,
                aggregates: capture.aggregates,
                warnings: capture.warnings
            )
            StandardIO.writeOut(summary + "\n")
        }
    } catch {
        StandardIO.writeError("thermal-probe rendering failed: \(error)\n")
        return 1
    }

    return ProbeExitCode.forCapture(capture)
}

Darwin.exit(run())
