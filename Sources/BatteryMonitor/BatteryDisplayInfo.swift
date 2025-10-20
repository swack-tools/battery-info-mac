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
    var deviceName: String? = nil  // e.g. "bq40z651"
    var firmwareVersion: String? = nil  // e.g. "0b00"
    var gasGaugeFirmwareVersion: String? = nil  // e.g. "v2"
    var batteryAge: String? = nil  // e.g. "45 days (0.1 years)"

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
    var chargeAccumulated: String? = nil
    var lastCalibration: String? = nil  // e.g. "6 cycles ago (at cycle 63)"

    // Lifetime Statistics
    var totalOperatingTime: String? = nil  // e.g. "6361 minutes (~106.0 hours)"
    var maximumTemperature: String? = nil  // e.g. "39°C"
    var minimumTemperature: String? = nil  // e.g. "14°C"
    var averageTemperature: String? = nil  // e.g. "21.7°C"

    // Health Assessment
    var healthScore: String? = nil  // e.g. "95/100 (A - Very Good)"
    var healthGrade: String? = nil  // e.g. "A"
    var healthDescription: String? = nil  // e.g. "Very Good"
    var cycleAssessment: String? = nil  // e.g. "Excellent"
    var capacityAssessment: String? = nil  // e.g. "Excellent"

    // Electrical Information
    var currentAvg: String? = nil  // e.g. "+1.90A (1900 mA) (charging)"
    var currentInstant: String? = nil  // e.g. "1.90A (1900 mA)"
    var currentFiltered: String? = nil  // e.g. "0 mA (idle)"
    var batteryChargePower: String? = nil  // e.g. "25.2W"

    // Charging
    var chargerWattage: String? = nil
    var chargerType: String? = nil
    var chargerFamily: String? = nil
    var chargerSerial: String? = nil
    var chargerID: String? = nil  // e.g. "USB-C PD (ID: 0x0E)"
    var voltage: String? = nil
    var current: String? = nil
    var power: String? = nil
    var adapterEfficiency: String? = nil  // e.g. "92.5% (3.5W loss)"
    var chargingEfficiency: String? = nil  // e.g. "85.3%"
    var chargingMode: String? = nil  // e.g. "CC/CV (Constant Current/Constant Voltage)"
    var chargerConfig: String? = nil  // e.g. "0x0878 (bits: 0000100001111000)"
    var notChargingReason: String? = nil  // e.g. "None (charging normally)"
    var externalChargeCapable: String? = nil  // e.g. "Yes"
    var adapterInput: String? = nil  // e.g. "29.4W (Real-time from PowerTelemetryData)"

    // USB-C PD
    var pdContract: String? = nil
    var pdSpecification: String? = nil
    var powerRole: String? = nil
    var dataRole: String? = nil
    var selectedPDO: String? = nil
    var activeRDO: String? = nil  // e.g. "0x5364B145"
    var operatingCurrent: String? = nil
    var maxCurrent: String? = nil  // e.g. "2.24 A (2240 mA)"
    var portFWVersion: String? = nil  // e.g. "v3.1.0"
    var numberOfPDOs: String? = nil  // e.g. "5"
    var numberOfEPRPDOs: String? = nil  // e.g. "0"
    var portMode: String? = nil  // e.g. "SNK (Sink)"
    var powerState: String? = nil  // e.g. "5 (Active/Normal Operation)"
    var portMaxPower: String? = nil  // e.g. "44.9 W"
    var sourceCapabilities: [String] = []
    var sinkCapabilities: [String] = []

    // Display
    var displayBrightness: String? = nil
    var displayPowerEstimate: String? = nil

    // USB Ports
    var usbWakeCurrent: String? = nil
    var usbSleepCurrent: String? = nil

    // Power Breakdown
    var hasPowerMetrics: Bool = false
    var cpuPower: String? = nil
    var gpuPower: String? = nil
    var anePower: String? = nil
    var dramPower: String? = nil
    var combinedPower: String? = nil
    var totalSystemPower: String? = nil
    var thermalPressure: String? = nil
    var peakComponent: String? = nil
    var idlePowerEstimate: String? = nil

    // Real-Time Power Flow
    var adapterPowerIn: String? = nil
    var batteryPowerFlow: String? = nil
    var systemLoad: String? = nil

    // Power Distribution
    var componentsPowerPct: String? = nil
    var displayPowerPct: String? = nil
    var otherComponentsPower: String? = nil
    var otherComponentsPowerPct: String? = nil

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
        var batteryData = IOKitBattery.getBatteryInfo()
        let chargerData = IOKitBattery.getChargerInfo()
        let systemInfo = SystemCommands.getSystemInfo()
        let usbcInfo = IOKitBattery.getUSBCPDInfoFromBattery()  // Use same function as CLI
        let displayInfo = SystemCommands.getDisplayInfo()
        let usbPortInfo = SystemCommands.getUSBPortInfo()
        let powerMgmtInfo = SystemCommands.getPowerManagementInfo()

        // Get firmware version, device name, and condition from system_profiler
        // (system_profiler is more reliable than IOPowerSources for battery health)
        if let spBatteryDetails = SystemCommands.getBatteryDetailsFromSystemProfiler() {
            if batteryData.firmwareVersion == nil {
                batteryData.firmwareVersion = spBatteryDetails.firmwareVersion
            }
            if batteryData.deviceName == nil {
                batteryData.deviceName = spBatteryDetails.deviceName
            }
            if spBatteryDetails.condition != nil {
                batteryData.condition = spBatteryDetails.condition ?? batteryData.condition
            }
        }

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
        info.deviceName = batteryData.deviceName
        info.firmwareVersion = batteryData.firmwareVersion
        info.gasGaugeFirmwareVersion = batteryData.gasGaugeFirmwareVersion

        if let model = batteryData.batteryModel, let rev = batteryData.batteryModelRevision {
            info.batteryModel = "\(model) (rev \(rev))"
        } else if let model = batteryData.batteryModel {
            info.batteryModel = model
        }

        // Battery age
        if let mfgDate = batteryData.manufactureDate {
            // Calculate age from manufacture date
            // mfgDate format is already a string, just display as-is for now
            // TODO: Calculate actual age if we parse the date
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

        if let chargeAccum = batteryData.chargeAccumulated {
            info.chargeAccumulated = "\(chargeAccum) mAh"
        }

        if let lastQmax = batteryData.cycleCountLastQmax, lastQmax > 0 {
            let cyclesSince = batteryData.cycleCount - lastQmax
            info.lastCalibration = "\(cyclesSince) cycles ago (at cycle \(lastQmax))"
        }

        // ========== LIFETIME STATISTICS ==========
        if let totalTime = batteryData.totalOperatingTime {
            let hours = Double(totalTime) / 60.0
            info.totalOperatingTime = String(format: "%d minutes (~%.1f hours)", totalTime, hours)
        }

        if let maxTemp = batteryData.maximumTemperature {
            info.maximumTemperature = String(format: "%d°C", Int(maxTemp))
        }

        if let minTemp = batteryData.minimumTemperature {
            info.minimumTemperature = String(format: "%d°C", Int(minTemp))
        }

        if let avgTemp = batteryData.averageTemperature {
            info.averageTemperature = String(format: "%.1f°C", avgTemp)
        }

        // ========== HEALTH ASSESSMENT ==========
        let healthScore = SystemCommands.calculateHealthScore(battery: batteryData)
        info.healthScore = "\(healthScore.score)/100 (\(healthScore.grade) - \(healthScore.description))"
        info.healthGrade = healthScore.grade
        info.healthDescription = healthScore.description

        // Cycle assessment
        if batteryData.cycleCount < 100 {
            info.cycleAssessment = "Excellent"
        } else if batteryData.cycleCount < 300 {
            info.cycleAssessment = "Very Good"
        } else if batteryData.cycleCount < 500 {
            info.cycleAssessment = "Good"
        } else if batteryData.cycleCount < 800 {
            info.cycleAssessment = "Fair"
        } else {
            info.cycleAssessment = "Aging"
        }

        // Capacity assessment
        if batteryData.healthPercent >= 95 {
            info.capacityAssessment = "Excellent"
        } else if batteryData.healthPercent >= 85 {
            info.capacityAssessment = "Very Good"
        } else if batteryData.healthPercent >= 75 {
            info.capacityAssessment = "Good"
        } else if batteryData.healthPercent >= 60 {
            info.capacityAssessment = "Fair"
        } else {
            info.capacityAssessment = "Poor"
        }

        // ========== ELECTRICAL INFORMATION ==========
        // Current (Average)
        if abs(batteryData.amperage) < 10 {
            info.currentAvg = "0 mA (idle)"
        } else if batteryData.amperage > 0 {
            info.currentAvg = String(format: "+%.2fA (%d mA) (charging)", batteryData.amperage / 1000.0, Int(batteryData.amperage))
        } else {
            info.currentAvg = String(format: "%.2fA (%d mA) (discharging)", batteryData.amperage / 1000.0, Int(batteryData.amperage))
        }

        // Current (Instant)
        if abs(batteryData.instantAmperage) < 10 {
            info.currentInstant = "0 mA"
        } else {
            info.currentInstant = String(format: "%.2fA (%d mA)", batteryData.instantAmperage / 1000.0, Int(batteryData.instantAmperage))
        }

        // Current (Filtered) - placeholder for now
        info.currentFiltered = "0 mA (idle)"

        // Battery charge power
        if batteryData.isCharging && batteryData.amperage > 0 {
            let power = (batteryData.voltage * batteryData.amperage) / 1000.0
            info.batteryChargePower = String(format: "%.1fW", power)
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

            // Charger ID
            if charger.adapterID > 0 {
                info.chargerID = String(format: "0x%02X", charger.adapterID)
            }

            // Not charging reason
            info.notChargingReason = charger.isCharging ? "None (charging normally)" : "Not charging"

            // External charge capable
            info.externalChargeCapable = charger.externalChargeCapable ? "Yes" : "No"

            // Adapter real-time power (from PowerTelemetryData)
            if let adapterPower = batteryData.adapterPower, adapterPower > 0 {
                info.adapterInput = String(format: "%.1fW (Real-time)", adapterPower)
            }

            // Adapter and charging efficiency
            if let adapterPower = batteryData.adapterPower, adapterPower > 0 {
                let batteryPower = abs((batteryData.voltage * batteryData.amperage) / 1000.0)

                if batteryData.isCharging && batteryPower > 0 {
                    let systemLoad = adapterPower - batteryPower
                    let loss = adapterPower - batteryPower - systemLoad

                    if loss > 0 {
                        let efficiency = ((adapterPower - loss) / adapterPower) * 100.0
                        info.adapterEfficiency = String(format: "%.1f%% (%.1fW loss)", efficiency, loss)
                    }

                    let chargingEff = (batteryPower / adapterPower) * 100.0
                    info.chargingEfficiency = String(format: "%.1f%%", chargingEff)
                }
            }

            // Source capabilities (from charger)
            info.sourceCapabilities = charger.sourceCapabilities.map { pdo in
                if pdo.isPPS {
                    if let minV = pdo.ppsMinVoltage, let maxV = pdo.ppsMaxVoltage {
                        return String(format: "PDO %d (PPS): %.1f-%.1fV @ %.2fA (Programmable Power Supply)", pdo.pdoNumber, minV, maxV, pdo.current)
                    }
                }
                return String(format: "PDO %d: %.2f V @ %.2f A (%.1f W)", pdo.pdoNumber, pdo.voltage, pdo.current, pdo.power)
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

            if let maxCurr = usbc.maxCurrent {
                info.maxCurrent = String(format: "%.2f A (%.0f mA)", maxCurr, maxCurr * 1000)
            }

            // activeRDO is already a formatted string
            info.activeRDO = usbc.activeRDO

            if let fwVersion = usbc.portFWVersion {
                info.portFWVersion = fwVersion
            }

            info.numberOfPDOs = "\(usbc.numberOfPDOs)"
            info.numberOfEPRPDOs = "\(usbc.numberOfEPRPDOs)"

            if let mode = usbc.portMode {
                info.portMode = mode
            }

            if let state = usbc.powerState {
                info.powerState = "\(state) (Active/Normal Operation)"
            }

            if let maxPower = usbc.portMaxPower, maxPower > 0 {
                info.portMaxPower = String(format: "%.1f W", maxPower)
            }

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

        // ========== POWER BREAKDOWN ==========
        // Use real-time system load from PowerTelemetryData if available
        if let systemLoad = batteryData.systemLoadPower, systemLoad > 0 {
            info.systemLoad = String(format: "%.1fW", systemLoad)
        } else if !batteryData.isCharging {
            // Fallback: On battery, system load = battery discharge power
            let batteryPower = abs((batteryData.voltage * batteryData.amperage) / 1000.0)
            if batteryPower > 0 {
                info.systemLoad = String(format: "%.1fW", batteryPower)
            }
        } else if let adapterPower = batteryData.adapterPower, adapterPower > 0 {
            // Fallback: Charging, system load = adapter power - battery charging power
            let batteryChargePower = abs((batteryData.voltage * batteryData.amperage) / 1000.0)
            let estimatedSystemLoad = adapterPower - batteryChargePower
            if estimatedSystemLoad > 0 {
                info.systemLoad = String(format: "%.1fW", estimatedSystemLoad)
            }
        }

        // Get power metrics (requires sudo for full details)
        if var powerMetrics = SystemCommands.getPowerMetrics() {
            // Enrich with battery data for power flow calculations
            SystemCommands.enrichPowerMetrics(&powerMetrics, battery: batteryData)

            info.hasPowerMetrics = true
            info.cpuPower = String(format: "%.1fW", powerMetrics.cpuPower)
            info.gpuPower = String(format: "%.1fW", powerMetrics.gpuPower)
            info.anePower = String(format: "%.1fW", powerMetrics.anePower)
            info.dramPower = String(format: "%.1fW", powerMetrics.dramPower)

            let combinedPower = powerMetrics.cpuPower + powerMetrics.gpuPower + powerMetrics.anePower + powerMetrics.dramPower
            info.combinedPower = String(format: "%.1fW", combinedPower)
            info.totalSystemPower = String(format: "%.1fW", powerMetrics.totalSystemPower)

            if let thermal = powerMetrics.thermalPressure {
                info.thermalPressure = thermal
            }

            let peakComponent = max(powerMetrics.cpuPower, powerMetrics.gpuPower, powerMetrics.anePower, powerMetrics.dramPower)
            info.peakComponent = String(format: "%.1fW", peakComponent)

            // Idle power estimate (when total power is very low)
            if powerMetrics.totalSystemPower > 0 && powerMetrics.totalSystemPower < 5.0 {
                info.idlePowerEstimate = String(format: "%.1fW", powerMetrics.totalSystemPower)
            }

            // Real-time power flow
            info.adapterPowerIn = String(format: "%.1fW", powerMetrics.adapterPowerIn)
            info.batteryPowerFlow = String(format: "%.1fW", powerMetrics.batteryPower)
            info.systemLoad = String(format: "%.1fW", powerMetrics.systemLoad)

            // Power distribution
            let total = powerMetrics.systemLoad > 0 ? powerMetrics.systemLoad : powerMetrics.totalSystemPower
            if total > 0 {
                let componentsPct = (combinedPower / total) * 100.0
                info.componentsPowerPct = String(format: "%.1fW (%d%%)", combinedPower, Int(componentsPct))

                if let displayPower = powerMetrics.displayPower {
                    let displayPct = (displayPower / total) * 100.0
                    info.displayPowerPct = String(format: "%.1fW (%d%%)", displayPower, Int(displayPct))
                }

                if let otherPower = powerMetrics.otherComponentsPower {
                    let otherPct = (otherPower / total) * 100.0
                    info.otherComponentsPower = String(format: "%.1fW", otherPower)
                    info.otherComponentsPowerPct = String(format: "%.1fW (%d%%)", otherPower, Int(otherPct))
                }
            }
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

