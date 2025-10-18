// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "BatteryMonitor",
            targets: ["BatteryMonitor"]
        )
    ],
    targets: [
        .executableTarget(
            name: "BatteryMonitor",
            dependencies: [],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ],
            plugins: []
        )
    ]
)
