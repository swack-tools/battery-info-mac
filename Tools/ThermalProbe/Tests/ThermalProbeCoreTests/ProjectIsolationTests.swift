import Foundation
import XCTest

final class ProjectIsolationTests: XCTestCase {
    private var toolRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryRoot: URL {
        toolRoot.deletingLastPathComponent().deletingLastPathComponent()
    }

    func testProductionPackageDoesNotReferenceThermalProbe() throws {
        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(package.contains("ThermalProbe"))
    }

    func testStandaloneToolIncludesDocumentationAndValidationLoad() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("README.md").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: toolRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: toolRoot.appendingPathComponent("Validation/ThermalLoad.swift").path
            )
        )
    }
}
