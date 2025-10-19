import Foundation

/// Comprehensive battery information for display in the menu bar app
struct BatteryDisplayInfo {
    // System Information
    var macModel: String = "Unknown"
    var chipModel: String = "Unknown"
    var ramSize: String = "Unknown"
    var cpuCores: String = "Unknown"

    // Status
    var percentage: Int = 0
    var statusText: String = "Unknown"
    var timeRemaining: String? = nil
    var timeToEmpty: String? = nil
    var timeToFull: String? = nil
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var powerSource: String = "Unknown"

    // Battery Health
    var condition: String = "Unknown"
    var serviceRecommended: Bool = false
    var healthPercentage: Int = 0
    var cycleCount: Int = 0
    var designCycleCount: Int = 1000
    var lifespanUsed: String = "Unknown"
    var currentCapacity: Int = 0  // Current charge in mAh
    var fullChargeCapacity: Int = 0  // FCC (max capacity battery can hold now)
    var designCapacity: Int = 0  // Original design capacity
    var nominalCapacity: Int = 0  // Nominal/rated capacity
    var temperature: String = "Unknown"
    var packReserve: String? = nil
    var atCriticalLevel: Bool = false
    var estimatedCyclesTo80: String? = nil

    // Capacity Analysis
    var capacityAnalysis: [String] = []

    // Cell Diagnostics
    var cellVoltages: String? = nil
    var cellVoltageDelta: String? = nil
    var cellDisconnectCount: Int? = nil
    var rsenseOpenCount: Int? = nil

    // Battery Info
    var manufacturer: String? = nil
    var batteryModel: String? = nil
    var batterySerial: String? = nil
    var manufactureDate: String? = nil
    var chemistry: String? = nil

    // Advanced Diagnostics
    var internalResistance: String? = nil
    var internalResistanceQuality: String? = nil
    var gaugeQmax: String? = nil
    var virtualTemperature: String? = nil
    var bestChargerPort: String? = nil
    var gaugeStatus: String? = nil
    var miscStatus: String? = nil
    var permanentFailure: String? = nil
    var gaugeWriteCount: Int? = nil
    var gaugeSoC: String? = nil
    var dailyChargeRange: String? = nil
    var shippingMode: String? = nil
    var lifetimeEnergy: String? = nil
    var postChargeWait: String? = nil
    var postDischargeWait: String? = nil
    var invalidWakeTime: String? = nil

    // Charging
    var chargerWattage: String? = nil
    var chargerType: String? = nil
    var chargerFamily: String? = nil
    var chargerSerial: String? = nil
    var voltage: String? = nil
    var current: String? = nil
    var power: String? = nil

    // USB-C PD
    var pdContract: String? = nil
    var pdSpecification: String? = nil
    var powerRole: String? = nil
    var dataRole: String? = nil
    var selectedPDO: String? = nil
    var operatingCurrent: String? = nil
    var sourceCapabilities: [String] = []
    var sinkCapabilities: [String] = []

    // Display
    var displayBrightness: String? = nil
    var displayPowerEstimate: String? = nil

    // USB Ports
    var usbWakeCurrent: String? = nil
    var usbSleepCurrent: String? = nil

    // Power Management
    var lowPowerMode: String? = nil
    var hibernationMode: String? = nil
    var wakeOnLAN: String? = nil
    var powerNap: String? = nil
    var displaySleepMinutes: String? = nil
    var activeAssertions: [String] = []
    var powerSourceHistory: [String] = []
    var sleepWakeHistory: [String] = []
    var scheduledEvents: [String] = []

    /// Fetch current battery information from IOKit
    static func fetch() -> BatteryDisplayInfo {
        var info = BatteryDisplayInfo()

        // Get all data sources
        let batteryData = IOKitBattery.getBatteryInfo()
        let chargerData = IOKitBattery.getChargerInfo()
        let systemInfo = SystemCommands.getSystemInfo()
        let usbcInfo = SystemCommands.getUSBCPDInfo()
        let displayInfo = SystemCommands.getDisplayInfo()
        let usbPortInfo = SystemCommands.getUSBPortInfo()
        let powerMgmtInfo = SystemCommands.getPowerManagementInfo()

        // ========== SYSTEM INFORMATION ==========
        info.macModel = systemInfo.macModel
        info.chipModel = systemInfo.chipModel
        info.ramSize = systemInfo.ramGB > 0 ? "\(systemInfo.ramGB) GB" : "Unknown"
        info.cpuCores = systemInfo.cpuCores > 0 ? "\(systemInfo.cpuCores) cores" : "Unknown"

        // ========== BATTERY STATUS ==========
        info.percentage = batteryData.batteryPercentage
        info.currentCapacity = batteryData.currentCapacity
        info.isCharging = batteryData.isCharging
        info.isPluggedIn = batteryData.externalConnected

        if info.isCharging {
            info.statusText = "Charging"
            info.powerSource = "AC Power (Charging)"
        } else if info.isPluggedIn {
            info.statusText = info.percentage >= 100 ? "Fully Charged" : "Plugged In"
            info.powerSource = "AC Power"
        } else {
            info.statusText = "On Battery"
            info.powerSource = "Battery"
        }

        // Time estimates
        if let timeToEmpty = batteryData.avgTimeToEmpty, timeToEmpty > 0, !info.isPluggedIn {
            let hours = timeToEmpty / 60
            let mins = timeToEmpty % 60
            info.timeToEmpty = String(format: "%d hrs %d min (%d min)", hours, mins, timeToEmpty)
            info.timeRemaining = String(format: "%d:%02d remaining", hours, mins)
        }

        if let timeToFull = batteryData.timeToFull, timeToFull > 0, info.isCharging {
            let hours = timeToFull / 60
            let mins = timeToFull % 60
            info.timeToFull = String(format: "%d:%02d until full", hours, mins)
            info.timeRemaining = info.timeToFull
        }

        // ========== BATTERY HEALTH ==========
        info.condition = batteryData.condition
        info.serviceRecommended = batteryData.serviceRecommended
        info.cycleCount = batteryData.cycleCount
        info.designCycleCount = batteryData.designCycleCount
        info.fullChargeCapacity = batteryData.actualMaxCapacityMah
        info.designCapacity = batteryData.designCapacity
        info.nominalCapacity = batteryData.nominalChargeCapacity

        // Calculate health percentage
        if info.designCapacity > 0 && info.fullChargeCapacity > 0 {
            info.healthPercentage = Int((Double(info.fullChargeCapacity) / Double(info.designCapacity)) * 100.0)
        }

        // Lifespan used
        if info.designCycleCount > 0 {
            let percent = (Double(info.cycleCount) / Double(info.designCycleCount)) * 100.0
            info.lifespanUsed = String(format: "%.1f%% (%d / %d cycles)", percent, info.cycleCount, info.designCycleCount)
        }

        // Temperature
        if batteryData.temperature > 0 {
            info.temperature = String(format: "%.1f°C", batteryData.temperature)
        }

        // Pack reserve
        if let reserve = batteryData.packReserve, reserve > 0 {
            info.packReserve = String(format: "%d mAh (reserved)", reserve)
        }

        info.atCriticalLevel = batteryData.atCriticalLevel

        // Estimated cycles to 80%
        if let cycles = batteryData.estimatedCyclesTo80Percent {
            info.estimatedCyclesTo80 = "\(cycles) cycles"
        }

        // Capacity Analysis
        if info.designCapacity > 0 {
            info.capacityAnalysis = [
                String(format: "Design (factory):   %d mAh (100%%)", info.designCapacity)
            ]

            if info.nominalCapacity > 0 {
                let diff = info.nominalCapacity - info.designCapacity
                let pct = (Double(info.nominalCapacity) / Double(info.designCapacity)) * 100.0
                info.capacityAnalysis.append(String(format: "Nominal (rated):    %d mAh (%.1f%%) [%+d mAh]",
                    info.nominalCapacity, pct, diff))
            }

            if info.fullChargeCapacity > 0 {
                let diff = info.fullChargeCapacity - info.designCapacity
                let pct = (Double(info.fullChargeCapacity) / Double(info.designCapacity)) * 100.0
                info.capacityAnalysis.append(String(format: "Current Max (FCC):  %d mAh (%.1f%%) [%+d mAh degradation]",
                    info.fullChargeCapacity, pct, diff))
            }
        }

        // ========== CELL DIAGNOSTICS ==========
        if let v1 = batteryData.cellVoltage1,
           let v2 = batteryData.cellVoltage2,
           let v3 = batteryData.cellVoltage3 {
            info.cellVoltages = String(format: "%.0fmV, %.0fmV, %.0fmV", v1, v2, v3)

            if let delta = batteryData.cellVoltageImbalance {
                info.cellVoltageDelta = String(format: "%.0fmV", delta)
            }
        }

        info.cellDisconnectCount = batteryData.cellDisconnectCount
        info.rsenseOpenCount = batteryData.rsenseOpenCount

        // ========== BATTERY INFO ==========
        info.manufacturer = batteryData.manufacturer
        info.batterySerial = batteryData.serialNumber
        info.manufactureDate = batteryData.manufactureDate
        info.chemistry = batteryData.chemistry

        if let model = batteryData.batteryModel, let rev = batteryData.batteryModelRevision {
            info.batteryModel = "\(model) (rev \(rev))"
        } else if let model = batteryData.batteryModel {
            info.batteryModel = model
        }

        // ========== ADVANCED DIAGNOSTICS ==========
        if let resistance = batteryData.internalResistance {
            info.internalResistance = String(format: "%.1f mΩ", resistance)

            // Quality assessment
            if resistance < 100 {
                info.internalResistanceQuality = "Excellent"
            } else if resistance < 150 {
                info.internalResistanceQuality = "Good"
            } else if resistance < 200 {
                info.internalResistanceQuality = "Fair"
            } else {
                info.internalResistanceQuality = "Poor"
            }
        }

        if let qmax = batteryData.gaugeQmax, qmax > 0, info.fullChargeCapacity > 0 {
            let diff = qmax - info.fullChargeCapacity
            let pct = (Double(abs(diff)) / Double(info.fullChargeCapacity)) * 100.0
            info.gaugeQmax = String(format: "%d mAh (FCC: %d mAh, %.1f%% diff)", qmax, info.fullChargeCapacity, pct)
        }

        if let vTemp = batteryData.virtualTemperature, vTemp > 0, batteryData.temperature > 0 {
            let calc = vTemp - batteryData.temperature
            info.virtualTemperature = String(format: "%.1f°C (calc: %+.1f°C from sensor)", vTemp, calc)
        }

        if let port = batteryData.bestChargerPort {
            info.bestChargerPort = "USB-C Port \(port)"
        }

        // Gauge Status (decoded)
        if let status = batteryData.gaugeStatus {
            info.gaugeStatus = BatteryDecoders.decodeGaugeFlags(status)
        }

        // Misc Status (decoded)
        if let misc = batteryData.miscStatus {
            info.miscStatus = BatteryDecoders.decodeMiscStatus(misc)
        }

        // Permanent Failure (decoded)
        if let failure = batteryData.permanentFailureStatus {
            info.permanentFailure = BatteryDecoders.decodePermanentFailure(failure)
        }

        info.gaugeWriteCount = batteryData.gaugeWriteCount

        if let soc = batteryData.gaugeSoC {
            info.gaugeSoC = "\(soc)%"
        }

        if let min = batteryData.dailyChargeMin, let max = batteryData.dailyChargeMax {
            info.dailyChargeRange = "\(min)% - \(max)%"
        }

        if batteryData.shippingModeActive {
            if let vMin = batteryData.shippingModeVoltageMin, let vMax = batteryData.shippingModeVoltageMax {
                info.shippingMode = String(format: "Active (range: %.1fV - %.1fV)", vMin, vMax)
            } else {
                info.shippingMode = "Active"
            }
        } else {
            if let vMin = batteryData.shippingModeVoltageMin, let vMax = batteryData.shippingModeVoltageMax {
                info.shippingMode = String(format: "Disabled (range: %.1fV - %.1fV)", vMin, vMax)
            } else {
                info.shippingMode = "Disabled"
            }
        }

        if let energy = batteryData.lifetimeEnergyKWh {
            info.lifetimeEnergy = String(format: "~%.1f kWh (est)", energy)
        }

        if let wait = batteryData.postChargeWaitSeconds {
            info.postChargeWait = String(format: "%d min (%ds)", wait / 60, wait)
        }

        if let wait = batteryData.postDischargeWaitSeconds {
            info.postDischargeWait = String(format: "%d min (%ds)", wait / 60, wait)
        }

        if let wake = batteryData.invalidWakeSeconds {
            info.invalidWakeTime = String(format: "%d sec (%ds)", wake, wake)
        }

        // ========== CHARGING INFO ==========
        if let charger = chargerData {
            if charger.adapterWattage > 0 {
                info.chargerWattage = "\(charger.adapterWattage)W"
            }

            info.chargerType = charger.chargingType
            info.chargerSerial = charger.adapterSerial

            // Charger family (from name or family code)
            if let family = charger.adapterFamily {
                info.chargerFamily = family
            }

            if let voltage = charger.profileVoltage {
                info.voltage = String(format: "%.2fV", voltage)
            }

            if let current = charger.profileCurrent {
                info.current = String(format: "%.2fA", current)
            }

            if let voltage = charger.profileVoltage, let current = charger.profileCurrent {
                let power = voltage * current
                info.power = String(format: "%.1fW", power)
                info.pdContract = String(format: "%.2f V @ %.2f A (%.0f W)", voltage, current, power)
            }
        }

        // ========== USB-C PD INFO ==========
        if let usbc = usbcInfo {
            info.pdSpecification = usbc.pdSpecification
            info.powerRole = usbc.powerRole
            info.dataRole = usbc.dataRole

            if let pdo = usbc.selectedPDO {
                info.selectedPDO = "PDO #\(pdo)"
            }

            if let current = usbc.operatingCurrent {
                info.operatingCurrent = String(format: "%.2f A (%.0f mA)", current, current * 1000)
            }

            // Source capabilities (from charger) - TODO: Get from AppleTypeCPort
            // For now, sourceCapabilities will remain empty

            // Sink capabilities (laptop)
            info.sinkCapabilities = usbc.sinkCapabilities.map { pdo in
                if pdo.isPPS {
                    if let minV = pdo.ppsMinVoltage, let maxV = pdo.ppsMaxVoltage {
                        return String(format: "PDO %d (PPS): %.1f-%.1fV @ %.2fA (Programmable Power Supply)", pdo.pdoNumber, minV, maxV, pdo.current)
                    }
                }
                return String(format: "PDO %d: %.1f V @ %.2f A (%.1f W)", pdo.pdoNumber, pdo.voltage, pdo.current, pdo.power)
            }
        }

        // ========== DISPLAY INFO ==========
        if let display = displayInfo {
            if display.brightness > 0 {
                info.displayBrightness = String(format: "%.0f%%", display.brightness)
            }
            if let power = display.estimatedPower {
                info.displayPowerEstimate = String(format: "%.1fW", power)
            }
        }

        // ========== USB PORTS ==========
        if let usb = usbPortInfo {
            info.usbWakeCurrent = String(format: "%.2f A (%.0f mA)", usb.wakeCurrent, usb.wakeCurrent * 1000)
            info.usbSleepCurrent = String(format: "%.2f A (%.0f mA)", usb.sleepCurrent, usb.sleepCurrent * 1000)
        }

        // ========== POWER MANAGEMENT ==========
        if let pm = powerMgmtInfo {
            info.lowPowerMode = pm.lowPowerMode ? "Enabled" : "Disabled"
            info.hibernationMode = pm.hibernationMode
            info.wakeOnLAN = pm.wakeOnLAN ? "Enabled" : "Disabled"
            info.powerNap = pm.powerNap ? "Enabled" : "Disabled"

            if pm.displaySleepMinutes > 0 {
                info.displaySleepMinutes = "\(pm.displaySleepMinutes) min"
            }

            info.activeAssertions = pm.activeAssertions
            info.powerSourceHistory = pm.powerSourceHistory
            info.sleepWakeHistory = pm.sleepWakeHistory
            info.scheduledEvents = pm.scheduledEvents
        }

        return info
    }
}

