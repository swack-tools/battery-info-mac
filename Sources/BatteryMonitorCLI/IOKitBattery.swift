import Foundation
import IOKit
import IOKit.ps

// MARK: - IOKit Battery Access

enum BatteryPropertySource {
    case rootBattery
    case batteryPack
}

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

        if let packService = getAppleSmartBatteryPackService() {
            enrichBatteryData(&batteryData, from: packService, source: .batteryPack)
            IOObjectRelease(packService)
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

    /// Get the AppleSmartBatteryPack IOService
    static func getAppleSmartBatteryPackService() -> io_service_t? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBatteryPack")
        )

        return service != 0 ? service : nil
    }

    /// Enrich battery data with additional IORegistry properties
    private static func enrichBatteryData(_ data: inout BatteryData, from service: io_service_t) {
        enrichBatteryData(&data, from: service, source: .rootBattery)
    }

    private static func enrichBatteryData(_ data: inout BatteryData, from service: io_service_t, source: BatteryPropertySource) {
        // Get all properties
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)

        guard result == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else {
            return
        }

        enrichBatteryData(&data, fromProperties: props, source: source)
    }

    static func enrichBatteryData(_ data: inout BatteryData, fromProperties props: [String: Any], source: BatteryPropertySource) {
        let batteryProps = props["BatteryData"] as? [String: Any]
        let orderedProps: [[String: Any]]
        switch source {
        case .rootBattery:
            orderedProps = [props, batteryProps].compactMap { $0 }
        case .batteryPack:
            orderedProps = [batteryProps, props].compactMap { $0 }
        }

        func firstInt(_ key: String) -> Int? {
            for dict in orderedProps {
                if let value = dict[key] as? Int {
                    return value
                }
                if let value = dict[key] as? Int64 {
                    return Int(value)
                }
                if let value = dict[key] as? NSNumber {
                    return value.intValue
                }
            }
            return nil
        }

        func firstInt64(_ key: String) -> Int64? {
            for dict in orderedProps {
                if let value = dict[key] as? Int64 {
                    return value
                }
                if let value = dict[key] as? Int {
                    return Int64(value)
                }
                if let value = dict[key] as? NSNumber {
                    return value.int64Value
                }
            }
            return nil
        }

        func firstBool(_ key: String) -> Bool? {
            for dict in orderedProps {
                if let value = dict[key] as? Bool {
                    return value
                }
                if let value = dict[key] as? NSNumber {
                    return value.boolValue
                }
            }
            return nil
        }

        func firstString(_ key: String) -> String? {
            for dict in orderedProps {
                if let value = dict[key] as? String {
                    return value
                }
            }
            return nil
        }

        func firstData(_ key: String) -> Data? {
            for dict in orderedProps {
                if let value = dict[key] as? Data {
                    return value
                }
            }
            return nil
        }

        func firstIntArray(_ key: String) -> [Int]? {
            for dict in orderedProps {
                if let value = dict[key] as? [Int] {
                    return value
                }
            }
            return nil
        }

        func firstDictionary(_ key: String) -> [String: Any]? {
            for dict in orderedProps {
                if let value = dict[key] as? [String: Any] {
                    return value
                }
            }
            return nil
        }

        func signedMilliamps(_ raw: Int) -> Double {
            raw > 32767 ? Double(raw - 65536) : Double(raw)
        }

        func signedMilliamps(_ raw: Int64) -> Double {
            raw > Int64.max / 2 ? Double(Int64(bitPattern: UInt64(raw))) : Double(raw)
        }

        func legacyTemperatureCelsius(_ raw: Int) -> Double {
            (Double(raw) / 10.0) - 273.15
        }

        func packTemperatureCelsius(_ raw: Int) -> Double {
            Double(raw) / 100.0
        }

        // Voltage (mV to V)
        if let voltage = firstInt("Voltage"), data.voltage == 0 || source == .rootBattery {
            data.voltage = Double(voltage) / 1000.0
        }

        // Amperage (handle signed/unsigned overflow)
        if let amperage = firstInt("Amperage"), data.amperage == 0 || source == .rootBattery {
            data.amperage = signedMilliamps(amperage)
        }

        // InstantAmperage (handle signed/unsigned overflow for 64-bit values)
        if let instantAmp = firstInt64("InstantAmperage"), data.instantAmperage == 0 || source == .rootBattery {
            data.instantAmperage = signedMilliamps(instantAmp)
        }

        if data.temperature == 0, let temp = firstInt("Temperature") {
            switch source {
            case .rootBattery:
                data.temperature = legacyTemperatureCelsius(temp)
            case .batteryPack:
                data.temperature = packTemperatureCelsius(temp)
            }
        }

        // Charging status from IORegistry (more accurate than IOPowerSources)
        if let isCharging = firstBool("IsCharging") {
            data.isCharging = isCharging
        }

        // FullyCharged flag
        if let fullyCharged = firstBool("FullyCharged") {
            data.isCharged = fullyCharged
            // If fully charged, override isCharging to false
            if fullyCharged {
                data.isCharging = false
            }
        }

        // Cycle count
        if let cycles = firstInt("CycleCount"), data.cycleCount == 0 {
            data.cycleCount = cycles
        }

        // Time to empty - always use IORegistry value (matches Python behavior)
        // AvgTimeToEmpty is more accurate than PowerSource API's TimeToEmpty
        if let avgTimeToEmpty = firstInt("AvgTimeToEmpty") {
            data.timeToEmpty = avgTimeToEmpty
        }

        // Design capacity
        if let designCap = firstInt("DesignCapacity"), data.designCapacity == 0 {
            data.designCapacity = designCap
        }

        // Max capacity (may be percentage or mAh depending on system)
        if let maxCap = firstInt("MaxCapacity"), data.maxCapacity == 0 {
            data.maxCapacity = maxCap
        }

        if data.appleRawMaxCapacity == 0 {
            if let rawMaxCap = firstInt("AppleRawMaxCapacity"), rawMaxCap > 200 {
                data.appleRawMaxCapacity = rawMaxCap
            } else if let fullChargeCapacity = firstInt("FullChargeCapacity"), fullChargeCapacity > 200 {
                data.appleRawMaxCapacity = fullChargeCapacity
            }
        }

        // Nominal Charge Capacity (rated capacity in mAh)
        if let nominalCap = firstInt("NominalChargeCapacity"), data.nominalChargeCapacity == 0 {
            data.nominalChargeCapacity = nominalCap
        }

        // Current capacity - keep as percentage from IOPowerSources/IORegistry
        // Don't overwrite with AppleRawCurrentCapacity (mAh) - that's stored separately
        if let currentCap = firstInt("CurrentCapacity") {
            // CurrentCapacity is the percentage macOS reports (0-100)
            if currentCap >= 0 && currentCap <= 100 {
                data.currentCapacity = currentCap  // Keep as percentage
            }
        }
        // AppleRawCurrentCapacity is available via calculation when needed

        // Cell voltages (check both root and BatteryData)
        if let voltages = firstIntArray("CellVoltage") {
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
        if let packVoltage = firstInt("PackVoltage"), data.packVoltage == nil {
            data.packVoltage = Double(packVoltage) / 1000.0
        }

        // Internal resistance (mΩ) - check multiple sources
        if let resistance = firstInt("BatteryResistance"), data.internalResistance == nil {
            data.internalResistance = Double(resistance)
        } else if data.internalResistance == nil,
                  let weightedRa = firstIntArray("WeightedRa"), weightedRa.count > 0 {
            // Calculate average of WeightedRa array
            let sum = weightedRa.reduce(0, +)
            data.internalResistance = Double(sum) / Double(weightedRa.count)
        }

        // Gauge State of Charge (check multiple locations)
        if let gaugeSoC = firstInt("GaugeSOC") {
            data.gaugeSoC = gaugeSoC
        } else if let stateOfCharge = firstInt("StateOfCharge") {
            data.gaugeSoC = stateOfCharge
        }

        // Virtual temperature
        if data.virtualTemperature == nil, let virtualTemp = firstInt("VirtualTemperature") {
            switch source {
            case .rootBattery:
                data.virtualTemperature = legacyTemperatureCelsius(virtualTemp)
            case .batteryPack:
                data.virtualTemperature = packTemperatureCelsius(virtualTemp)
            }
        }

        // Chemistry ID (check both root and BatteryData)
        if let chemID = firstInt("ChemID") {
            data.chemID = chemID
            data.chemistry = decodeChemID(chemID)
        }

        // Device Name (battery chip model like "bq40z651")
        if let deviceName = firstString("DeviceName"), data.deviceName == nil {
            data.deviceName = deviceName
        }

        if let serial = firstString("Serial"), data.serialNumber == nil {
            data.serialNumber = serial
        }

        // Manufacturing info
        if let mfgData = firstData("ManufacturerData") ?? firstData("MfgData") {
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
        if data.manufactureDate == nil, let mfgDate = firstInt64("ManufactureDate") {
            data.manufactureDate = decodeManufactureDate(mfgDate)

            // Calculate battery age in days
            if let dateStr = data.manufactureDate {
                data.batteryAgeDays = calculateBatteryAgeDays(from: dateStr)
            }
        }

        // Gas Gauge Firmware version from IORegistry
        if let fwVersion = firstInt("GasGaugeFirmwareVersion"), data.gasGaugeFirmwareVersion == nil {
            data.gasGaugeFirmwareVersion = String(format: "v%d", fwVersion)
        }

        // Status flags
        if let permFailure = firstInt("PermanentFailureStatus"), data.permanentFailureStatus == nil {
            data.permanentFailureStatus = permFailure
        }

        if let gaugeFlag = firstInt("GaugeFlagRaw"), data.gaugeFlagRaw == nil {
            data.gaugeFlagRaw = gaugeFlag
        }

        if let miscStatus = firstInt("MiscStatus"), data.miscStatus == nil {
            data.miscStatus = miscStatus
        }

        // Pack reserve
        if let packReserve = firstInt("PackReserve"), data.packReserve == nil {
            data.packReserve = packReserve
        }

        // Critical level
        if let atCritical = firstBool("AtCriticalLevel") {
            data.atCriticalLevel = atCritical
        }

        // Best charger port (BestAdapterIndex in IORegistry)
        if let bestPort = firstInt("BestAdapterIndex"), data.bestChargerPort == nil {
            data.bestChargerPort = bestPort
        }

        if let rsenseOpen = firstInt("BatteryRsenseOpenCount"), data.rsenseOpenCount == nil {
            data.rsenseOpenCount = rsenseOpen
        }

        if let gaugeWrites = firstInt("DataFlashWriteCount"), data.gaugeWriteCount == nil {
            data.gaugeWriteCount = gaugeWrites
        }

        if let gaugeStatus = firstInt("GaugeFlagRaw") ?? firstInt("GaugeStatus"), data.gaugeStatus == nil {
            data.gaugeStatus = gaugeStatus
        }

        if let postCharge = firstInt("PostChargeWaitSeconds"), data.postChargeWaitSeconds == nil {
            data.postChargeWaitSeconds = postCharge
        }

        if let postDischarge = firstInt("PostDischargeWaitSeconds"), data.postDischargeWaitSeconds == nil {
            data.postDischargeWaitSeconds = postDischarge
        }

        if let invalidWake = firstInt("InvalidWakeSeconds") ?? (props["BatteryInvalidWakeSeconds"] as? Int),
           data.invalidWakeSeconds == nil {
            data.invalidWakeSeconds = invalidWake
        }

        if let chargeAccum = firstInt("ChargeAccum") ?? firstInt("ChargeAccumulated"), data.chargeAccumulated == nil {
            data.chargeAccumulated = chargeAccum
        }

        if let dailyMax = firstInt("DailyMaxSoc"), data.dailyChargeMax == nil {
            data.dailyChargeMax = dailyMax
        }
        if let dailyMin = firstInt("DailyMinSoc"), data.dailyChargeMin == nil {
            data.dailyChargeMin = dailyMin
        }

        if let carrierMode = firstDictionary("CarrierMode") ?? (props["CarrierMode"] as? [String: Any]),
           data.shippingModeVoltageMax == nil {
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
        if let cellDisconnect = firstInt("BatteryCellDisconnectCount"), data.cellDisconnectCount == nil {
            data.cellDisconnectCount = cellDisconnect
        }

        // Health
        if let batteryHealth = firstString("BatteryHealth") {
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
        if let lifetime = firstDictionary("LifetimeData") {
            // Total operating time (already in minutes)
            if let totalTime = lifetime["TotalOperatingTime"] as? Int, data.totalOperatingTime == nil {
                data.totalOperatingTime = totalTime  // Already in minutes
            }

            // Average temperature (deciCelsius - tenths of degree Celsius)
            if let avgTemp = lifetime["AverageTemperature"] as? Int, data.averageTemperature == nil {
                data.averageTemperature = Double(avgTemp) / 10.0
            }

            // Maximum temperature (Celsius)
            if let maxTemp = lifetime["MaximumTemperature"] as? Int, data.maximumTemperature == nil {
                data.maximumTemperature = Double(maxTemp)
            }

            // Minimum temperature (Celsius)
            if let minTemp = lifetime["MinimumTemperature"] as? Int, data.minimumTemperature == nil {
                data.minimumTemperature = Double(minTemp)
            }

            // Cycle count at last Qmax calibration
            if let cycleLastQmax = lifetime["CycleCountLastQmax"] as? Int, data.cycleCountLastQmax == nil {
                data.cycleCountLastQmax = cycleLastQmax
            }

            // Gauge measured maximum capacity (can be Int or array)
            if let qmax = lifetime["Qmax"] as? Int, data.gaugeQmax == nil {
                data.gaugeQmax = qmax
            } else if data.gaugeQmax == nil, let qmaxArray = lifetime["Qmax"] as? [Int], qmaxArray.count > 0 {
                // Average the Qmax values
                let sum = qmaxArray.reduce(0, +)
                data.gaugeQmax = sum / qmaxArray.count
            }
        }

        // Also check for Qmax at BatteryData level (not just LifetimeData)
        if data.gaugeQmax == nil, let qmax = firstInt("Qmax") {
            data.gaugeQmax = qmax
        } else if data.gaugeQmax == nil, let qmaxArray = batteryProps?["Qmax"] as? [Int], qmaxArray.count > 0 {
            let sum = qmaxArray.reduce(0, +)
            data.gaugeQmax = sum / qmaxArray.count
        }

        if data.designCycleCount == 1000, let designCycles = firstInt("DesignCycleCount9C"), designCycles > 0 {
            data.designCycleCount = designCycles
        }

        // PowerTelemetryData - real-time power metrics and accumulated energy
        if let ptd = firstDictionary("PowerTelemetryData") {
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
                data.adapterCurrent = signedMilliamps(adapterCurrent) / 1000.0  // mA to A
            }

            // Real-time adapter power input (from SystemPowerIn)
            if let adapterPower = ptd["SystemPowerIn"] as? Int {
                data.adapterPower = Double(adapterPower) / 1000.0  // mW to W
            }

            // Real-time system load (from SystemLoad)
            if let systemLoad = ptd["SystemLoad"] as? Int {
                data.systemLoadPower = Double(systemLoad) / 1000.0  // mW to W
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
