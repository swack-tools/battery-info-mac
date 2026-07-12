// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThermalProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ThermalProbeCore"),
        .testTarget(name: "ThermalProbeCoreTests", dependencies: ["ThermalProbeCore"])
    ],
    swiftLanguageVersions: [.v5]
)
