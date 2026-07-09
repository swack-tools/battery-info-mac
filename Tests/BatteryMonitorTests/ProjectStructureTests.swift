import Foundation
import XCTest

final class ProjectStructureTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageIsMenuAppOnlyWithPrivilegedHelper() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(package.contains("BatteryMonitorPrivilegedHelper"))
        XCTAssertTrue(package.contains("BatteryMonitorShared"))
        XCTAssertFalse(package.contains("BatteryMonitorCLI"))
    }

    func testCliAndScriptSurfacesAreRemoved() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Sources/BatteryMonitorCLI").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Sources/BatteryMonitor/main_cli.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("python/power_info.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("scripts").path))
    }

    func testReleaseWorkflowDoesNotPublishCliArtifact() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"))

        XCTAssertFalse(workflow.contains("BatteryMonitorCLI"))
        XCTAssertFalse(workflow.contains("scripts/publish_release.sh"))
    }

    func testLaunchDaemonPlistIsBundled() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist").path))
    }
}
