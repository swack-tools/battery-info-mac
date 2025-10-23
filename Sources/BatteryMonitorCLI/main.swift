import Foundation

// MARK: - macOS Battery Monitor - Full Feature Parity with Python

@main
struct BatteryMonitorCLI {
    static func main() async {
        // Print header matching Python format
        print("macOS Battery and Charger Information (Detailed Mode)")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print(dateFormatter.string(from: Date()))
        print("")

        // Get all data
        var battery = IOKitBattery.getBatteryInfo()
        let systemInfo = SystemCommands.getSystemInfo()
        let chargerInfo = IOKitBattery.getChargerInfo()
        let healthScore = SystemCommands.calculateHealthScore(battery: battery)
        let displayInfo = SystemCommands.getDisplayInfo()
        let usbPortInfo = SystemCommands.getUSBPortInfo()
        let powerMgmt = SystemCommands.getPowerManagementInfo()
        let usbcPD = IOKitBattery.getUSBCPDInfoFromBattery()

        // Get firmware version, device name, and condition from system_profiler
        if let spBatteryDetails = SystemCommands.getBatteryDetailsFromSystemProfiler() {
            if battery.firmwareVersion == nil {
                battery.firmwareVersion = spBatteryDetails.firmwareVersion
            }
            if battery.deviceName == nil {
                battery.deviceName = spBatteryDetails.deviceName
            }
            if spBatteryDetails.condition != nil {
                battery.condition = spBatteryDetails.condition ?? battery.condition
            }
        }

        // Get power metrics if running as root
        var powerMetrics: PowerMetrics? = nil
        if getuid() == 0 {
            if var pm = SystemCommands.getPowerMetrics() {
                SystemCommands.enrichPowerMetrics(&pm, battery: battery)
                powerMetrics = pm
            }
        }

        // ==================== System Information ====================
        printHeader("System Information")
        printRow("Mac Model:", systemInfo.macModel)
        printRow("Chip:", systemInfo.chipModel)
        printRow("RAM:", "\(systemInfo.ramGB) GB")
        printRow("CPU Cores:", "\(systemInfo.cpuCores) physical, \(systemInfo.cpuCores) logical")
        print("")

        // ==================== Summary ====================
        // Show USB-C PD Contract if adapter is connected (from AdapterDetails, not PowerTelemetryData)
        if let adapterV = chargerInfo?.profileVoltage, let adapterA = chargerInfo?.profileCurrent, adapterV > 0, adapterA > 0 {
            printHeader("Summary")
            let watts = chargerInfo?.adapterWattage ?? Int(adapterV * adapterA)
            printRow("USB-C PD Contract:", String(format: "%.2f V @ %.2f A (%d W)", adapterV, adapterA, watts))
            print("")
        }

        // ==================== Battery Status ====================
        printHeader("Battery Status")
        printRow("Current Charge:", "\(battery.batteryPercentage)%")

        // Status: charged, charging, or discharging (matching pmset output)
        let batteryStatus: String
        if battery.isCharged {
            batteryStatus = "charged"
        } else if battery.isCharging {
            batteryStatus = "charging"
        } else {
            batteryStatus = "discharging"
        }
        printRow("Status:", batteryStatus)
        printRow("Power Source:", battery.isPluggedIn ? "AC Power" : "Battery Power")
        printRow("Charging:", battery.isCharging ? "Yes" : "No")

        if let timeToFull = battery.timeToFull, battery.isCharging {
            let _ = timeToFull / 60
            let mins = timeToFull % 60
            printRow("Avg Time to Full:", "\(mins) min (\(timeToFull) min)")
        }

        // Show time to empty when not charging (matches Python behavior)
        if let timeToEmpty = battery.timeToEmpty, !battery.isCharging {
            // Handle special cases: 65535 (0xFFFF), -1, or 0 means "Not available"
            if timeToEmpty == 65535 || timeToEmpty <= 0 {
                printRow("Avg Time to Empty:", "Not available")
            } else {
                let hours = timeToEmpty / 60
                let mins = timeToEmpty % 60
                printRow("Avg Time to Empty:", "\(hours) hrs \(mins) min (\(timeToEmpty) min)")
            }
        }
        print("")

        // ==================== Battery Health ====================
        printHeader("Battery Health")
        printRow("Condition:", battery.condition)
        printRow("Service Recommended:", battery.serviceRecommended ? "Yes" : "No")
        printRow("Cycle Count:", "\(battery.cycleCount) cycles")
        printRow("Design Cycle Count:", "\(battery.designCycleCount) cycles (design lifespan)")
        printDescription("Expected battery lifespan")
        printRow("Lifespan Used:", String(format: "%.1f%% (%d / %d cycles)", battery.lifespanUsedPercent, battery.cycleCount, battery.designCycleCount))

        let fcc = battery.actualMaxCapacityMah
        printRow("Battery FCC:", "\(fcc) mAh")
        printRow("Design Capacity:", "\(battery.designCapacity) mAh")
        printRow("Nominal Capacity:", "\(battery.nominalChargeCapacity) mAh")
        printRow("Health Percentage:", "\(battery.healthPercent)%")
        print("")

        // Capacity Analysis
        print("Capacity Analysis:")
        print("  Design (factory):    \(battery.designCapacity) mAh (100%)")

        if battery.nominalChargeCapacity > 0 {
            let nominalPct = Double(battery.nominalChargeCapacity) / Double(battery.designCapacity) * 100.0
            let nominalDiff = battery.nominalChargeCapacity - battery.designCapacity
            print(String(format: "  Nominal (rated):     %d mAh (%.1f%%) [%@%d mAh]",
                        battery.nominalChargeCapacity, nominalPct,
                        nominalDiff >= 0 ? "+" : "", nominalDiff))
        }

        let fccPct = Double(fcc) / Double(battery.designCapacity) * 100.0
        let degradation = battery.designCapacity - fcc
        print(String(format: "  Current Max (FCC):   %d mAh (%.1f%%) [-%d mAh degradation]", fcc, fccPct, degradation))

        printRow("Temperature:", String(format: "%.1f°C", battery.temperature))
        printRow("Current Capacity:", "\(battery.currentCapacity) mAh")

        if let packReserve = battery.packReserve {
            printRow("Pack Reserve:", "\(packReserve) mAh (reserved)")
            printDescription("Capacity reserved by battery management")
        }

        printRow("At Critical Level:", battery.atCriticalLevel ? "Yes" : "No")

        if let estCycles = battery.estimatedCyclesTo80Percent {
            printRow("Est. Cycles to 80%:", "\(estCycles) cycles")
        }

        // Cell voltages
        if let v1 = battery.cellVoltage1, let v2 = battery.cellVoltage2 {
            var cellStr = "\(Int(v1 * 1000))mV, \(Int(v2 * 1000))mV"
            if let v3 = battery.cellVoltage3 {
                cellStr += ", \(Int(v3 * 1000))mV"
            }
            if let v4 = battery.cellVoltage4 {
                cellStr += ", \(Int(v4 * 1000))mV"
            }
            printRow("Cell Voltages:", cellStr)

            if let delta = battery.cellVoltageImbalance {
                printRow("Cell Voltage Delta:", "\(Int(delta))mV")
            }
        }

        if let cellDisconnect = battery.cellDisconnectCount {
            printRow("Cell Disconnect Count:", "\(cellDisconnect)")
        }

        if let rsenseOpen = battery.rsenseOpenCount {
            printRow("R-sense Open Count:", "\(rsenseOpen)")
        }

        if let permFailure = battery.permanentFailureStatus {
            let status = permFailure == 0 ? "None (battery healthy)" : String(format: "0x%04X", permFailure)
            printRow("Permanent Failure:", status)
        }

        if let gaugeWrites = battery.gaugeWriteCount {
            printRow("Gauge Write Count:", "\(gaugeWrites)")
        }

        printRow("Battery Mfg:", battery.manufacturer ?? "Unknown")

        if let model = battery.batteryModel, let rev = battery.batteryModelRevision {
            printRow("Battery Model (Mfg):", "\(model) (rev \(rev))")
        }

        printRow("Rated Cycle Life:", "\(battery.designCycleCount) cycles (\(String(format: "%.1f", battery.lifespanUsedPercent))% used)")

        if let mfgDate = battery.manufactureDate {
            printRow("Manufacture Date:", mfgDate)
        }

        if let chemistry = battery.chemistry {
            printRow("Battery Chemistry:", chemistry)
        }

        if let gaugeSoC = battery.gaugeSoC {
            printRow("Gauge SOC:", "\(gaugeSoC)%")
        }

        if let dailyMin = battery.dailyChargeMin, let dailyMax = battery.dailyChargeMax {
            printRow("Daily Charge Range:", "\(dailyMin)% - \(dailyMax)%")
        }

        if battery.shippingModeActive {
            if let minV = battery.shippingModeVoltageMin, let maxV = battery.shippingModeVoltageMax {
                printRow("Shipping Mode:", String(format: "Active (range: %.1fV - %.1fV)", minV, maxV))
            } else {
                printRow("Shipping Mode:", "Active")
            }
        } else {
            if let minV = battery.shippingModeVoltageMin, let maxV = battery.shippingModeVoltageMax {
                printRow("Shipping Mode:", String(format: "Disabled (range: %.1fV - %.1fV)", minV, maxV))
            }
        }

        // Lifetime Energy (use actual accumulated energy from PowerTelemetryData)
        if let lifetimeKWh = battery.lifetimeEnergyKWh {
            printRow("Lifetime Energy:", String(format: "~%.1f kWh (est)", lifetimeKWh))
        }
        print("")

        // ==================== Advanced Battery Diagnostics ====================
        if battery.internalResistance != nil || battery.gaugeQmax != nil {
            printHeader("Advanced Battery Diagnostics")

            if let resistance = battery.internalResistance {
                let assessment = resistance < 100 ? "Excellent" : resistance < 150 ? "Fair" : "High"
                printRow("Internal Resistance:", String(format: "%.1f mΩ (%@)", resistance, assessment))
                printDescription("Lower resistance = better battery health")
            }

            if let qmax = battery.gaugeQmax {
                let diff = abs(Double(qmax) - Double(fcc))
                let diffPct = (diff / Double(fcc)) * 100.0
                printRow("Gauge Measured Qmax:", String(format: "%d mAh (FCC: %d mAh, %.1f%% diff)", qmax, fcc, diffPct))
            }

            // Virtual Temperature - only show when battery is active and value is reliable
            if let virtualTemp = battery.virtualTemperature {
                let tempDiff = virtualTemp - battery.temperature

                // Check if battery is active (charging or discharging with >100mA current)
                let batteryActive = battery.isCharging || abs(battery.amperage) > 100

                // Only show if: battery is active AND temp is realistic AND difference is reasonable
                if batteryActive && virtualTemp >= -20 && virtualTemp <= 80 && abs(tempDiff) > 2 && abs(tempDiff) < 10 {
                    printRow("Virtual Temperature:", String(format: "%.1f°C (calc: %+.1f°C from sensor)", virtualTemp, tempDiff))
                    printDescription("Calculated temp based on load & discharge")
                }
            }

            if let bestPort = battery.bestChargerPort {
                printRow("Best Charger Port:", "USB-C Port \(bestPort)")
                printDescription("Port with highest power capability")
            }

            if let gaugeStatus = battery.gaugeStatus {
                // Decode gauge status flags (matching Python decoder)
                var statusFlags: [String] = []
                if gaugeStatus & 0x0001 != 0 { statusFlags.append("Discharge Detected") }
                if gaugeStatus & 0x0002 != 0 { statusFlags.append("Charge Termination") }
                if gaugeStatus & 0x0004 != 0 { statusFlags.append("Overcharge Detection") }
                if gaugeStatus & 0x0008 != 0 { statusFlags.append("Terminate Discharge Alarm") }
                if gaugeStatus & 0x0010 != 0 { statusFlags.append("Over-Temperature Alarm") }
                if gaugeStatus & 0x0020 != 0 { statusFlags.append("Terminate Charge Alarm") }
                if gaugeStatus & 0x0040 != 0 { statusFlags.append("Impedance Measured") }
                if gaugeStatus & 0x0080 != 0 { statusFlags.append("Fully Charged (FC)") }
                if gaugeStatus & 0x0100 != 0 { statusFlags.append("Discharge Inhibit") }
                if gaugeStatus & 0x0200 != 0 { statusFlags.append("Charge Inhibit") }
                if gaugeStatus & 0x0400 != 0 { statusFlags.append("Voltage OK (VOK)") }
                if gaugeStatus & 0x0800 != 0 { statusFlags.append("Ready (RDY)") }
                if gaugeStatus & 0x1000 != 0 { statusFlags.append("Qualified for Use (QEN)") }
                if gaugeStatus & 0x2000 != 0 { statusFlags.append("Fast Charge OK") }
                if gaugeStatus & 0x4000 != 0 { statusFlags.append("Battery Present") }
                if gaugeStatus & 0x8000 != 0 { statusFlags.append("Valid Data") }

                let decodedStatus = statusFlags.isEmpty ? "None (0x00)" : statusFlags.joined(separator: ", ")
                printRow("Gauge Status:", "\(decodedStatus) (0x\(String(format: "%04X", gaugeStatus)))")
                printDescription("Battery gauge chip status flags")
            }

            if let miscStatus = battery.miscStatus {
                let decodedMisc = BatteryDecoders.decodeMiscStatus(miscStatus)
                printRow("Misc Status:", decodedMisc)
                printDescription("⚠️  Bit meanings undocumented by Apple")
            }

            if let postCharge = battery.postChargeWaitSeconds {
                printRow("Post-Charge Wait:", "\(postCharge / 60) min (\(postCharge)s)")
                printDescription("Rest time after charging before measurement")
            }

            if let postDischarge = battery.postDischargeWaitSeconds {
                printRow("Post-Discharge Wait:", "\(postDischarge / 60) min (\(postDischarge)s)")
                printDescription("Rest time after discharge before measurement")
            }

            if let invalidWake = battery.invalidWakeSeconds {
                printRow("Invalid Wake Time:", "\(invalidWake) sec (\(invalidWake)s)")
                printDescription("Time battery stayed awake when it shouldn't")
            }

            if let chargeAccum = battery.chargeAccumulated {
                printRow("Charge Accumulated:", "\(chargeAccum) mAh")
                printDescription("Total charge accumulated in battery")
            }

            if let lastQmax = battery.cycleCountLastQmax {
                let cyclesSince = battery.cycleCount - lastQmax
                printRow("Last Calibration:", "\(cyclesSince) cycles ago (at cycle \(lastQmax))")
                printDescription("Cycles since battery capacity recalibration")
            }

            print("")
        }

        // ==================== Electrical Information ====================
        printHeader("Electrical Information")
        printRow("Voltage:", String(format: "%.2fV (%d mV)", battery.voltage, Int(battery.voltage * 1000)))

        // Current (Avg) - match Python format
        if battery.amperage == 0 {
            printRow("Current (Avg):", "0 mA (idle)")
        } else if battery.amperage > 0 {
            printRow("Current (Avg):", String(format: "+%.2fA (%d mA) (charging)",
                                             battery.amperage / 1000.0, Int(battery.amperage)))
        } else {
            printRow("Current (Avg):", String(format: "%.2fA (%d mA) (discharging)",
                                             battery.amperage / 1000.0, Int(battery.amperage)))
        }

        // Current (Instant)
        if battery.instantAmperage == 0 {
            printRow("Current (Instant):", "0 mA")
        } else {
            printRow("Current (Instant):", String(format: "%.2fA (%d mA)",
                                                  battery.instantAmperage / 1000.0, Int(battery.instantAmperage)))
        }

        printRow("Current (Filtered):", "0 mA (idle)")  // Placeholder

        // Battery Charge Power (only when charging)
        if battery.isCharging {
            let batteryPower = battery.voltage * battery.amperage / 1000.0  // W
            printRow("Battery Charge Power:", String(format: "%.1fW", batteryPower))
        }
        print("")

        // ==================== Charger Information ====================
        printHeader("Charger Information")
        if let charger = chargerInfo {
            printRow("Connected:", "Yes")

            // Charging type
            if charger.chargingType != nil {
                let typeDisplay = charger.isWireless ? "Wireless" : "USB-C Wired"
                printRow("Charging Type:", typeDisplay)
            }

            // Wattage
            if charger.adapterWattage > 0 {
                printRow("Wattage:", "\(charger.adapterWattage)W")
            }

            // Calculated wattage from voltage and current
            if let voltage = charger.profileVoltage, let current = charger.profileCurrent {
                let calcWattage = voltage * current
                printRow("Wattage (calc):", String(format: "%.1fW", calcWattage))
            }

            // Type/Description
            if let type = charger.chargingType {
                printRow("Type:", type)
            }

            // Active Profile
            if let profileIndex = charger.activeProfileIndex,
               let voltage = charger.profileVoltage,
               let current = charger.profileCurrent {
                let watts = Int(voltage * current)
                printRow("Active Profile:", String(format: "Index %d (%.0fV @ %.2fA, %dW)",
                    profileIndex, voltage, current, watts))
            }

            // Voltage and Current
            if let voltage = charger.profileVoltage {
                printRow("Voltage:", String(format: "%.1fV", voltage))
            }
            if let current = charger.profileCurrent {
                printRow("Current:", String(format: "%.2fA", current))
            }

            // Current Limit (calculated from wattage / voltage)
            if let voltage = charger.profileVoltage, charger.adapterWattage > 0, voltage > 0 {
                let currentLimit = Double(charger.adapterWattage) / voltage
                printRow("Current Limit (calc):", String(format: "%.2fA", currentLimit))
            }

            // Charger Family
            if let familyCode = charger.adapterFamilyCode {
                let familyStr = String(format: "0x%x", familyCode)
                let decoded = decodeChargerFamily(familyCode)
                printRow("Charger Family:", "\(familyStr) (\(decoded))")
            }

            // Charger ID
            let chargerIDStr = charger.adapterID == 0 ? "Generic/Third-Party Charger" : "Apple Charger"
            printRow("Charger ID:", String(format: "%@ (ID: 0x%02X)", chargerIDStr, charger.adapterID))

            // Not Charging Reason
            printRow("Not Charging Reason:", charger.isCharging ? "None (charging normally)" : "Not charging")

            // Charging Mode (based on power)
            if charger.isCharging, let adapterPower = battery.adapterPower {
                let chargingMode: String
                if adapterPower > 20 {
                    chargingMode = "Fast Charging (>20W)"
                } else if adapterPower < 5 {
                    chargingMode = "Trickle Charging (<5W)"
                } else {
                    chargingMode = "Standard Charging (5-20W)"
                }
                printRow("Charging Mode:", chargingMode)
            }

            // Charger Config (show as hex with decoded bits)
            if let config = charger.chargerConfiguration {
                let bits = getBitPositions(config)
                let bitsStr = bits.map { String($0) }.joined(separator: ", ")
                printRow("Charger Config:", String(format: "0x%04X (bits: %@)", config, bitsStr))

                // Decode charger config bits
                let configDesc = decodeChargerConfig(config)
                if !configDesc.isEmpty {
                    printRow("", configDesc)
                }
            }

            // External Charge
            printRow("External Charge:", charger.externalChargeCapable ? "Yes" : "No")

            // Adapter Input (real-time power from PowerTelemetryData)
            if let adapterPower = battery.adapterPower, adapterPower > 0 {
                printRow("Adapter Input:", String(format: "%.1fW", adapterPower))
                printRow("", "(Real-time from PowerTelemetryData)")
            }

            // Adapter Efficiency (if we have both adapter input and battery charging power)
            if let adapterPower = battery.adapterPower,
               adapterPower > 0,
               let adapterV = battery.adapterVoltage,
               let adapterA = battery.adapterCurrent {
                let dcPower = adapterV * adapterA
                if dcPower > 0 {
                    let efficiency = (dcPower / adapterPower) * 100.0
                    let loss = adapterPower - dcPower
                    printRow("Adapter Efficiency:", String(format: "%.1f%% (%.1fW loss)", efficiency, loss))
                    printRow("", "(AC to DC conversion efficiency)")
                }
            }

            // Charging Efficiency (battery charge power / adapter input)
            if let adapterPower = battery.adapterPower, adapterPower > 0 {
                let batteryChargePower = battery.voltage * battery.amperage / 1000.0
                if batteryChargePower > 0 {
                    let chargingEfficiency = (batteryChargePower / adapterPower) * 100.0
                    printRow("Charging Efficiency:", String(format: "%.1f%%", chargingEfficiency))
                    printRow("", "(Battery charge / Total adapter input)")
                }
            }
        } else {
            printRow("Connected:", "No")
        }
        print("")

        // ==================== Power Breakdown ====================
        if let pm = powerMetrics {
            printHeader("Power Breakdown")
            printRow("CPU Power:", String(format: "%.1fW", pm.cpuPower))
            printRow("GPU Power:", String(format: "%.1fW", pm.gpuPower))
            printRow("ANE Power:", String(format: "%.1fW", pm.anePower))
            printRow("DRAM Power:", String(format: "%.1fW", pm.dramPower))
            let combinedPower = pm.cpuPower + pm.gpuPower + pm.anePower + pm.dramPower
            printRow("Combined Power:", String(format: "%.1fW", combinedPower))
            printRow("Total System Power:", String(format: "%.1fW", pm.totalSystemPower))
            if let thermal = pm.thermalPressure {
                printRow("Thermal Pressure:", thermal)
            }
            let peakComponent = max(pm.cpuPower, pm.gpuPower, pm.anePower, pm.dramPower)
            printRow("Peak Component:", String(format: "%.1fW", peakComponent))

            // Idle Power estimate (when total power is very low)
            if pm.totalSystemPower > 0 && pm.totalSystemPower < 5.0 {
                printRow("Idle Power (est):", String(format: "%.1fW", pm.totalSystemPower))
            }

            // Real-time power flow
            print("Real-Time Power Flow:")
            printRow("  Adapter Power In:", String(format: "%.1fW", pm.adapterPowerIn))
            printRow("  Battery Power:", String(format: "%.1fW", pm.batteryPower))
            printRow("  System Load:", String(format: "%.1fW", pm.systemLoad))
            print("")

            // Power distribution
            let total = pm.systemLoad > 0 ? pm.systemLoad : pm.totalSystemPower
            if total > 0 {
                let componentsPct = (combinedPower / total) * 100.0
                print("Power Distribution:")
                printRow("  Components:", String(format: "%.1fW (%d%%)", combinedPower, Int(componentsPct)))
                printDescription("CPU/GPU/ANE/DRAM")

                if let displayPower = pm.displayPower {
                    let displayPct = (displayPower / total) * 100.0
                    printRow("  Display:", String(format: "%.1fW (%d%%)", displayPower, Int(displayPct)))
                    if let brightness = displayInfo?.brightness {
                        printDescription("Backlight @ \(Int(brightness))%")
                    }
                }

                if let otherPower = pm.otherComponentsPower {
                    let otherPct = (otherPower / total) * 100.0
                    printRow("  Other Components:", String(format: "%.1fW (%d%%)", otherPower, Int(otherPct)))
                    printDescription("SSD, WiFi, Thunderbolt, USB, etc.")
                }

                printRow("  Total System Load:", String(format: "%.1fW", total))
            }
            print("")
        }

        // ==================== Display ====================
        if let display = displayInfo {
            printHeader("Display")
            printRow("Display Brightness:", "\(Int(display.brightness))%")
            if let power = display.estimatedPower {
                printRow("Display Power (est):", String(format: "%.1fW", power))
                printDescription("(Estimated: \(Int(display.brightness))% × \(Int(display.maxPower))W max)")
            }
            print("")
        }

        // ==================== USB Ports ====================
        if let usb = usbPortInfo {
            printHeader("USB Ports")
            printRow("USB Wake Current:", String(format: "%.2f A (%d mA)", usb.wakeCurrent, Int(usb.wakeCurrent * 1000)))
            printRow("USB Sleep Current:", String(format: "%.2f A (%d mA)", usb.sleepCurrent, Int(usb.sleepCurrent * 1000)))
            print("")
        }

        // ==================== Power Management ====================
        if let pm = powerMgmt {
            printHeader("Power Management")
            printRow("Low Power Mode:", pm.lowPowerMode ? "Enabled" : "Disabled")
            printRow("Hibernation Mode:", pm.hibernationMode)
            printRow("Wake on LAN:", pm.wakeOnLAN ? "Enabled" : "Disabled")

            if !pm.activeAssertions.isEmpty {
                printRow("Active Assertions:", "\(pm.activeAssertions.count) active")
                for assertion in pm.activeAssertions.prefix(3) {
                    printDescription(assertion)
                }
            }

            printRow("Power Nap:", pm.powerNap ? "Enabled" : "Disabled")
            printRow("Display Sleep:", "\(pm.displaySleepMinutes) min")

            if !pm.powerSourceHistory.isEmpty {
                printRow("Power Source History:", "\(pm.powerSourceHistory.count) recent changes")
                for event in pm.powerSourceHistory.prefix(2) {
                    printDescription(event)
                }
            }

            if !pm.sleepWakeHistory.isEmpty {
                printRow("Sleep/Wake History:", "\(pm.sleepWakeHistory.count) recent events")
                for event in pm.sleepWakeHistory.prefix(3) {
                    printDescription(event)
                }
            }

            if !pm.scheduledEvents.isEmpty {
                printRow("Scheduled Events:", "\(pm.scheduledEvents.count) upcoming")
                for event in pm.scheduledEvents.prefix(2) {
                    printDescription(event)
                }
            }
            print("")
        }

        // ==================== USB-C Power Delivery ====================
        if let pd = usbcPD {
            printHeader("USB-C Power Delivery")
            if let spec = pd.pdSpecification {
                printRow("PD Specification:", spec)
            }
            if let powerRole = pd.powerRole {
                printRow("Power Role:", powerRole)
            }
            if let dataRole = pd.dataRole {
                printRow("Data Role:", dataRole)
            }
            if let rdo = pd.activeRDO {
                printRow("Active RDO:", rdo)
            }
            if let selectedPDO = pd.selectedPDO {
                printRow("Selected PDO:", "PDO #\(selectedPDO)")
            }
            if let opCurrent = pd.operatingCurrent {
                printRow("Operating Current:", String(format: "%.2f A (%d mA)", opCurrent, Int(opCurrent * 1000)))
            }
            if let maxCurrent = pd.maxCurrent {
                printRow("Max Current:", String(format: "%.2f A (%d mA)", maxCurrent, Int(maxCurrent * 1000)))
            }
            if let fwVer = pd.portFWVersion {
                printRow("Port FW Version:", fwVer)
            }
            printRow("Number of PDOs:", "\(pd.numberOfPDOs)")
            printRow("Number of EPR PDOs:", "\(pd.numberOfEPRPDOs)")
            if let portMode = pd.portMode {
                printRow("Port Mode:", portMode)
            }
            if let powerState = pd.powerState {
                printRow("Power State:", "\(powerState) (Active/Normal Operation)")
            }
            if let maxPower = pd.portMaxPower {
                printRow("Port Max Power:", String(format: "%.1f W", maxPower))
            }
            print("")
        }

        // ==================== Source Capabilities (Charger) ====================
        if let charger = chargerInfo, !charger.sourceCapabilities.isEmpty {
            printHeader("Source Capabilities (Charger)")
            for cap in charger.sourceCapabilities {
                if cap.isPPS {
                    let minV = cap.ppsMinVoltage ?? 0
                    let maxV = cap.ppsMaxVoltage ?? 0
                    printRow("PDO \(cap.pdoNumber) (PPS):", String(format: "%.1f-%.1f V @ %.2f A", minV, maxV, cap.current))
                    printDescription("(Programmable Power Supply - variable voltage)")
                } else {
                    printRow("PDO \(cap.pdoNumber):", String(format: "%.2f V @ %.2f A (%.1f W)", cap.voltage, cap.current, cap.power))
                }
            }
            print("")
        }

        // ==================== Sink Capabilities (Laptop) ====================
        if let pd = usbcPD {
            // Sink Capabilities
            if !pd.sinkCapabilities.isEmpty {
                printHeader("Sink Capabilities (Laptop)")
                for cap in pd.sinkCapabilities {
                    if cap.isPPS {
                        let minV = cap.ppsMinVoltage ?? 0
                        let maxV = cap.ppsMaxVoltage ?? 0
                        printRow("PDO \(cap.pdoNumber) (PPS):", String(format: "%.1f-%.1f V @ %.2f A", minV, maxV, cap.current))
                        printDescription("(Programmable Power Supply - variable voltage)")
                    } else {
                        printRow("PDO \(cap.pdoNumber):", String(format: "%.2f V @ %.2f A (%.1f W)", cap.voltage, cap.current, cap.power))
                    }
                }
                print("")
            }
        }

        // ==================== Battery Details ====================
        printHeader("Battery Details")
        if let deviceName = battery.deviceName {
            // If it looks like a chip model (contains letters and numbers), show it
            if deviceName.contains(where: { $0.isLetter }) && deviceName.contains(where: { $0.isNumber }) && deviceName.count < 20 {
                printRow("Model:", deviceName)
            }
        }
        if let serial = battery.serialNumber {
            printRow("Serial Number:", serial)
        }
        if let fwVersion = battery.firmwareVersion {
            printRow("Firmware Version:", fwVersion)
        }
        if let gasGaugeFW = battery.gasGaugeFirmwareVersion {
            printRow("Gas Gauge FW:", gasGaugeFW)
        }
        if let ageDays = battery.batteryAgeDays, let ageYears = battery.batteryAgeYears {
            printRow("Battery Age:", "\(ageDays) days (\(String(format: "%.1f", ageYears)) years)")
        }
        print("")

        // ==================== Lifetime Statistics ====================
        if battery.totalOperatingTime != nil || battery.averageTemperature != nil {
            printHeader("Lifetime Statistics")
            if let totalTime = battery.totalOperatingTime {
                let hours = Double(totalTime) / 60.0
                printRow("Total Operating Time:", "\(totalTime) minutes (~\(String(format: "%.1f", hours)) hours)")
            }
            if let maxTemp = battery.maximumTemperature {
                printRow("Maximum Temperature:", "\(Int(maxTemp))°C")
            }
            if let minTemp = battery.minimumTemperature {
                printRow("Minimum Temperature:", "\(Int(minTemp))°C")
            }
            if let avgTemp = battery.averageTemperature {
                printRow("Average Temperature:", String(format: "%.1f°C", avgTemp))
            }
            print("")
        }

        // ==================== Health Assessment ====================
        printHeader("Health Assessment")
        let factorsStr = healthScore.factors.joined(separator: ", ")
        printRow("Battery Health Score:", "\(healthScore.score)/100 (\(healthScore.grade) - \(healthScore.description))")
        printDescription(factorsStr)
        print("")

        let cycleAssessment = battery.cycleCount < 100 ? "Excellent (very low)" :
                            battery.cycleCount < 300 ? "Very Good" :
                            battery.cycleCount < 500 ? "Good" : "Fair"
        printRow("Cycle Count:", "\(cycleAssessment) (\(battery.cycleCount) cycles - \(cycleAssessment.lowercased()))")

        let capacityAssessment = battery.healthPercent >= 95 ? "Excellent" :
                                battery.healthPercent >= 85 ? "Very Good" :
                                battery.healthPercent >= 80 ? "Good" : "Fair"
        printRow("Capacity:", "\(capacityAssessment) (\(battery.healthPercent)% of original)")
        print("")
        print("Note: MacBook batteries typically maintain good health for 1000+ cycles")
        print("")

        // Show tip for power metrics if not running as root
        if getuid() != 0 {
            print("💡 Tip: Run with sudo for complete power metrics and diagnostics")
            print("")
        }
    }

    // MARK: - Formatting Helpers

    static func printHeader(_ title: String) {
        print(title)
        print(String(repeating: "=", count: 50))
    }

    static func printRow(_ label: String, _ value: String) {
        let padding = 23 - label.count
        let spaces = String(repeating: " ", count: max(padding, 1))
        print("\(label)\(spaces)\(value)")
    }

    static func printDescription(_ desc: String) {
        print("                       \(desc)")
    }

    // MARK: - Decoder Helpers

    /// Get bit positions set in an integer
    static func getBitPositions(_ value: Int) -> [Int] {
        var positions: [Int] = []
        for i in 0..<32 {
            if (value & (1 << i)) != 0 {
                positions.append(i)
            }
        }
        return positions
    }

    /// Decode charger family code
    static func decodeChargerFamily(_ familyCode: Int64) -> String {
        // Known Apple chargers
        let knownChargers: [Int64: String] = [
            0xe0008d03: "Apple 140W USB-C",
            0xe0008c03: "Apple 96W USB-C",
            0xe0008b03: "Apple 87W USB-C",
            0xe0008a03: "Apple 61W USB-C",
            0xe0008903: "Apple 30W USB-C",
            0xe0008803: "Apple 29W USB-C"
        ]

        if let name = knownChargers[familyCode] {
            return name
        }

        // Generic identification based on high bits
        let highByte = (familyCode >> 24) & 0xFF
        if highByte == 0xe0 {
            return "USB-C PD charger"
        } else {
            return "Legacy charger"
        }
    }

    /// Decode charger configuration bits
    static func decodeChargerConfig(_ config: Int) -> String {
        var descriptions: [String] = []

        if (config & (1 << 0)) != 0 { descriptions.append("PPON enabled") }
        if (config & (1 << 1)) != 0 { descriptions.append("BCCON enabled") }
        if (config & (1 << 2)) != 0 { descriptions.append("DCMON enabled") }
        if (config & (1 << 3)) != 0 { descriptions.append("Charging disabled") }
        if (config & (1 << 4)) != 0 { descriptions.append("Battery installed") }
        if (config & (1 << 5)) != 0 { descriptions.append("Charger suspended") }
        if (config & (1 << 6)) != 0 { descriptions.append("Charger inhibited (charge stopped)") }
        if (config & (1 << 7)) != 0 { descriptions.append("Temporary battery") }
        if (config & (1 << 8)) != 0 { descriptions.append("Thermistor valid") }
        if (config & (1 << 9)) != 0 { descriptions.append("Auto-recharge disabled") }
        if (config & (1 << 10)) != 0 { descriptions.append("Fast charge allowed") }
        if (config & (1 << 11)) != 0 { descriptions.append("Charge inhibit override") }

        return descriptions.joined(separator: ", ")
    }
}
