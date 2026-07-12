import Foundation

public enum DefaultCollectorFactory {
    public static func make(
        commandRunner: any CommandRunning = ProcessCommandRunner()
    ) -> [any ThermalCollector] {
        [
            SMCCollector(),
            HIDCollector(),
            BatteryCollector(),
            ProcessThermalStateCollector(),
            IOReportCollector(),
            PowermetricsCollector(runner: commandRunner),
            PMSetCollector(runner: commandRunner),
            IORegistryThermalCollector(),
            CapabilityProbeCollector(
                source: "sysctl",
                executable: "/usr/sbin/sysctl",
                arguments: ["-a"],
                format: .keyValue,
                runner: commandRunner
            ),
            CapabilityProbeCollector(
                source: "systemProfiler",
                executable: "/usr/sbin/system_profiler",
                arguments: ["SPPowerDataType", "-json"],
                format: .json,
                runner: commandRunner
            )
        ]
    }
}
