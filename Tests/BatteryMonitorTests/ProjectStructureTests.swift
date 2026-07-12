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

    func testStandaloneThermalProbeAndCShimAreRemoved() throws {
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent("Tools/ThermalProbe").path
            )
        )
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"))
        XCTAssertTrue(package.contains("BatteryMonitorThermal"))
        XCTAssertFalse(package.contains("CThermalProbeShim"))
    }

    func testReleaseWorkflowDoesNotPublishCliArtifact() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"))

        XCTAssertFalse(workflow.contains("BatteryMonitorCLI"))
        XCTAssertFalse(workflow.contains("scripts/publish_release.sh"))
    }

    func testReleaseWorkflowUsesAvailableHostedMacOSRunner() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"))

        XCTAssertTrue(workflow.contains("runs-on: macos-latest"))
        XCTAssertFalse(workflow.contains("runs-on: macos-26"))
        XCTAssertTrue(workflow.contains("if [[ -d /Applications/Xcode_26.6.app ]]"))
    }

    func testLaunchDaemonPlistIsBundled() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("SupportFiles/LaunchDaemons/com.swacktools.batterymonitor.helper.plist").path))
    }

    func testRootHelperPersistenceToggleIsVisibleInDetailView() throws {
        let view = try String(contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/BatteryDetailView.swift"))
        let manager = try String(contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/PrivilegedHelperManager.swift"))

        XCTAssertTrue(view.contains("RootHelperControlSection(info: dataManager.batteryInfo)"))
        XCTAssertTrue(view.contains("Toggle(PrivilegedHelperControlState.toggleTitle"))
        XCTAssertTrue(manager.contains("Run as root at startup"))
    }

    func testAdvancedThermalsImmediatelyFollowsGeneralThermals() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/BatteryMonitor/BatteryDetailView.swift")
        )
        let general = try XCTUnwrap(source.range(of: "GeneralThermalsSection(info:"))
        let advanced = try XCTUnwrap(source.range(of: "ThermalsAdvancedSection(info:"))

        XCTAssertLessThan(general.lowerBound, advanced.lowerBound)
        XCTAssertTrue(source.contains("struct ThermalsAdvancedSection: View"))
        XCTAssertTrue(source.contains("info.detailedThermalReadings"))
        XCTAssertTrue(source.contains("info.thermalSourceStatuses"))
    }
}
