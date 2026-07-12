import Foundation
@testable import ThermalProbeCore

final class FixtureClock: ProbeClock {
    private(set) var wallNow: Date
    private(set) var monotonicNow: TimeInterval

    init(wallNow: Date = Date(timeIntervalSince1970: 100), monotonicNow: TimeInterval = 10) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
    }

    func sleep(milliseconds: Int) {
        advance(TimeInterval(milliseconds) / 1_000)
    }

    func advance(_ seconds: TimeInterval) {
        wallNow = wallNow.addingTimeInterval(seconds)
        monotonicNow += seconds
    }
}

struct FixtureCollector: ThermalCollector {
    let source: String
    let result: (CollectionContext) -> SourceResult

    func collect(context: CollectionContext) -> SourceResult {
        result(context)
    }

    static func temperature(
        _ source: String,
        _ value: Double,
        identifier: String = "Tp01",
        category: ReadingCategory = .cpu,
        clock: FixtureClock? = nil,
        advanceSeconds: TimeInterval = 0
    ) -> FixtureCollector {
        FixtureCollector(source: source) { context in
            let started = context.clock.wallNow
            clock?.advance(advanceSeconds)
            let reading = Reading(
                source: source,
                identifier: identifier,
                label: identifier,
                category: category,
                kind: .temperature,
                value: .number(value),
                unit: "C",
                timestamp: context.clock.wallNow,
                classification: .known
            )
            return .completed(
                source: source,
                startedAt: started,
                durationMilliseconds: advanceSeconds * 1_000,
                readings: [reading]
            )
        }
    }
}

enum ThermalFixtures {
    static let host = HostMetadata(
        osVersion: "27.0",
        osBuild: "26A5378j",
        model: "Mac16,12",
        chip: "Apple M4"
    )

    static let invocation = InvocationMetadata(
        arguments: [],
        isRoot: true,
        requestedSamples: 1,
        intervalMilliseconds: 1000,
        raw: false
    )

    static func sample(
        index: Int,
        source: String,
        identifier: String,
        value: Double,
        category: ReadingCategory = .cpu
    ) -> ThermalSample {
        let reading = Reading(
            source: source,
            identifier: identifier,
            label: identifier,
            category: category,
            kind: .temperature,
            value: .number(value),
            unit: "C",
            timestamp: Date(timeIntervalSince1970: Double(index)),
            classification: .known
        )
        let result = SourceResult.completed(
            source: source,
            startedAt: reading.timestamp,
            durationMilliseconds: 1,
            readings: [reading]
        )
        return ThermalSample(
            index: index,
            startedAt: reading.timestamp,
            durationMilliseconds: 1,
            sources: [result],
            summaries: []
        )
    }

    static func capture(sampleCount: Int) -> CaptureEnvelope {
        let samples = (0..<sampleCount).map {
            sample(index: $0, source: "smc", identifier: "Tp01", value: Double(40 + $0))
        }
        return CaptureEnvelope(
            schemaVersion: 1,
            host: host,
            invocation: invocation,
            samples: samples,
            aggregates: [],
            warnings: []
        )
    }
}

struct FixtureHostProvider: HostMetadataProviding {
    func metadata() -> HostMetadata { ThermalFixtures.host }
}
