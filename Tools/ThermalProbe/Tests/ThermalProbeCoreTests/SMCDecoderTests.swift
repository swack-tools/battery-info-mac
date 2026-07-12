import XCTest
@testable import ThermalProbeCore

final class SMCDecoderTests: XCTestCase {
    func testDecodesSignedSP78AndLittleEndianFloat() throws {
        XCTAssertEqual(
            try XCTUnwrap(SMCDecoder.decode(type: "sp78", bytes: [0x2a, 0x80])),
            42.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SMCDecoder.decode(type: "sp78", bytes: [0xff, 0x00])),
            -1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SMCDecoder.decode(type: "flt ", bytes: [0x00, 0x00, 0x28, 0x42])),
            42,
            accuracy: 0.001
        )
    }

    func testDecodesIntegerAndFixedPointFamilies() throws {
        XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "ui8 ", bytes: [0x2a])), 42)
        XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "ui16", bytes: [0x01, 0x02])), 258)
        XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "ui32", bytes: [0, 0, 1, 2])), 258)
        XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "si16", bytes: [0xff, 0xfe])), -2)
        XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "fpe2", bytes: [0x01, 0x00])), 64)
        XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "sp5a", bytes: [0x04, 0x00])), 1)
    }

    func testUnsupportedTypeReturnsNil() throws {
        XCTAssertNil(try SMCDecoder.decode(type: "ch8*", bytes: [1, 2, 3, 4]))
    }

    func testShortBufferThrowsInsteadOfReadingPastEnd() {
        XCTAssertThrowsError(try SMCDecoder.decode(type: "ui32", bytes: [0, 1])) { error in
            XCTAssertEqual(error as? SMCDecodeError, .insufficientBytes(expected: 4, actual: 2))
        }
    }

    func testNonFiniteFloatThrows() {
        XCTAssertThrowsError(try SMCDecoder.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f])) { error in
            XCTAssertEqual(error as? SMCDecodeError, .nonFiniteValue)
        }
    }
}
