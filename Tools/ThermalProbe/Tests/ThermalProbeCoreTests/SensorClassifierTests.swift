import XCTest
@testable import ThermalProbeCore

final class SensorClassifierTests: XCTestCase {
    func testClassifiesKnownM4CPUAndGPUKeys() {
        let efficiency = SensorClassifier.classifySMC(key: "Te05")
        XCTAssertEqual(efficiency.label, "CPU efficiency core 1")
        XCTAssertEqual(efficiency.category, .cpu)
        XCTAssertEqual(efficiency.classification, .known)

        let performance = SensorClassifier.classifySMC(key: "Tp0e")
        XCTAssertEqual(performance.label, "CPU performance core 8")
        XCTAssertEqual(performance.category, .cpu)
        XCTAssertEqual(performance.classification, .known)

        let gpu = SensorClassifier.classifySMC(key: "Tg0G")
        XCTAssertEqual(gpu.label, "GPU 1")
        XCTAssertEqual(gpu.category, .gpu)
        XCTAssertEqual(gpu.classification, .known)
    }

    func testClassifiesKnownBatteryAndMemoryKeys() {
        XCTAssertEqual(SensorClassifier.classifySMC(key: "TB0T").category, .battery)
        XCTAssertEqual(SensorClassifier.classifySMC(key: "TB0T").classification, .known)
        XCTAssertEqual(SensorClassifier.classifySMC(key: "Tm1p").category, .memory)
        XCTAssertEqual(SensorClassifier.classifySMC(key: "Tm1p").classification, .known)
    }

    func testPrefixOnlyTemperatureGuessRemainsHeuristic() {
        let cpu = SensorClassifier.classifySMC(key: "TpZZ")
        XCTAssertNil(cpu.label)
        XCTAssertEqual(cpu.category, .cpu)
        XCTAssertEqual(cpu.kind, .temperature)
        XCTAssertEqual(cpu.classification, .heuristic)

        let unknown = SensorClassifier.classifySMC(key: "Tzzz")
        XCTAssertEqual(unknown.category, .unknown)
        XCTAssertEqual(unknown.classification, .heuristic)
    }

    func testNonTemperatureKeyRemainsRawAndUnclassified() {
        let classification = SensorClassifier.classifySMC(key: "PSTR")
        XCTAssertEqual(classification.kind, .rawContext)
        XCTAssertEqual(classification.classification, .unclassified)
    }
}
