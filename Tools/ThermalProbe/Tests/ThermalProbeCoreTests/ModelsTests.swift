import Foundation
import XCTest
@testable import ThermalProbeCore

final class ModelsTests: XCTestCase {
    func testCaptureEnvelopeRoundTripsWithoutLosingTypedMetadata() throws {
        let reading = Reading(
            source: "smc",
            identifier: "Tp01",
            label: "CPU performance core 1",
            category: .cpu,
            kind: .temperature,
            value: .number(61.25),
            unit: "C",
            timestamp: Date(timeIntervalSince1970: 10),
            classification: .known,
            metadata: ["nested": .object(["enabled": .bool(true)])],
            warnings: [],
            rawDataType: "sp78",
            rawBytes: [0x3d, 0x40]
        )
        let source = SourceResult(
            source: "smc",
            status: .success,
            startedAt: Date(timeIntervalSince1970: 9),
            durationMilliseconds: 4,
            readings: [reading],
            warnings: [],
            error: nil,
            capabilities: [:]
        )
        let sample = ThermalSample(
            index: 0,
            startedAt: Date(timeIntervalSince1970: 9),
            durationMilliseconds: 4,
            sources: [source],
            summaries: []
        )
        let capture = CaptureEnvelope(
            schemaVersion: 1,
            host: HostMetadata(
                osVersion: "27.0",
                osBuild: "26A5378j",
                model: "Mac16,12",
                chip: "Apple M4"
            ),
            invocation: InvocationMetadata(
                arguments: ["--raw"],
                isRoot: true,
                requestedSamples: 1,
                intervalMilliseconds: 1000,
                raw: true
            ),
            samples: [sample],
            aggregates: [],
            warnings: []
        )

        let data = try ProbeJSON.encoder.encode(capture)
        let decoded = try ProbeJSON.decoder.decode(CaptureEnvelope.self, from: data)

        XCTAssertEqual(decoded, capture)
        XCTAssertEqual(decoded.samples[0].sources[0].readings[0].rawBytes, [0x3d, 0x40])
        XCTAssertEqual(
            decoded.samples[0].sources[0].readings[0].metadata["nested"],
            .object(["enabled": .bool(true)])
        )
    }
}
