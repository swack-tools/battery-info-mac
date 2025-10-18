import Foundation

/// Simplified battery information for display in the menu bar app
struct BatteryDisplayInfo {
    // Status
    var percentage: Int = 0
    var statusText: String = "Unknown"
    var timeRemaining: String? = nil
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var powerSource: String = "Unknown"

    // Health
    var condition: String = "Unknown"
    var healthPercentage: Int = 0
    var cycleCount: Int = 0
    var designCycleCount: Int = 1000
    var currentCapacity: Int = 0  // Current charge in mAh
    var fullChargeCapacity: Int = 0  // FCC (max capacity battery can hold now)
    var designCapacity: Int = 0  // Original design capacity
    var temperature: String = "Unknown"

    // Advanced metrics
    var cellVoltages: String? = nil
    var internalResistance: String? = nil
    var manufacturer: String? = nil

    // Charging
    var chargerWattage: String? = nil
    var voltage: String? = nil
    var current: String? = nil

    // USB-C PD
    var pdContract: String? = nil
    var pdVersion: String? = nil

    /// Fetch current battery information from IOKit
    static func fetch() -> BatteryDisplayInfo {
        var info = BatteryDisplayInfo()

        // Get IOKit battery data
        let batteryData = IOKitBattery.getBatteryInfo()
        let chargerData = IOKitBattery.getChargerInfo()
        let systemData = MenuBarSystemInfo()

        // Use computed battery percentage (handles both percentage and mAh cases)
        info.percentage = batteryData.batteryPercentage
        info.currentCapacity = batteryData.currentCapacity
        info.fullChargeCapacity = batteryData.actualMaxCapacityMah

        // Status
        info.isCharging = batteryData.isCharging
        info.isPluggedIn = batteryData.externalConnected

        if info.isCharging {
            info.statusText = "Charging"
            info.powerSource = "AC Power (Charging)"
        } else if info.isPluggedIn {
            if info.percentage >= 100 {
                info.statusText = "Fully Charged"
            } else {
                info.statusText = "Plugged In"
            }
            info.powerSource = "AC Power"
        } else {
            info.statusText = "On Battery"
            info.powerSource = "Battery"
        }

        // Time remaining
        if let timeToEmpty = batteryData.avgTimeToEmpty, timeToEmpty > 0, !info.isPluggedIn {
            let hours = timeToEmpty / 60
            let minutes = timeToEmpty % 60
            info.timeRemaining = String(format: "%d:%02d remaining", hours, minutes)
        } else if let timeToFull = batteryData.timeToFull, timeToFull > 0, info.isCharging {
            let hours = timeToFull / 60
            let minutes = timeToFull % 60
            info.timeRemaining = String(format: "%d:%02d until full", hours, minutes)
        }

        // Health
        info.cycleCount = batteryData.cycleCount
        info.designCycleCount = batteryData.designCycleCount
        info.designCapacity = batteryData.designCapacity

        // Calculate health percentage from actualMaxCapacityMah
        let fcc = batteryData.actualMaxCapacityMah
        let designCap = batteryData.designCapacity

        if designCap > 0 && fcc > 0 {
            info.healthPercentage = Int((Double(fcc) / Double(designCap)) * 100.0)
        }

        // Condition
        info.condition = batteryData.condition

        // Temperature (already in Celsius from IOKitBattery)
        if batteryData.temperature > 0 {
            info.temperature = String(format: "%.1f°C", batteryData.temperature)
        }

        // Advanced metrics
        if let v1 = batteryData.cellVoltage1,
           let v2 = batteryData.cellVoltage2,
           let v3 = batteryData.cellVoltage3 {
            info.cellVoltages = String(format: "%.0fmV, %.0fmV, %.0fmV", v1, v2, v3)
        }

        if let resistance = batteryData.internalResistance {
            info.internalResistance = String(format: "%.1f mΩ", resistance)
        }

        info.manufacturer = batteryData.manufacturer

        // Charging info
        if info.isPluggedIn, let charger = chargerData {
            // Get charger wattage
            if charger.adapterWattage > 0 {
                info.chargerWattage = "\(charger.adapterWattage)W"
            } else if let profilerData = systemData.chargerInfo {
                if let wattage = profilerData["Wattage"] as? Int {
                    info.chargerWattage = "\(wattage)W"
                } else if let wattageStr = profilerData["Wattage"] as? String {
                    info.chargerWattage = wattageStr
                }
            }

            // Get voltage and current from charger data
            if let voltage = charger.profileVoltage {
                info.voltage = String(format: "%.2f", voltage)
            }

            if let current = charger.profileCurrent {
                info.current = String(format: "%.2f", current)
            }

            // USB-C PD contract
            if let voltage = charger.profileVoltage,
               let current = charger.profileCurrent {
                let power = voltage * current
                info.pdContract = String(format: "%.1fV @ %.2fA (%.0fW)", voltage, current, power)
            }

            // PD version from USB PD spec (we'd need to get this from USBCPDInfo)
            if let pdSpec = charger.usbPDVersion {
                info.pdVersion = pdSpec
            }
        }

        return info
    }
}

/// System information helper for menu bar app
struct MenuBarSystemInfo {
    var chargerInfo: [String: Any]?

    init() {
        // Get charger info from system_profiler
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPPowerDataType", "-json"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let powerDataType = json["SPPowerDataType"] as? [[String: Any]],
               let firstEntry = powerDataType.first,
               let acCharger = firstEntry["sppower_ac_charger_information"] as? [String: Any] {
                self.chargerInfo = acCharger
            }
        } catch {
            // Silently fail
        }
    }
}
