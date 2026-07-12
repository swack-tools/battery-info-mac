import XCTest
@testable import BatteryMonitor

final class BatteryThroughputTests: XCTestCase {
    func testCatalogReturnsVerifiedM4AirCapacity() {
        XCTAssertEqual(BatterySpecificationCatalog.ratedWattHours(for: "Mac16,12"), 53.8)
    }

    func testCatalogReturnsNilForUnknownModel() {
        XCTAssertNil(BatterySpecificationCatalog.ratedWattHours(for: "UnknownMac1,1"))
    }

    func testEstimatorCalculatesCycleEquivalentKilowattHours() throws {
        let result = try XCTUnwrap(BatteryThroughputEstimator.kilowattHours(
            cycleCount: 311,
            modelIdentifier: "Mac16,12"
        ))

        XCTAssertEqual(result, 16.7318, accuracy: 0.000_001)
    }

    func testEstimatorRejectsNonpositiveCyclesAndUnknownModels() {
        XCTAssertNil(BatteryThroughputEstimator.kilowattHours(
            cycleCount: 0,
            modelIdentifier: "Mac16,12"
        ))
        XCTAssertNil(BatteryThroughputEstimator.kilowattHours(
            cycleCount: -1,
            modelIdentifier: "Mac16,12"
        ))
        XCTAssertNil(BatteryThroughputEstimator.kilowattHours(
            cycleCount: 311,
            modelIdentifier: "UnknownMac1,1"
        ))
    }

    func testDisplayFormatsKnownModelThroughput() {
        XCTAssertEqual(
            BatteryDisplayInfo.estimatedBatteryThroughputText(
                cycleCount: 311,
                modelIdentifier: "Mac16,12"
            ),
            "~16.7 kWh"
        )
    }

    func testDisplayOmitsUnknownModelThroughput() {
        XCTAssertNil(BatteryDisplayInfo.estimatedBatteryThroughputText(
            cycleCount: 311,
            modelIdentifier: "UnknownMac1,1"
        ))
    }
}
