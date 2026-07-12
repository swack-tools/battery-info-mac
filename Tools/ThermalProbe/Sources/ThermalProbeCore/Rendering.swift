import Foundation

public enum JSONRenderer {
    public static func render(capture: CaptureEnvelope) throws -> Data {
        try ProbeJSON.encoder.encode(capture)
    }
}

public enum JSONLinesRenderer {
    public static func render(capture: CaptureEnvelope) throws -> String {
        var records = try capture.samples.map {
            try renderSample(
                $0,
                schemaVersion: capture.schemaVersion,
                host: capture.host,
                invocation: capture.invocation
            )
        }
        records.append(
            try renderSummary(
                schemaVersion: capture.schemaVersion,
                host: capture.host,
                invocation: capture.invocation,
                aggregates: capture.aggregates,
                warnings: capture.warnings
            )
        )
        return records.joined(separator: "\n") + "\n"
    }

    public static func renderSample(
        _ sample: ThermalSample,
        schemaVersion: Int,
        host: HostMetadata,
        invocation: InvocationMetadata
    ) throws -> String {
        let record = StreamRecord(
            sample: SampleStreamRecord(
                schemaVersion: schemaVersion,
                host: host,
                invocation: invocation,
                sample: sample
            )
        )
        return String(decoding: try ProbeJSON.encoder.encode(record), as: UTF8.self)
    }

    public static func renderSummary(
        schemaVersion: Int,
        host: HostMetadata,
        invocation: InvocationMetadata,
        aggregates: [SensorAggregate],
        warnings: [String]
    ) throws -> String {
        let record = StreamRecord(
            summary: SummaryStreamRecord(
                schemaVersion: schemaVersion,
                host: host,
                invocation: invocation,
                aggregates: aggregates,
                warnings: warnings
            )
        )
        return String(decoding: try ProbeJSON.encoder.encode(record), as: UTF8.self)
    }
}

public enum HumanRenderer {
    public static func render(capture: CaptureEnvelope) -> String {
        var lines = [
            "Thermal Probe schema \(capture.schemaVersion)",
            "macOS \(capture.host.osVersion) (\(capture.host.osBuild))",
            "\(capture.host.model) - \(capture.host.chip)",
            ""
        ]
        for sample in capture.samples {
            lines.append(renderSample(sample, includeRawMetadata: capture.invocation.raw))
        }
        lines.append(renderSummary(aggregates: capture.aggregates, warnings: capture.warnings))
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    public static func renderSample(
        _ sample: ThermalSample,
        includeRawMetadata: Bool = false
    ) -> String {
        var lines = [
            "Sample \(sample.index + 1) @ \(ProbeJSON.format(date: sample.startedAt))",
            "Sources:"
        ]
        for source in sample.sources {
            lines.append(
                String(
                    format: "  %-18@ %-11@ %5d readings %8.1f ms",
                    source.source,
                    source.status.rawValue,
                    source.readings.count,
                    source.durationMilliseconds
                )
            )
            if let error = source.error {
                lines.append("    error [\(error.code)]: \(error.message)")
            }
            for warning in source.warnings {
                lines.append("    warning: \(warning)")
            }
            if includeRawMetadata {
                for key in source.capabilities.keys.sorted() {
                    guard let value = source.capabilities[key] else { continue }
                    lines.append("    capability \(key): \(renderJSONValue(value))")
                }
            }
        }

        let readings = sample.sources.flatMap(\.readings).sorted {
            if $0.category == $1.category {
                if $0.source == $1.source { return $0.identifier < $1.identifier }
                return $0.source < $1.source
            }
            return $0.category.rawValue < $1.category.rawValue
        }
        lines.append("Readings:")
        if readings.isEmpty {
            lines.append("  (none)")
        } else {
            for reading in readings {
                let value: String
                switch reading.value {
                case let .number(number):
                    value = String(format: "%.2f", number) + (reading.unit.map { " \($0)" } ?? "")
                case let .text(text):
                    value = text + (reading.unit.map { " \($0)" } ?? "")
                }
                let label = reading.label.map { " [\($0)]" } ?? ""
                lines.append(
                    "  \(reading.category.rawValue)/\(reading.source) \(reading.identifier)\(label): \(value)"
                )
                if includeRawMetadata {
                    for key in reading.metadata.keys.sorted() {
                        guard let metadata = reading.metadata[key] else { continue }
                        lines.append("    metadata \(key): \(renderJSONValue(metadata))")
                    }
                    if let rawDataType = reading.rawDataType {
                        lines.append("    raw datatype: \(rawDataType)")
                    }
                    if let rawBytes = reading.rawBytes {
                        let hexadecimal = rawBytes.map { String(format: "%02x", $0) }.joined()
                        lines.append("    raw bytes: \(hexadecimal)")
                    }
                    if let rawIntegerValue = reading.rawIntegerValue {
                        lines.append("    raw integer: \(rawIntegerValue)")
                    }
                }
                for warning in reading.warnings {
                    lines.append("    warning: \(warning)")
                }
            }
        }

        if !sample.summaries.isEmpty {
            lines.append("Component summaries:")
            for summary in sample.summaries {
                lines.append(
                    String(
                        format: "  %@ min %.2f C avg %.2f C max %.2f C (%d sensors)",
                        summary.category.rawValue,
                        summary.minimum,
                        summary.average,
                        summary.maximum,
                        summary.count
                    )
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func renderSummary(
        aggregates: [SensorAggregate],
        warnings: [String]
    ) -> String {
        var lines = ["Capture aggregates:"]
        if aggregates.isEmpty {
            lines.append("  (none)")
        } else {
            for aggregate in aggregates {
                let unit = aggregate.unit.map { " \($0)" } ?? ""
                lines.append(
                    String(
                        format: "  %@/%@ min %.2f%@ avg %.2f%@ max %.2f%@ delta %+.2f%@ (%d samples)",
                        aggregate.source,
                        aggregate.identifier,
                        aggregate.minimum,
                        unit,
                        aggregate.average,
                        unit,
                        aggregate.maximum,
                        unit,
                        aggregate.delta,
                        unit,
                        aggregate.sampleCount
                    )
                )
            }
        }
        for warning in warnings {
            lines.append("  warning: \(warning)")
        }
        return lines.joined(separator: "\n")
    }

    public static func diagnostics(capture: CaptureEnvelope) -> [String] {
        capture.samples.flatMap { sample in
            sample.sources.flatMap { source -> [String] in
                var messages = source.warnings.map { "\(source.source): \($0)" }
                if let error = source.error {
                    messages.append("\(source.source) [\(error.code)]: \(error.message)")
                }
                return messages
            }
        } + capture.warnings
    }

    private static func renderJSONValue(_ value: JSONValue) -> String {
        guard let data = try? ProbeJSON.encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
