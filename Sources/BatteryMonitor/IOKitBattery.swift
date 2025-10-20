import Foundation
import IOKit
import IOKit.ps

// MARK: - IOKit Battery Access

class IOKitBattery {

    /// Get battery information directly from IOKit
    static func getBatteryInfo() -> BatteryData {
        var batteryData = BatteryData()

        // Get the power source blob
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return batteryData
        }

        // Get the first power source (internal battery)
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            // Only process internal batteries
            if let type = info[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                batteryData = parseBatteryInfo(info)
                break
            }
        }

        // Get additional data from IORegistry
        if let service = getAppleSmartBatteryService() {
            enrichBatteryData(&batteryData, from: service)
            IOObjectRelease(service)
        }

        return batteryData
    }

    /// Get charger information from IORegistry
    static func getChargerInfo() -> ChargerData? {
        guard let service = getAppleSmartBatteryService() else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        var charger = ChargerData()

        // Check if external charger is connected
        if let externalConnected = props["ExternalConnected"] as? Bool {
            charger.isCharging = externalConnected
        }

        // Extract from AdapterDetails
        if let adapterDetails = props["AdapterDetails"] as? [String: Any] {
            // Adapter ID
            if let adapterId = adapterDetails["AdapterID"] as? Int {
                charger.adapterID = adapterId
            }

            // Wattage
            if let watts = adapterDetails["Watts"] as? Int {
                charger.adapterWattage = watts
            }

            // Description (e.g., "pd charger")
            if let description = adapterDetails["Description"] as? String {
                charger.chargingType = description
            }

            // Family Code
            if let familyCode = adapterDetails["FamilyCode"] as? Int64 {
                charger.adapterFamilyCode = familyCode
                charger.adapterFamily = String(format: "0x%x", familyCode)
            } else if let familyCode = adapterDetails["FamilyCode"] as? Int {
                charger.adapterFamilyCode = Int64(familyCode)
                charger.adapterFamily = String(format: "0x%x", familyCode)
            }

            // Active profile index
            if let profileIndex = adapterDetails["UsbHvcHvcIndex"] as? Int {
                charger.activeProfileIndex = profileIndex
            }

            // Current profile voltage and current
            if let voltage = adapterDetails["AdapterVoltage"] as? Int {
                charger.profileVoltage = Double(voltage) / 1000.0  // mV to V
            }
            if let current = adapterDetails["Current"] as? Int {
                charger.profileCurrent = Double(current) / 1000.0  // mA to A
            }

            // IsWireless
            if let isWireless = adapterDetails["IsWireless"] as? Bool {
                charger.isWireless = isWireless
            }

            // PMU Configuration (charger config register)
            if let pmuConfig = adapterDetails["PMUConfiguration"] as? Int {
                charger.pmuConfiguration = pmuConfig
            }

            // Parse UsbHvcMenu (source capabilities - available PDOs)
            if let menu = adapterDetails["UsbHvcMenu"] as? [[String: Any]] {
                charger.sourceCapabilities = parseSourcePDOs(menu)
            }
        }

        // Charger Configuration register
        if let chargerConfig = props["ChargerConfiguration"] as? Int {
            charger.chargerConfiguration = chargerConfig
        }

        // External charge capable
        if let externalCapable = props["ExternalChargeCapable"] as? Bool {
            charger.externalChargeCapable = externalCapable
        }

        // IsCharging
        if let isCharging = props["IsCharging"] as? Bool {
            charger.isCharging = isCharging
        }

        return charger.isCharging || charger.externalChargeCapable ? charger : nil
    }

    /// Parse source PDOs from UsbHvcMenu
    private static func parseSourcePDOs(_ menu: [[String: Any]]) -> [PDOCapability] {
        var pdos: [PDOCapability] = []

        for item in menu {
            guard let index = item["Index"] as? Int,
                  let maxVoltage = item["MaxVoltage"] as? Int,
                  let maxCurrent = item["MaxCurrent"] as? Int else {
                continue
            }

            let voltage = Double(maxVoltage) / 1000.0  // mV to V
            let current = Double(maxCurrent) / 1000.0  // mA to A
            let power = voltage * current

            pdos.append(PDOCapability(
                pdoNumber: index + 1,
                voltage: voltage,
                current: current,
                power: power,
                isPPS: false
            ))
        }

        return pdos
    }

    /// Parse battery info from power source dictionary
    private static func parseBatteryInfo(_ info: [String: Any]) -> BatteryData {
        var data = BatteryData()

        // Basic charging status
        data.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
        data.isPluggedIn = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        data.isCharged = info[kIOPSIsChargedKey] as? Bool ?? false
        data.externalConnected = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue

        // Capacity
        data.currentCapacity = info[kIOPSCurrentCapacityKey] as? Int ?? 0
        data.maxCapacity = info[kIOPSMaxCapacityKey] as? Int ?? 0
        data.designCapacity = info[kIOPSDesignCapacityKey] as? Int ?? 0

        // Note: Health will be calculated in enrichBatteryData after reading AppleRawMaxCapacity

        // Cycle count
        data.cycleCount = info["Cycle Count"] as? Int ?? 0

        // Health
        data.condition = info[kIOPSBatteryHealthKey] as? String ?? "Unknown"

        // Time estimates (from PowerSource API)
        data.timeToFull = info[kIOPSTimeToFullChargeKey] as? Int
        data.timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int

        // Voltage and current
        if let voltage = info[kIOPSVoltageKey] as? Int {
            data.voltage = Double(voltage) / 1000.0  // mV to V
        }
        if let amperage = info[kIOPSCurrentKey] as? Int {
            data.amperage = Double(amperage)  // mA
        }

        // Temperature
        if let temp = info["Temperature"] as? Int {
            // Temperature is in decikelvin (tenths of kelvin)
            data.temperature = (Double(temp) / 10.0) - 273.15  // Convert to Celsius
        }

        // Device info (will be enriched from IORegistry later)
        data.manufacturer = info["Manufacturer"] as? String
        data.serialNumber = info[kIOPSHardwareSerialNumberKey] as? String
        // Don't use kIOPSNameKey here - it's "InternalBattery-0"
        // Real device name will come from IORegistry

        return data
    }

    /// Get the AppleSmartBattery IOService
    static func getAppleSmartBatteryService() -> io_service_t? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )

        return service != 0 ? service : nil
    }

    /// Enrich battery data with additional IORegistry properties
    private static func enrichBatteryData(_ data: inout BatteryData, from service: io_service_t) {
        // Get all properties
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)

        guard result == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else {
            return
        }

        // Voltage (mV to V)
        if let voltage = props["Voltage"] as? Int {
            data.voltage = Double(voltage) / 1000.0
        }

        // Amperage (handle signed/unsigned overflow)
        if let amperage = props["Amperage"] as? Int {
            // If value is very large, it's actually negative (2's complement)
            if amperage > 32767 {
                data.amperage = Double(amperage - 65536)
            } else {
                data.amperage = Double(amperage)
            }
        }

        // InstantAmperage (handle signed/unsigned overflow for 64-bit values)
        if let instantAmp = props["InstantAmperage"] as? Int64 {
            // For negative values stored as unsigned, convert from 2's complement
            if instantAmp > Int64.max / 2 {
                data.instantAmperage = Double(Int64(bitPattern: UInt64(instantAmp)))
            } else {
                data.instantAmperage = Double(instantAmp)
            }
        } else if let instantAmp = props["InstantAmperage"] as? Int {
            // Fallback to Int if not Int64
            if instantAmp > 32767 {
                data.instantAmperage = Double(instantAmp - 65536)
            } else {
                data.instantAmperage = Double(instantAmp)
            }
        }

        // Temperature (decikelvin to Celsius)
        if let temp = props["Temperature"] as? Int {
            data.temperature = (Double(temp) / 10.0) - 273.15
        }

        // Charging status from IORegistry (more accurate than IOPowerSources)
        if let isCharging = props["IsCharging"] as? Bool {
            data.isCharging = isCharging
        }

        // FullyCharged flag
        if let fullyCharged = props["FullyCharged"] as? Bool {
            data.isCharged = fullyCharged
            // If fully charged, override isCharging to false
            if fullyCharged {
                data.isCharging = false
            }
        }

        // Cycle count
        if let cycles = props["CycleCount"] as? Int {
            data.cycleCount = cycles
        }

        // Time to empty - always use IORegistry value (matches Python behavior)
        // AvgTimeToEmpty is more accurate than PowerSource API's TimeToEmpty
        if let avgTimeToEmpty = props["AvgTimeToEmpty"] as? Int {
            data.timeToEmpty = avgTimeToEmpty
        }

        // Design capacity
        if let designCap = props["DesignCapacity"] as? Int {
            data.designCapacity = designCap
        }

        // Max capacity (may be percentage or mAh depending on system)
        if let maxCap = props["MaxCapacity"] as? Int {
            data.maxCapacity = maxCap
        }

        // Apple Raw Max Capacity (actual FCC in mAh)
        if let rawMaxCap = props["AppleRawMaxCapacity"] as? Int {
            data.appleRawMaxCapacity = rawMaxCap
        }

        // Nominal Charge Capacity (rated capacity in mAh)
        if let nominalCap = props["NominalChargeCapacity"] as? Int {
            data.nominalChargeCapacity = nominalCap
        }

        // Current capacity - keep as percentage from IOPowerSources/IORegistry
        // Don't overwrite with AppleRawCurrentCapacity (mAh) - that's stored separately
        if let currentCap = props["CurrentCapacity"] as? Int {
            // CurrentCapacity is the percentage macOS reports (0-100)
            if currentCap >= 0 && currentCap <= 100 {
                data.currentCapacity = currentCap  // Keep as percentage
            }
        }
        // AppleRawCurrentCapacity is available via calculation when needed

        // Cell voltages (check both root and BatteryData)
        var cellVoltages: [Int]? = props["CellVoltage"] as? [Int]

        // If not at root, check inside BatteryData
        if cellVoltages == nil, let batteryData = props["BatteryData"] as? [String: Any] {
            cellVoltages = batteryData["CellVoltage"] as? [Int]
        }

        if let voltages = cellVoltages {
            if voltages.count > 0 { data.cellVoltage1 = Double(voltages[0]) / 1000.0 }
            if voltages.count > 1 { data.cellVoltage2 = Double(voltages[1]) / 1000.0 }
            if voltages.count > 2 { data.cellVoltage3 = Double(voltages[2]) / 1000.0 }
            if voltages.count > 3 { data.cellVoltage4 = Double(voltages[3]) / 1000.0 }

            // Calculate imbalance (difference between highest and lowest)
            // Keep calculation in mV (Int) to avoid floating-point precision loss
            if voltages.count >= 2 {
                if let max = voltages.max(), let min = voltages.min() {
                    data.cellVoltageImbalance = Double(max - min)  // Already in mV
                }
            }
        }

        // Pack voltage
        if let packVoltage = props["PackVoltage"] as? Int {
            data.packVoltage = Double(packVoltage) / 1000.0
        }

        // Internal resistance (mΩ) - check multiple sources
        if let resistance = props["BatteryResistance"] as? Int {
            data.internalResistance = Double(resistance)
        } else if let batteryData = props["BatteryData"] as? [String: Any],
                  let weightedRa = batteryData["WeightedRa"] as? [Int], weightedRa.count > 0 {
            // Calculate average of WeightedRa array
            let sum = weightedRa.reduce(0, +)
            data.internalResistance = Double(sum) / Double(weightedRa.count)
        }

        // Gauge State of Charge (check multiple locations)
        if let gaugeSoC = props["GaugeSOC"] as? Int {
            data.gaugeSoC = gaugeSoC
        } else if let batteryData = props["BatteryData"] as? [String: Any],
                  let stateOfCharge = batteryData["StateOfCharge"] as? Int {
            data.gaugeSoC = stateOfCharge
        }

        // Virtual temperature
        if let virtualTemp = props["VirtualTemperature"] as? Int {
            data.virtualTemperature = (Double(virtualTemp) / 10.0) - 273.15
        }

        // Chemistry ID (check both root and BatteryData)
        if let chemID = props["ChemID"] as? Int {
            data.chemID = chemID
            data.chemistry = decodeChemID(chemID)
        } else if let batteryData = props["BatteryData"] as? [String: Any],
                  let chemID = batteryData["ChemID"] as? Int {
            data.chemID = chemID
            data.chemistry = decodeChemID(chemID)
        }

        // Device Name (battery chip model like "bq40z651")
        if let deviceName = props["DeviceName"] as? String {
            data.deviceName = deviceName
        }

        // Manufacturing info
        if let mfgData = props["ManufacturerData"] as? Data {
            // Try to decode manufacturer data
            if let decoded = decodeManufacturerData(mfgData) {
                if data.manufacturer == nil {
                    data.manufacturer = decoded["manufacturer"]
                }
                data.batteryModel = decoded["model"]
                data.batteryModelRevision = decoded["revision"]
            }
        }

        // Manufacture date (check both root and BatteryData, can be Int or Int64)
        var mfgDateRaw: Int64? = nil
        if let mfgDate = props["ManufactureDate"] as? Int64 {
            mfgDateRaw = mfgDate
        } else if let mfgDate = props["ManufactureDate"] as? Int {
            mfgDateRaw = Int64(mfgDate)
        } else if let batteryData = props["BatteryData"] as? [String: Any] {
            if let mfgDate = batteryData["ManufactureDate"] as? Int64 {
                mfgDateRaw = mfgDate
            } else if let mfgDate = batteryData["ManufactureDate"] as? Int {
                mfgDateRaw = Int64(mfgDate)
            }
        }

        if let mfgDate = mfgDateRaw {
            data.manufactureDate = decodeManufactureDate(mfgDate)

            // Calculate battery age in days
            if let dateStr = data.manufactureDate {
                data.batteryAgeDays = calculateBatteryAgeDays(from: dateStr)
            }
        }

        // Gas Gauge Firmware version from IORegistry
        if let fwVersion = props["GasGaugeFirmwareVersion"] as? Int {
            data.gasGaugeFirmwareVersion = String(format: "v%d", fwVersion)
        }

        // Status flags
        if let permFailure = props["PermanentFailureStatus"] as? Int {
            data.permanentFailureStatus = permFailure
        }

        if let gaugeFlag = props["GaugeFlagRaw"] as? Int {
            data.gaugeFlagRaw = gaugeFlag
        }

        if let miscStatus = props["MiscStatus"] as? Int {
            data.miscStatus = miscStatus
        }

        // Pack reserve
        if let packReserve = props["PackReserve"] as? Int {
            data.packReserve = packReserve
        }

        // Critical level
        if let atCritical = props["AtCriticalLevel"] as? Bool {
            data.atCriticalLevel = atCritical
        }

        // Best charger port (BestAdapterIndex in IORegistry)
        if let bestPort = props["BestAdapterIndex"] as? Int {
            data.bestChargerPort = bestPort
        }

        // Check BatteryData subdictionary for additional fields
        if let batteryData = props["BatteryData"] as? [String: Any] {
            if data.miscStatus == nil, let ms = batteryData["MiscStatus"] as? Int {
                data.miscStatus = ms
            }

            // RSense Open Count
            if let rsenseOpen = batteryData["BatteryRsenseOpenCount"] as? Int {
                data.rsenseOpenCount = rsenseOpen
            }

            // Gauge Write Count (DataFlashWriteCount)
            if let gaugeWrites = batteryData["DataFlashWriteCount"] as? Int {
                data.gaugeWriteCount = gaugeWrites
            }

            // Gauge Status (field name is GaugeFlagRaw)
            if let gaugeStatus = batteryData["GaugeFlagRaw"] as? Int {
                data.gaugeStatus = gaugeStatus
            } else if let gaugeStatus = batteryData["GaugeStatus"] as? Int {
                data.gaugeStatus = gaugeStatus
            }

            // PostChargeWaitSeconds (check in BatteryData)
            if let postCharge = batteryData["PostChargeWaitSeconds"] as? Int {
                data.postChargeWaitSeconds = postCharge
            }

            // PostDischargeWaitSeconds (check in BatteryData)
            if let postDischarge = batteryData["PostDischargeWaitSeconds"] as? Int {
                data.postDischargeWaitSeconds = postDischarge
            }

            // InvalidWakeSeconds (check in BatteryData)
            if let invalidWake = batteryData["InvalidWakeSeconds"] as? Int {
                data.invalidWakeSeconds = invalidWake
            }

            // ChargeAccumulated (field name is ChargeAccum)
            if let chargeAccum = batteryData["ChargeAccum"] as? Int {
                data.chargeAccumulated = chargeAccum
            } else if let chargeAccum = batteryData["ChargeAccumulated"] as? Int {
                data.chargeAccumulated = chargeAccum
            }

            // Daily SOC (State of Charge) tracking
            if let dailyMax = batteryData["DailyMaxSoc"] as? Int {
                data.dailyChargeMax = dailyMax
            }
            if let dailyMin = batteryData["DailyMinSoc"] as? Int {
                data.dailyChargeMin = dailyMin
            }

            // Carrier Mode (Shipping Mode) - check in BatteryData
            if let carrierMode = batteryData["CarrierMode"] as? [String: Any] {
                if let status = carrierMode["CarrierModeStatus"] as? Int {
                    data.shippingModeActive = (status != 0)
                }
                if let highVoltage = carrierMode["CarrierModeHighVoltage"] as? Int {
                    data.shippingModeVoltageMax = Double(highVoltage) / 1000.0  // mV to V
                }
                if let lowVoltage = carrierMode["CarrierModeLowVoltage"] as? Int {
                    data.shippingModeVoltageMin = Double(lowVoltage) / 1000.0  // mV to V
                }
            }
        }

        // Carrier Mode (Shipping Mode) - also check at root level
        if data.shippingModeVoltageMax == nil, let carrierMode = props["CarrierMode"] as? [String: Any] {
            if let status = carrierMode["CarrierModeStatus"] as? Int {
                data.shippingModeActive = (status != 0)
            }
            if let highVoltage = carrierMode["CarrierModeHighVoltage"] as? Int {
                data.shippingModeVoltageMax = Double(highVoltage) / 1000.0  // mV to V
            }
            if let lowVoltage = carrierMode["CarrierModeLowVoltage"] as? Int {
                data.shippingModeVoltageMin = Double(lowVoltage) / 1000.0  // mV to V
            }
        }

        // Cell Disconnect Count (at root level)
        if let cellDisconnect = props["BatteryCellDisconnectCount"] as? Int {
            data.cellDisconnectCount = cellDisconnect
        }

        // PostChargeWaitSeconds (also check at root level)
        if data.postChargeWaitSeconds == nil, let postCharge = props["PostChargeWaitSeconds"] as? Int {
            data.postChargeWaitSeconds = postCharge
        }

        // PostDischargeWaitSeconds (also check at root level)
        if data.postDischargeWaitSeconds == nil, let postDischarge = props["PostDischargeWaitSeconds"] as? Int {
            data.postDischargeWaitSeconds = postDischarge
        }

        // BatteryInvalidWakeSeconds (at root level)
        if data.invalidWakeSeconds == nil, let invalidWake = props["BatteryInvalidWakeSeconds"] as? Int {
            data.invalidWakeSeconds = invalidWake
        }

        // Health
        if let batteryHealth = props["BatteryHealth"] as? String {
            data.condition = batteryHealth
        }

        // Update health percentage using actual FCC
        let actualFCC = data.actualMaxCapacityMah
        if actualFCC > 0 && data.designCapacity > 0 {
            data.healthPercent = Int((Double(actualFCC) / Double(data.designCapacity)) * 100)
        } else if data.maxCapacity > 100 && data.designCapacity > 0 {
            // Fallback if maxCapacity is in mAh
            data.healthPercent = Int((Double(data.maxCapacity) / Double(data.designCapacity)) * 100)
        }

        // Lifetime Data (can be at root or inside BatteryData)
        var lifetimeData: [String: Any]? = props["LifetimeData"] as? [String: Any]

        // If not found at root, check inside BatteryData
        if lifetimeData == nil, let batteryData = props["BatteryData"] as? [String: Any] {
            lifetimeData = batteryData["LifetimeData"] as? [String: Any]
        }

        if let lifetime = lifetimeData {
            // Total operating time (already in minutes)
            if let totalTime = lifetime["TotalOperatingTime"] as? Int {
                data.totalOperatingTime = totalTime  // Already in minutes
            }

            // Average temperature (deciCelsius - tenths of degree Celsius)
            if let avgTemp = lifetime["AverageTemperature"] as? Int {
                data.averageTemperature = Double(avgTemp) / 10.0
            }

            // Maximum temperature (Celsius)
            if let maxTemp = lifetime["MaximumTemperature"] as? Int {
                data.maximumTemperature = Double(maxTemp)
            }

            // Minimum temperature (Celsius)
            if let minTemp = lifetime["MinimumTemperature"] as? Int {
                data.minimumTemperature = Double(minTemp)
            }

            // Cycle count at last Qmax calibration
            if let cycleLastQmax = lifetime["CycleCountLastQmax"] as? Int {
                data.cycleCountLastQmax = cycleLastQmax
            }

            // Gauge measured maximum capacity (can be Int or array)
            if let qmax = lifetime["Qmax"] as? Int {
                data.gaugeQmax = qmax
            } else if let qmaxArray = lifetime["Qmax"] as? [Int], qmaxArray.count > 0 {
                // Average the Qmax values
                let sum = qmaxArray.reduce(0, +)
                data.gaugeQmax = sum / qmaxArray.count
            }
        }

        // Also check for Qmax at BatteryData level (not just LifetimeData)
        if data.gaugeQmax == nil, let batteryData = props["BatteryData"] as? [String: Any] {
            if let qmax = batteryData["Qmax"] as? Int {
                data.gaugeQmax = qmax
            } else if let qmaxArray = batteryData["Qmax"] as? [Int], qmaxArray.count > 0 {
                let sum = qmaxArray.reduce(0, +)
                data.gaugeQmax = sum / qmaxArray.count
            }
        }

        // PowerTelemetryData - real-time power metrics and accumulated energy
        if let ptd = props["PowerTelemetryData"] as? [String: Any] {
            // Accumulated system energy (for lifetime energy calculation)
            // IORegistry stores as NSNumber, need to extract as Int64
            if let energyNum = ptd["AccumulatedSystemEnergyConsumed"] as? NSNumber {
                data.accumulatedSystemEnergy = energyNum.int64Value
            }

            // Real-time adapter voltage and current (from SystemVoltageIn/SystemCurrentIn)
            if let adapterVoltage = ptd["SystemVoltageIn"] as? Int {
                data.adapterVoltage = Double(adapterVoltage) / 1000.0  // mV to V
            }

            if let adapterCurrent = ptd["SystemCurrentIn"] as? Int {
                // Handle signed/unsigned overflow
                if adapterCurrent > 32767 {
                    data.adapterCurrent = Double(adapterCurrent - 65536) / 1000.0  // mA to A
                } else {
                    data.adapterCurrent = Double(adapterCurrent) / 1000.0  // mA to A
                }
            }

            // Real-time adapter power input (from SystemPowerIn)
            if let adapterPower = ptd["SystemPowerIn"] as? Int {
                data.adapterPower = Double(adapterPower) / 1000.0  // mW to W
            }
        }
    }

    // MARK: - Decoders

    /// Decode ChemID to chemistry name
    private static func decodeChemID(_ chemID: Int) -> String {
        let knownIDs: [Int: String] = [
            29961: "Li-ion (High Energy)",
            29960: "Li-ion (Standard)",
            29962: "Li-ion (High Power)",
            29963: "Li-ion Polymer"
        ]

        if let known = knownIDs[chemID] {
            return "\(known) (ID: \(chemID))"
        } else {
            return "Li-ion (ID: \(chemID))"
        }
    }

    /// Decode manufacturer data binary blob
    private static func decodeManufacturerData(_ data: Data) -> [String: String]? {
        var result: [String: String] = [:]

        // Try to extract ASCII strings
        if let text = String(data: data, encoding: .ascii) {
            let parts = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }

            if parts.count >= 3 {
                result["model"] = parts[0]
                result["revision"] = parts[1]
                result["manufacturer"] = parts[2]
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Decode manufacture date (TI battery chip format: M-DD-YY-C)
    private static func decodeManufactureDate(_ dateRaw: Int64) -> String? {
        // Convert to hex string
        let hexStr = String(format: "%llX", dateRaw)

        // Decode as ASCII
        var dateStr = ""
        var index = hexStr.startIndex
        while index < hexStr.endIndex {
            let nextIndex = hexStr.index(index, offsetBy: 2, limitedBy: hexStr.endIndex) ?? hexStr.endIndex
            let byteStr = hexStr[index..<nextIndex]
            if let byte = UInt8(byteStr, radix: 16) {
                let scalar = UnicodeScalar(byte)
                if scalar.isASCII {
                    dateStr.append(Character(scalar))
                }
            }
            index = nextIndex
        }

        // Parse as M-DD-YY-C format
        guard dateStr.count >= 5 else { return nil }

        let monthStr = String(dateStr.prefix(1))
        let dayStr = String(dateStr.dropFirst(1).prefix(2))
        let yearStr = String(dateStr.dropFirst(3).prefix(2))
        let lotCode = dateStr.count > 5 ? String(dateStr.dropFirst(5)) : ""

        guard let month = Int(monthStr),
              let day = Int(dayStr),
              let yearSuffix = Int(yearStr) else {
            return nil
        }

        // Smart year detection (assume 20YY)
        let currentYear = Calendar.current.component(.year, from: Date())
        var year = 2000 + yearSuffix

        // If more than 10 years old, try 2010s or 2020s
        if year < (currentYear - 10) {
            year = 2010 + yearSuffix
            if year < (currentYear - 10) {
                year = 2020 + yearSuffix
            }
        }

        // Validate
        guard (1...12).contains(month),
              (1...31).contains(day),
              (2000...2099).contains(year) else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        if let _ = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) {
            if !lotCode.isEmpty {
                return String(format: "%04d-%02d-%02d (Lot: %@)", year, month, day, lotCode)
            } else {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
        }

        return nil
    }

    /// Calculate battery age in days from manufacture date string
    private static func calculateBatteryAgeDays(from dateString: String) -> Int? {
        // Extract date part (before any parentheses like "(Lot: X)")
        let datePart = dateString.components(separatedBy: " ").first ?? dateString

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let mfgDate = formatter.date(from: datePart) else {
            return nil
        }

        let now = Date()
        let days = Calendar.current.dateComponents([.day], from: mfgDate, to: now).day
        return days
    }
}
