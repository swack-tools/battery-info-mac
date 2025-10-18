import Foundation

// MARK: - System Command Wrappers

class SystemCommands {

    /// Execute a shell command and return the output
    static func runCommand(_ command: String, arguments: [String] = []) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - System Profiler

    /// Get charger/power adapter information from system_profiler
    static func getChargerInfo() -> ChargerData? {
        guard let output = runCommand("/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"]),
              let data = output.data(using: .utf8) else {
            return nil
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let spPowerDataType = json["SPPowerDataType"] as? [[String: Any]],
               let powerInfo = spPowerDataType.first,
               let acCharger = powerInfo["sppower_ac_charger_information"] as? [String: Any] {

                var charger = ChargerData()

                // Adapter ID
                if let adapterId = acCharger["sppower_charger_id"] as? String,
                   let id = Int(adapterId, radix: 16) {
                    charger.adapterID = id
                }

                // Adapter wattage
                if let wattage = acCharger["sppower_charger_watts"] as? Int {
                    charger.adapterWattage = wattage
                } else if let wattageStr = acCharger["sppower_charger_watts"] as? String,
                          let wattage = Int(wattageStr) {
                    charger.adapterWattage = wattage
                }

                // Adapter family
                if let family = acCharger["sppower_charger_family"] as? String {
                    charger.adapterFamily = family
                    charger.adapterName = decodeAdapterFamily(family)
                }

                // Adapter serial
                if let serial = acCharger["sppower_charger_serial_number"] as? String {
                    charger.adapterSerial = serial
                }

                // Charging status
                if let charging = acCharger["sppower_battery_is_charging"] as? String {
                    charger.isCharging = charging.lowercased() == "yes" || charging.lowercased() == "true"
                } else if let charging = acCharger["sppower_battery_is_charging"] as? Bool {
                    charger.isCharging = charging
                }

                return charger
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Get battery firmware version, device name, and condition from system_profiler
    static func getBatteryDetailsFromSystemProfiler() -> (firmwareVersion: String?, deviceName: String?, condition: String?)? {
        guard let output = runCommand("/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"]),
              let data = output.data(using: .utf8) else {
            return nil
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let spPowerDataType = json["SPPowerDataType"] as? [[String: Any]],
               let powerInfo = spPowerDataType.first {

                var firmwareVersion: String? = nil
                var deviceName: String? = nil
                var condition: String? = nil

                // Get firmware and device name from model info
                if let batteryModelInfo = powerInfo["sppower_battery_model_info"] as? [String: Any] {
                    firmwareVersion = batteryModelInfo["sppower_battery_firmware_version"] as? String
                    deviceName = batteryModelInfo["sppower_battery_device_name"] as? String
                }

                // Get condition from health info and map to text output format
                if let healthInfo = powerInfo["sppower_battery_health_info"] as? [String: Any],
                   let health = healthInfo["sppower_battery_health"] as? String {
                    // Map JSON values to text output values (matching Python parser)
                    switch health {
                    case "Good":
                        condition = "Normal"
                    case "Fair":
                        condition = "Replace Soon"
                    case "Poor", "Check Battery":
                        condition = "Service Battery"
                    default:
                        condition = health
                    }
                }

                return (firmwareVersion, deviceName, condition)
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Get system hardware information
    static func getSystemInfo() -> SystemInfo {
        var info = SystemInfo()

        // Get from system_profiler
        if let output = runCommand("/usr/sbin/system_profiler", arguments: ["SPHardwareDataType", "-json"]),
           let data = output.data(using: .utf8) {

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let spHardwareDataType = json["SPHardwareDataType"] as? [[String: Any]],
                   let hardware = spHardwareDataType.first {

                    // Mac model
                    if let model = hardware["machine_model"] as? String {
                        info.macModel = model
                    }

                    // Chip model
                    if let chip = hardware["chip_type"] as? String {
                        info.chipModel = chip
                    }

                    // RAM
                    if let ram = hardware["physical_memory"] as? String {
                        // Parse "32 GB" to 32
                        let components = ram.components(separatedBy: " ")
                        if let value = Int(components[0]) {
                            info.ramGB = value
                        }
                    }

                    // CPU cores
                    if let cores = hardware["number_processors"] as? String {
                        // Parse "1 (10 cores)" or just "10"
                        if let match = cores.range(of: "\\d+", options: .regularExpression) {
                            if let value = Int(cores[match]) {
                                info.cpuCores = value
                            }
                        }
                    }
                }
            } catch {
                // Fallback to defaults
            }
        }

        // Get CPU cores from sysctl if not available
        if info.cpuCores == 0 {
            if let output = runCommand("/usr/sbin/sysctl", arguments: ["-n", "hw.physicalcpu"]),
               let cores = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                info.cpuCores = cores
            }
        }

        return info
    }

    // MARK: - pmset

    /// Get battery status from pmset
    static func getPmsetInfo() -> [String: Any]? {
        guard let output = runCommand("/usr/bin/pmset", arguments: ["-g", "batt"]) else {
            return nil
        }

        var result: [String: Any] = [:]

        // Parse pmset output
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("InternalBattery") {
                // Parse: "InternalBattery-0 (id=12345678)	100%; charged; 0:00 remaining present: true"
                if line.contains("charged") {
                    result["isCharged"] = true
                }
                if line.contains("charging") {
                    result["isCharging"] = true
                }
                if line.contains("discharging") {
                    result["isCharging"] = false
                }

                // Extract percentage
                if let range = line.range(of: "\\d+%", options: .regularExpression) {
                    let percentStr = line[range].dropLast()  // Remove %
                    if let percent = Int(percentStr) {
                        result["percentage"] = percent
                    }
                }
            }
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - powermetrics (requires sudo)

    /// Get power metrics from powermetrics (requires root/sudo)
    static func getPowerMetrics() -> PowerMetrics? {
        // Check if running as root
        guard getuid() == 0 else {
            return nil
        }

        guard let output = runCommand("/usr/bin/powermetrics", arguments: [
            "--samplers", "cpu_power,gpu_power",
            "-n", "1",
            "-i", "1000"
        ]) else {
            return nil
        }

        var metrics = PowerMetrics()

        // Parse powermetrics output
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // CPU Power: 123 mW
            if trimmed.contains("CPU Power:") {
                if let match = trimmed.range(of: "\\d+", options: .regularExpression),
                   let value = Double(trimmed[match]) {
                    metrics.cpuPower = value / 1000.0  // mW to W
                }
            }

            // GPU Power: 456 mW
            if trimmed.contains("GPU Power:") {
                if let match = trimmed.range(of: "\\d+", options: .regularExpression),
                   let value = Double(trimmed[match]) {
                    metrics.gpuPower = value / 1000.0  // mW to W
                }
            }

            // ANE Power: 789 mW
            if trimmed.contains("ANE Power:") {
                if let match = trimmed.range(of: "\\d+", options: .regularExpression),
                   let value = Double(trimmed[match]) {
                    metrics.anePower = value / 1000.0  // mW to W
                }
            }

            // DRAM Power: 321 mW
            if trimmed.contains("DRAM Power:") {
                if let match = trimmed.range(of: "\\d+", options: .regularExpression),
                   let value = Double(trimmed[match]) {
                    metrics.dramPower = value / 1000.0  // mW to W
                }
            }
        }

        metrics.totalSystemPower = metrics.cpuPower + metrics.gpuPower + metrics.anePower + metrics.dramPower

        // Get thermal pressure
        if let thermalOutput = runCommand("/usr/bin/pmset", arguments: ["-g", "therm"]) {
            if thermalOutput.contains("No thermal warning level") {
                metrics.thermalPressure = "Nominal"
            } else if thermalOutput.contains("light") {
                metrics.thermalPressure = "Light"
            } else if thermalOutput.contains("moderate") {
                metrics.thermalPressure = "Moderate"
            } else if thermalOutput.contains("heavy") {
                metrics.thermalPressure = "Heavy"
            }
        }

        return metrics
    }

    /// Enrich power metrics with battery data for power flow calculations
    static func enrichPowerMetrics(_ metrics: inout PowerMetrics, battery: BatteryData) {
        // Calculate battery power (negative when discharging)
        metrics.batteryPower = battery.voltage * battery.amperage / 1000.0  // W

        // If charging, adapter power in = battery power + system load
        // If discharging, system load = -battery power
        if battery.isCharging {
            // Estimate adapter power (battery charging + system consumption)
            metrics.systemLoad = metrics.totalSystemPower
            metrics.adapterPowerIn = abs(metrics.batteryPower) + metrics.systemLoad
        } else {
            // Discharging: all power from battery
            metrics.systemLoad = abs(metrics.batteryPower)
            metrics.adapterPowerIn = 0.0
        }

        // Estimate display power from brightness
        // Typical MacBook display: ~6W at 100%, scales linearly
        let estimatedDisplayBrightness = 50.0  // Default estimate
        metrics.displayPower = (estimatedDisplayBrightness / 100.0) * 6.0  // W

        // Calculate "other components" power
        let measuredComponents = metrics.cpuPower + metrics.gpuPower + metrics.anePower + metrics.dramPower
        let displayPower = metrics.displayPower ?? 0.0
        metrics.otherComponentsPower = max(0, metrics.systemLoad - measuredComponents - displayPower)
    }

    // MARK: - Decoders

    /// Decode adapter family code to human-readable name
    private static func decodeAdapterFamily(_ family: String) -> String {
        // Parse hex family code (e.g., "0xe0008d03")
        guard let familyValue = UInt32(family.dropFirst(2), radix: 16) else {
            return "Unknown Adapter"
        }

        let highByte = (familyValue >> 24) & 0xFF

        // Known Apple chargers
        let knownChargers: [UInt32: String] = [
            0xe0008d03: "Apple 140W USB-C Power Adapter",
            0xe0008c03: "Apple 96W USB-C Power Adapter",
            0xe0008b03: "Apple 87W USB-C Power Adapter",
            0xe0008a03: "Apple 61W USB-C Power Adapter",
            0xe0008903: "Apple 30W USB-C Power Adapter",
            0xe0008803: "Apple 29W USB-C Power Adapter"
        ]

        if let name = knownChargers[familyValue] {
            return name
        }

        // Generic identification
        if highByte == 0xe0 {
            return "USB-C Power Delivery Adapter"
        } else {
            return "Legacy Power Adapter"
        }
    }
}

// MARK: - Health Scoring

extension SystemCommands {

    /// Calculate battery health score (0-100)
    static func calculateHealthScore(battery: BatteryData) -> BatteryHealthScore {
        var totalScore = 0.0
        var factors: [String] = []

        // Factor 1: Capacity health (40% weight)
        let capacityScore = battery.healthPercent
        totalScore += Double(capacityScore) * 0.4
        factors.append("Capacity: \(capacityScore)%")

        // Factor 2: Cycle count (30% weight)
        let cycleScore: Int
        if battery.cycleCount < 100 {
            cycleScore = 100
        } else if battery.cycleCount < 300 {
            cycleScore = 90
        } else if battery.cycleCount < 500 {
            cycleScore = 80
        } else if battery.cycleCount < 800 {
            cycleScore = 60
        } else {
            cycleScore = 40
        }
        totalScore += Double(cycleScore) * 0.3
        factors.append("Cycle Life: \(100 - (battery.cycleCount * 100 / 1000))%")

        // Factor 3: Cell balance (20% weight)
        if let imbalance = battery.cellVoltageImbalance {
            let balanceScore: Int
            if imbalance < 10 {  // < 10mV
                balanceScore = 100
            } else if imbalance < 50 {
                balanceScore = 80
            } else {
                balanceScore = 50
            }
            totalScore += Double(balanceScore) * 0.2
            factors.append("Cell Balance: \(Int(imbalance))mV")
        } else {
            totalScore += 100.0 * 0.2
        }

        // Factor 4: Internal resistance (10% weight)
        if let resistance = battery.internalResistance {
            let resistanceScore: Int
            if resistance < 80 {
                resistanceScore = 100
            } else if resistance < 120 {
                resistanceScore = 90
            } else if resistance < 180 {
                resistanceScore = 70
            } else {
                resistanceScore = max(40, Int(40.0 - (resistance - 180.0) / 10.0))
            }
            totalScore += Double(resistanceScore) * 0.1
            factors.append("Resistance: \(String(format: "%.1f", resistance))mΩ")
        } else {
            totalScore += 100.0 * 0.1
        }

        let score = Int(totalScore)

        // Grade and description
        let (grade, description): (String, String)
        if score >= 95 {
            (grade, description) = ("A+", "Excellent")
        } else if score >= 85 {
            (grade, description) = ("A", "Very Good")
        } else if score >= 75 {
            (grade, description) = ("B", "Good")
        } else if score >= 60 {
            (grade, description) = ("C", "Fair")
        } else {
            (grade, description) = ("D", "Poor")
        }

        return BatteryHealthScore(
            score: score,
            grade: grade,
            description: description,
            factors: factors
        )
    }
}
