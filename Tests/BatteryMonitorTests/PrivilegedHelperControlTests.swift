import XCTest
@testable import BatteryMonitor

final class PrivilegedHelperControlTests: XCTestCase {
    func testEnabledHelperStateShowsRootStartupToggleAsOn() {
        let state = PrivilegedHelperControlState(
            registration: .enabled,
            telemetryStatus: "Active, updated 2s ago"
        )

        XCTAssertTrue(state.isToggleOn)
        XCTAssertEqual(PrivilegedHelperControlState.toggleTitle, "Run as root at startup")
        XCTAssertEqual(state.statusText, "Root helper registered")
        XCTAssertTrue(state.detailText.contains("root LaunchDaemon"))
        XCTAssertTrue(state.detailText.contains("login"))
    }

    func testRequiresApprovalKeepsToggleOnAndSurfacesApproval() {
        let state = PrivilegedHelperControlState(
            registration: .requiresApproval,
            telemetryStatus: "Needs admin approval in System Settings"
        )

        XCTAssertTrue(state.isToggleOn)
        XCTAssertEqual(state.statusText, "Admin approval needed")
        XCTAssertTrue(state.showsApprovalButton)
    }

    func testNotRegisteredHelperStateShowsToggleOff() {
        let state = PrivilegedHelperControlState(
            registration: .notRegistered,
            telemetryStatus: "Not registered"
        )

        XCTAssertFalse(state.isToggleOn)
        XCTAssertEqual(state.statusText, "Root helper off")
        XCTAssertFalse(state.showsApprovalButton)
    }
}
