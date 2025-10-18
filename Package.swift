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
        ),
        .executable(
            name: "BatteryMonitorCLI",
            targets: ["BatteryMonitorCLI"]
        )
    ],
    targets: [
        // GUI Menu Bar App
        .executableTarget(
            name: "BatteryMonitor",
            dependencies: [],
            exclude: ["main_cli.swift"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        // CLI Tool
        .executableTarget(
            name: "BatteryMonitorCLI",
            dependencies: [],
            path: "Sources/BatteryMonitorCLI",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
