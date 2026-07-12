// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThermalProbe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "thermal-probe", targets: ["ThermalProbe"])
    ],
    targets: [
        .target(
            name: "CThermalProbeShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "ThermalProbeCore",
            dependencies: ["CThermalProbeShim"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(name: "ThermalProbe", dependencies: ["ThermalProbeCore"]),
        .testTarget(name: "ThermalProbeCoreTests", dependencies: ["ThermalProbeCore"])
    ],
    swiftLanguageVersions: [.v5]
)
