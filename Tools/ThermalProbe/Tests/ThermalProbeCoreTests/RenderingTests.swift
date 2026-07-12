import Foundation
import XCTest
@testable import ThermalProbeCore

final class RenderingTests: XCTestCase {
    func testJSONLHasSampleRecordsAndFinalSummaryRecord() throws {
        var capture = ThermalFixtures.capture(sampleCount: 2)
        capture.aggregates = CaptureAggregator.aggregate(capture.samples)

        let lines = try JSONLinesRenderer.render(capture: capture).split(separator: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(
            try ProbeJSON.decoder.decode(StreamRecord.self, from: Data(lines[0].utf8)).tag,
            .sample
        )
        XCTAssertEqual(
            try ProbeJSON.decoder.decode(StreamRecord.self, from: Data(lines[2].utf8)).tag,
            .summary
        )
    }

    func testHumanOutputIncludesSourceStatusAndNativeIdentifier() {
        let output = HumanRenderer.render(capture: ThermalFixtures.capture(sampleCount: 1))

        XCTAssertTrue(output.contains("macOS 27.0 (26A5378j)"))
        XCTAssertTrue(output.contains("smc"))
        XCTAssertTrue(output.contains("success"))
        XCTAssertTrue(output.contains("Tp01"))
        XCTAssertTrue(output.contains("40.00 C"))
    }

    func testJSONRendererProducesDecodableCapture() throws {
        let capture = ThermalFixtures.capture(sampleCount: 1)
        let data = try JSONRenderer.render(capture: capture)

        XCTAssertEqual(try ProbeJSON.decoder.decode(CaptureEnvelope.self, from: data), capture)
    }

    func testHumanOutputRendersUnitlessNumericRawContext() {
        var capture = ThermalFixtures.capture(sampleCount: 1)
        capture.samples[0].sources[0].readings[0].kind = .rawContext
        capture.samples[0].sources[0].readings[0].unit = nil

        let output = HumanRenderer.render(capture: capture)

        XCTAssertTrue(output.contains("Tp01"))
        XCTAssertTrue(output.contains("40.00"))
    }
}
