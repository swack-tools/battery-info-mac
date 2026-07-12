import Darwin
import Foundation

public protocol HostMetadataProviding {
    func metadata() -> HostMetadata
}

public struct LiveHostMetadataProvider: HostMetadataProviding {
    public init() {}

    public func metadata() -> HostMetadata {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion == 0 ? "" : ".\(version.patchVersion)")
        return HostMetadata(
            osVersion: osVersion,
            osBuild: systemVersionValue("ProductBuildVersion") ?? "unknown",
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown"
        )
    }

    private func systemVersionValue(_ key: String) -> String? {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary[key] as? String
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

public final class CaptureCoordinator {
    public static let schemaVersion = 1

    private let clock: any ProbeClock
    private let hostProvider: any HostMetadataProviding

    public init(
        clock: any ProbeClock = SystemProbeClock(),
        hostProvider: any HostMetadataProviding = LiveHostMetadataProvider()
    ) {
        self.clock = clock
        self.hostProvider = hostProvider
    }

    public func capture(
        options: ProbeOptions,
        arguments: [String],
        isRoot: Bool,
        collectors: [any ThermalCollector],
        onSample: ((SampleStreamRecord) -> Void)? = nil
    ) -> CaptureEnvelope {
        let host = hostProvider.metadata()
        let invocation = InvocationMetadata(
            arguments: arguments,
            isRoot: isRoot,
            requestedSamples: options.samples,
            intervalMilliseconds: options.intervalMilliseconds,
            raw: options.raw
        )
        var samples: [ThermalSample] = []
        var warnings: [String] = []

        for index in 0..<max(0, options.samples) {
            let sampleStartedAt = clock.wallNow
            let sampleMonotonicStart = clock.monotonicNow
            let context = CollectionContext(clock: clock, includeRaw: options.raw)
            let sources = CollectorRunner.run(collectors: collectors, context: context)
            let durationMilliseconds = max(
                0,
                (clock.monotonicNow - sampleMonotonicStart) * 1_000
            )
            var sample = ThermalSample(
                index: index,
                startedAt: sampleStartedAt,
                durationMilliseconds: durationMilliseconds,
                sources: sources,
                summaries: []
            )
            sample.summaries = CaptureAggregator.summarize(sample: sample)
            samples.append(sample)
            onSample?(
                SampleStreamRecord(
                    schemaVersion: Self.schemaVersion,
                    host: host,
                    invocation: invocation,
                    sample: sample
                )
            )

            guard index + 1 < options.samples else { continue }
            let remaining = Double(options.intervalMilliseconds) - durationMilliseconds
            if remaining > 0 {
                clock.sleep(milliseconds: Int(remaining.rounded(.down)))
            } else {
                warnings.append(
                    String(
                        format: "sample %d interval overrun by %.1f ms",
                        index + 1,
                        -remaining
                    )
                )
            }
        }

        return CaptureEnvelope(
            schemaVersion: Self.schemaVersion,
            host: host,
            invocation: invocation,
            samples: samples,
            aggregates: CaptureAggregator.aggregate(samples),
            warnings: warnings
        )
    }
}

public enum ProbeExitCode {
    public static func forCapture(_ capture: CaptureEnvelope) -> Int32 {
        capture.samples.flatMap(\.sources).contains { !$0.readings.isEmpty } ? 0 : 1
    }
}
