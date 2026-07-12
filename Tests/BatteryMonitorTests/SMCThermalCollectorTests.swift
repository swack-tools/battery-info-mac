import Foundation
import XCTest
import BatteryMonitorShared
@testable import BatteryMonitorThermal

final class SMCThermalCollectorTests: XCTestCase {
    func testSMCStructsMatchCLayouts() {
        assertLayout(SMCVersion.self, size: 6, stride: 6, alignment: 2)
        assertLayout(SMCPowerLimit.self, size: 16, stride: 16, alignment: 4)
        assertLayout(SMCKeyInfo.self, size: 12, stride: 12, alignment: 4)
        assertLayout(SMCKeyData.self, size: 80, stride: 80, alignment: 4)

        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.key), 0)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.version), 4)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.powerLimit), 12)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.result), 40)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.status), 41)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.bytes), 48)
    }

    func testFourCCConvertsInBothDirections() throws {
        let value = try SMCFourCC.value(from: "Tp01")

        XCTAssertEqual(value, 0x5470_3031)
        XCTAssertEqual(SMCFourCC.string(from: value), "Tp01")
        XCTAssertThrowsError(try SMCFourCC.value(from: "CPU"))
        XCTAssertThrowsError(try SMCFourCC.value(from: "ABCDE"))
    }

    func testReadBytesRequestRejectsSizesOutsideFixedBufferBeforeCommandFive() {
        for dataSize: UInt32 in [0, 33, .max] {
            XCTAssertThrowsError(
                try SMCReadBytesRequest.make(key: 0x5470_3031, dataSize: dataSize),
                "data size \(dataSize)"
            )
        }
    }

    func testReadBytesRequestAcceptsFixedBufferBounds() throws {
        for dataSize: UInt32 in [1, 32] {
            let request = try SMCReadBytesRequest.make(key: 0x5470_3031, dataSize: dataSize)

            XCTAssertEqual(request.key, 0x5470_3031)
            XCTAssertEqual(request.keyInfo.dataSize, dataSize)
            XCTAssertEqual(request.data8, 5)
        }
    }

    func testOutputSizeValidatorRequiresExactSMCKeyDataSize() throws {
        let expected = MemoryLayout<SMCKeyData>.size

        for outputSize in [0, expected - 1, expected + 1] {
            XCTAssertThrowsError(
                try SMCOutputSizeValidator.validate(outputSize),
                "output size \(outputSize)"
            )
        }
        XCTAssertNoThrow(try SMCOutputSizeValidator.validate(expected))
    }

    func testDecoderHandlesSignedAndUnsignedFixedPoint() throws {
        XCTAssertEqual(try SMCDecoder.decode(type: "sp78", bytes: [0x36, 0x80]), 54.5)
        XCTAssertEqual(try SMCDecoder.decode(type: "sp78", bytes: [0xff, 0x80]), -0.5)
        XCTAssertEqual(try SMCDecoder.decode(type: "fp88", bytes: [0x01, 0x80]), 1.5)
    }

    func testDecoderRejectsMalformedOrInvalidFixedPointDescriptors() throws {
        for type in ["spx8", "sp7x", "sp88", "fp78"] {
            XCTAssertNil(try SMCDecoder.decode(type: type, bytes: [0x01, 0x80]), type)
        }
    }

    func testDecoderHandlesFloatAndIntegerTypes() throws {
        XCTAssertEqual(try SMCDecoder.decode(type: "flt ", bytes: [0x00, 0x00, 0x52, 0x42]), 52.5)
        XCTAssertEqual(try SMCDecoder.decode(type: "ui8 ", bytes: [0xff]), 255)
        XCTAssertEqual(try SMCDecoder.decode(type: "ui16", bytes: [0x12, 0x34]), 0x1234)
        XCTAssertEqual(try SMCDecoder.decode(type: "ui32", bytes: [0x12, 0x34, 0x56, 0x78]), 0x1234_5678)
        XCTAssertEqual(try SMCDecoder.decode(type: "si8 ", bytes: [0xff]), -1)
        XCTAssertEqual(try SMCDecoder.decode(type: "si16", bytes: [0xff, 0xfe]), -2)
        XCTAssertEqual(try SMCDecoder.decode(type: "si32", bytes: [0xff, 0xff, 0xff, 0xfd]), -3)
        XCTAssertNil(try SMCDecoder.decode(type: "flag", bytes: [1]))
    }

    func testDecoderRejectsInsufficientAndNonfiniteValues() {
        XCTAssertThrowsError(try SMCDecoder.decode(type: "sp78", bytes: [0x36])) { error in
            XCTAssertEqual(error as? SMCDecodeError, .insufficientBytes(expected: 2, actual: 1))
        }
        XCTAssertThrowsError(try SMCDecoder.decode(type: "ui32", bytes: [0, 1, 2])) { error in
            XCTAssertEqual(error as? SMCDecodeError, .insufficientBytes(expected: 4, actual: 3))
        }
        XCTAssertThrowsError(try SMCDecoder.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f])) { error in
            XCTAssertEqual(error as? SMCDecodeError, .nonFiniteValue)
        }
    }

    func testClassifierRecognizesKnownTemperatureKeys() {
        assertClassification("Tp01", label: "CPU performance core 1", category: .cpu)
        assertClassification("Tg0G", label: "GPU 1", category: .gpu)
        assertClassification("TB0T", label: "Battery 1", category: .battery)
        assertClassification("Tm0p", label: "Memory proximity 1", category: .memory)
    }

    func testClassifierUsesTemperatureHeuristicsAndOmitsOtherKeys() {
        let cpu = SMCSensorClassifier.classify(key: "Tf9Z")
        XCTAssertEqual(cpu.category, .cpu)
        XCTAssertEqual(cpu.classification, .heuristic)
        XCTAssertTrue(cpu.isTemperature)

        let unknownTemperature = SMCSensorClassifier.classify(key: "Ts0P")
        XCTAssertEqual(unknownTemperature.category, .unknown)
        XCTAssertEqual(unknownTemperature.classification, .heuristic)
        XCTAssertTrue(unknownTemperature.isTemperature)

        let nonTemperature = SMCSensorClassifier.classify(key: "F0Ac")
        XCTAssertEqual(nonTemperature.classification, .unclassified)
        XCTAssertFalse(nonTemperature.isTemperature)
    }

    func testKnownSMCKeyMapsToCPUReading() throws {
        let raw = SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0x36, 0x80], status: 0)

        let reading = try SMCReadingMapper.map(raw, timestamp: .distantPast)

        XCTAssertEqual(reading?.source, "smc")
        XCTAssertEqual(reading?.identifier, "Tp01")
        XCTAssertEqual(reading?.label, "CPU performance core 1")
        XCTAssertEqual(reading?.category, .cpu)
        XCTAssertEqual(reading?.kind, .temperature)
        XCTAssertEqual(reading?.numericValue, 54.5)
        XCTAssertEqual(reading?.unit, "C")
        XCTAssertEqual(reading?.classification, .known)
        XCTAssertEqual(reading?.warnings, [])
    }

    func testMapperWarnsForImplausibleTemperatureAndSMCStatus() throws {
        let raw = SMCRawRecord(
            key: "Tp01",
            dataType: "flt ",
            data: [0x00, 0x00, 0x17, 0x43],
            status: 7
        )

        let reading = try XCTUnwrap(SMCReadingMapper.map(raw, timestamp: .distantPast))

        XCTAssertEqual(reading.numericValue, 151)
        XCTAssertEqual(reading.warnings, [
            "temperature is outside the -40...150 C plausibility range",
            "SMC returned status 7"
        ])
    }

    func testMapperOmitsDecodedNonTemperatureRecord() throws {
        let raw = SMCRawRecord(key: "F0Ac", dataType: "ui16", data: [0x04, 0xd2], status: 0)

        XCTAssertNil(try SMCReadingMapper.map(raw, timestamp: .distantPast))
    }

    func testMapperOmitsUnsupportedNonTemperatureRecordWithoutError() throws {
        let raw = SMCRawRecord(key: "F0Ac", dataType: "flag", data: [1], status: 0)

        XCTAssertNil(try SMCReadingMapper.map(raw, timestamp: .distantPast))
    }

    func testInjectedProviderCollectsWithoutLiveSMC() {
        let provider = FixtureSMCProvider(records: [
            SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0x36, 0x80], status: 0),
            SMCRawRecord(key: "F0Ac", dataType: "ui16", data: [0x04, 0xd2], status: 0)
        ])

        let result = SMCThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings.map(\.identifier), ["Tp01"])
        XCTAssertEqual(result.status.source, "smc")
        XCTAssertEqual(result.status.state, .success)
        XCTAssertEqual(result.status.readingCount, 1)
        XCTAssertEqual(result.status.scannedRecordCount, 2)
        XCTAssertEqual(result.status.warnings, [])
        XCTAssertNil(result.status.error)
    }

    func testInjectedProviderPreservesDecodeWarningAsPartialStatus() {
        let provider = FixtureSMCProvider(records: [
            SMCRawRecord(key: "Tg0G", dataType: "sp78", data: [0x40], status: 0)
        ])

        let result = SMCThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.status.scannedRecordCount, 1)
        XCTAssertEqual(result.status.warnings.count, 1)
        XCTAssertTrue(result.status.warnings[0].contains("Tg0G"))
    }

    func testInjectedProviderPreservesBatchWarningsAndAttemptedCount() {
        let provider = FixtureSMCProvider(
            records: [
                SMCRawRecord(key: "Tp01", dataType: "sp78", data: [0x36, 0x80], status: 0)
            ],
            attemptedCount: 4,
            warnings: [
                "SMC index 1: index failure",
                "SMC key Tg0G: key failure"
            ]
        )

        let result = SMCThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings.map(\.identifier), ["Tp01"])
        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.status.scannedRecordCount, 4)
        XCTAssertEqual(result.status.warnings, [
            "SMC index 1: index failure",
            "SMC key Tg0G: key failure"
        ])
    }

    func testInjectedProviderWithNoReadableRecordsReturnsBoundedFailedStatus() {
        let warnings = (0..<25).map { "SMC index \($0): index failure" }
        let provider = FixtureSMCProvider(
            records: [],
            attemptedCount: 25,
            warnings: warnings
        )

        let result = SMCThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.readingCount, 0)
        XCTAssertEqual(result.status.scannedRecordCount, 25)
        XCTAssertEqual(result.status.error, "SMC scanned 25 keys but produced no readable records")
        XCTAssertEqual(result.status.warnings.count, 20)
        XCTAssertEqual(result.status.warnings.first, "SMC index 0: index failure")
        XCTAssertEqual(result.status.warnings.last, "6 additional SMC warnings omitted")
    }

    func testUnsupportedTemperatureEncodingProducesKeyedPartialWarning() {
        let provider = FixtureSMCProvider(records: [
            SMCRawRecord(key: "Ts0P", dataType: "flag", data: [1], status: 0)
        ])

        let result = SMCThermalCollector(provider: provider).collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.state, .partial)
        XCTAssertEqual(result.status.scannedRecordCount, 1)
        XCTAssertEqual(result.status.warnings, [
            "Ts0P: unsupported temperature encoding flag"
        ])
    }

    func testInjectedProviderFailureReturnsFailedStatus() {
        let result = SMCThermalCollector(provider: FailingSMCProvider()).collect(at: .distantPast)

        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(result.status.source, "smc")
        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.readingCount, 0)
        XCTAssertEqual(result.status.scannedRecordCount, 0)
        XCTAssertEqual(result.status.error, "fixture failure")
    }

    func testTypedProviderUnavailableFailureReturnsUnavailableStatus() {
        let error = SMCProviderError(
            kind: .unavailable,
            message: "AppleSMC service was not found",
            code: nil
        )

        let result = SMCThermalCollector(provider: TypedFailingSMCProvider(error: error))
            .collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .unavailable)
        XCTAssertEqual(result.status.error, "AppleSMC service was not found")
    }

    func testTypedProviderKernelFailureReturnsFailedStatus() {
        let error = SMCProviderError(
            kind: .failed,
            message: "AppleSMC call failed",
            code: Int32(bitPattern: 0xe000_02bc)
        )

        let result = SMCThermalCollector(provider: TypedFailingSMCProvider(error: error))
            .collect(at: .distantPast)

        XCTAssertEqual(result.status.state, .failed)
        XCTAssertTrue(result.status.error?.contains("AppleSMC call failed") == true)
    }

    private func assertLayout<T>(
        _ type: T.Type,
        size: Int,
        stride: Int,
        alignment: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(MemoryLayout<T>.size, size, file: file, line: line)
        XCTAssertEqual(MemoryLayout<T>.stride, stride, file: file, line: line)
        XCTAssertEqual(MemoryLayout<T>.alignment, alignment, file: file, line: line)
    }

    private func assertClassification(
        _ key: String,
        label: String,
        category: ThermalCategory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let classification = SMCSensorClassifier.classify(key: key)
        XCTAssertEqual(classification.label, label, file: file, line: line)
        XCTAssertEqual(classification.category, category, file: file, line: line)
        XCTAssertEqual(classification.classification, .known, file: file, line: line)
        XCTAssertTrue(classification.isTemperature, file: file, line: line)
    }
}

private struct FixtureSMCProvider: SMCRecordProviding {
    var batch: SMCRecordBatch

    init(
        records: [SMCRawRecord],
        attemptedCount: Int? = nil,
        warnings: [String] = []
    ) {
        batch = SMCRecordBatch(
            records: records,
            attemptedCount: attemptedCount ?? records.count,
            warnings: warnings
        )
    }

    func recordBatch() throws -> SMCRecordBatch {
        batch
    }
}

private struct FailingSMCProvider: SMCRecordProviding {
    func recordBatch() throws -> SMCRecordBatch {
        throw FixtureError.failed
    }
}

private struct TypedFailingSMCProvider: SMCRecordProviding {
    var error: SMCProviderError

    func recordBatch() throws -> SMCRecordBatch {
        throw error
    }
}

private enum FixtureError: Error, CustomStringConvertible {
    case failed

    var description: String { "fixture failure" }
}
