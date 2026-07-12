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
            name: "BatteryMonitorPrivilegedHelper",
            targets: ["BatteryMonitorPrivilegedHelper"]
        )
    ],
    targets: [
        .target(
            name: "BatteryMonitorShared"
        ),
        .target(
            name: "BatteryMonitorThermal",
            dependencies: ["BatteryMonitorShared"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        // GUI Menu Bar App
        .executableTarget(
            name: "BatteryMonitor",
            dependencies: ["BatteryMonitorShared"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "BatteryMonitorPrivilegedHelper",
            dependencies: ["BatteryMonitorShared", "BatteryMonitorThermal"]
        ),
        .testTarget(
            name: "BatteryMonitorTests",
            dependencies: ["BatteryMonitor", "BatteryMonitorShared", "BatteryMonitorThermal"]
        )
    ]
)
