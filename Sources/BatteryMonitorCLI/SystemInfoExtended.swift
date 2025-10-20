import Foundation
import IOKit
import IOKit.ps

// MARK: - Extended System Information Gathering

extension SystemCommands {

    // MARK: - Display Information

    /// Get display brightness and power information
    static func getDisplayInfo() -> DisplayInfo? {
        var displayInfo = DisplayInfo()

        // Try to get brightness from IODisplay
        let matching = IOServiceMatching("IODisplayConnect")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)

            if result == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] {
                if let params = props["IODisplayParameters"] as? [String: Any],
                   let brightness = params["brightness"] as? [String: Any],
                   let value = brightness["value"] as? Int,
                   let max = brightness["max"] as? Int, max > 0 {
                    displayInfo.brightness = (Double(value) / Double(max)) * 100.0
                    displayInfo.estimatedPower = (displayInfo.brightness / 100.0) * displayInfo.maxPower
                    return displayInfo
                }
            }

            service = IOIteratorNext(iterator)
        }

        // Fallback: estimate 50% brightness
        displayInfo.brightness = 50.0
        displayInfo.estimatedPower = 3.0  // 50% of 6W
        return displayInfo
    }

    // MARK: - USB Port Information

    /// Get USB port wake/sleep current information
    static func getUSBPortInfo() -> USBPortInfo? {
        // Query pmset for USB current limits
        guard let output = runCommand("/usr/bin/pmset", arguments: ["-g", "custom"]) else {
            return nil
        }

        var usbInfo = USBPortInfo()

        // Parse USB current from pmset output
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("USB") && line.contains("wake") {
                // Extract current value if present
                if let match = line.range(of: "\\d+", options: .regularExpression) {
                    if let value = Double(line[match]) {
                        usbInfo.wakeCurrent = value / 1000.0  // mA to A
                    }
                }
            }
        }

        // Default values from IORegistry (typical MacBook values)
        if usbInfo.wakeCurrent == 0 {
            usbInfo.wakeCurrent = 3.0  // 3A typical
            usbInfo.sleepCurrent = 3.0
        }

        return usbInfo
    }

    // MARK: - Power Management Information

    /// Get comprehensive power management settings
    static func getPowerManagementInfo() -> PowerManagementInfo? {
        var pmInfo = PowerManagementInfo()

        // Get pmset settings
        if let output = runCommand("/usr/bin/pmset", arguments: ["-g", "live"]) {
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.contains("lowpowermode") {
                    pmInfo.lowPowerMode = trimmed.contains("1")
                }

                if trimmed.contains("hibernatemode") {
                    if let match = trimmed.range(of: "\\d+", options: .regularExpression),
                       let mode = Int(trimmed[match]) {
                        pmInfo.hibernationMode = decodeHibernationMode(mode)
                    }
                }

                if trimmed.contains("womp") {
                    pmInfo.wakeOnLAN = trimmed.contains("1")
                }

                if trimmed.contains("powernap") {
                    pmInfo.powerNap = trimmed.contains("1")
                }

                if trimmed.contains("displaysleep") {
                    if let match = trimmed.range(of: "\\d+", options: .regularExpression),
                       let minutes = Int(trimmed[match]) {
                        pmInfo.displaySleepMinutes = minutes
                    }
                }
            }
        }

        // Get active power assertions (only those with "named:" - matching Python behavior)
        if let output = runCommand("/usr/bin/pmset", arguments: ["-g", "assertions"]) {
            let lines = output.components(separatedBy: .newlines)
            var assertions: [String] = []

            for line in lines {
                // Only capture lines with active assertions (contains "named:")
                if line.contains("named:") &&
                   (line.contains("PreventUserIdleSystemSleep") ||
                    line.contains("PreventSystemSleep") ||
                    line.contains("PreventUserIdleDisplaySleep")) {
                    // Extract assertion type and name
                    // Format: "pid 338(powerd): [0x...] time PreventUserIdleSystemSleep named: "Name""
                    if let typeRange = line.range(of: "Prevent\\w+", options: .regularExpression),
                       let namedRange = line.range(of: "named:\\s*\"([^\"]+)\"", options: .regularExpression) {
                        let type = String(line[typeRange])
                        let nameMatch = line[namedRange]
                        let name = nameMatch.replacingOccurrences(of: "named:", with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))

                        // Simplify common assertion names
                        let simplifiedName = simplifyAssertionName(name)
                        assertions.append("\(type): \(simplifiedName)")
                    }
                }
            }

            pmInfo.activeAssertions = Array(assertions.prefix(10))  // Limit to 10
        }

        // Get power source history and sleep/wake history (using pmset -g log)
        // Optimized: Use grep to filter before reading all lines (much faster)
        if let powerOutput = runCommand("/bin/sh", arguments: ["-c", "/usr/bin/pmset -g log | /usr/bin/grep -E '(Using AC|Using Batt)' | /usr/bin/tail -20"]) {
            let lines = powerOutput.components(separatedBy: .newlines)
            var history: [String] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // Extract timestamp and power source type (matching Python format)
                    // Format: "YYYY-MM-DD HH:MM:SS ... Using AC/Batt ..."
                    if let timeRange = trimmed.range(of: "\\d{2}:\\d{2}:\\d{2}", options: .regularExpression) {
                        let time = String(trimmed[timeRange])
                        let source = trimmed.contains("Using AC") ? "AC Power" : "Battery"
                        history.append("\(time): \(source)")
                    }
                }
            }

            pmInfo.powerSourceHistory = Array(history.suffix(5))  // Last 5 events
        }

        if let sleepOutput = runCommand("/bin/sh", arguments: ["-c", "/usr/bin/pmset -g log | /usr/bin/grep -E '(Sleep|Wake|DarkWake)' | /usr/bin/tail -20"]) {
            let lines = sleepOutput.components(separatedBy: .newlines)
            var sleepWake: [String] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // Extract timestamp and event type (matching Python format)
                    // Format: "YYYY-MM-DD HH:MM:SS ... Sleep/Wake/DarkWake ..."
                    if let timeRange = trimmed.range(of: "\\d{2}:\\d{2}:\\d{2}", options: .regularExpression) {
                        let time = String(trimmed[timeRange])
                        let event = trimmed.contains("DarkWake") ? "DarkWake" : (trimmed.contains("Sleep") ? "Sleep" : "Wake")
                        sleepWake.append("\(time): \(event)")
                    }
                }
            }

            pmInfo.sleepWakeHistory = Array(sleepWake.suffix(5))  // Last 5 events
        }

        // Get scheduled events
        if let output = runCommand("/usr/bin/pmset", arguments: ["-g", "sched"]) {
            let lines = output.components(separatedBy: .newlines)
            var scheduled: [String] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.starts(with: "Scheduled") {
                    scheduled.append(trimmed)
                }
            }

            pmInfo.scheduledEvents = scheduled
        }

        return pmInfo
    }

    private static func decodeHibernationMode(_ mode: Int) -> String {
        switch mode {
        case 0: return "Disabled"
        case 3: return "Safe sleep (default)"
        case 25: return "Hibernatefile"
        default: return "Mode \(mode)"
        }
    }

    // MARK: - USB-C Power Delivery Information

    /// Get USB-C Power Delivery information from IORegistry
    static func getUSBCPDInfo() -> USBCPDInfo? {
        var pdInfo = USBCPDInfo()

        // First, get PD version from AppleSmartBattery's FedDetails (matching Python behavior)
        let batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if batteryService != 0 {
            defer { IOObjectRelease(batteryService) }

            var batteryProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(batteryService, &batteryProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = batteryProps?.takeRetainedValue() as? [String: Any],
               let fedDetails = props["FedDetails"] as? [[String: Any]],
               !fedDetails.isEmpty {

                // Use first port's FedDetails (matching Python's active_port_idx logic)
                let fed = fedDetails[0]

                // PD Spec Revision (0=1.0, 1=2.0, 2=3.0, 3=3.1)
                if let pdRev = fed["FedPdSpecRevision"] as? Int {
                    let pdVersionMap: [Int: String] = [0: "1.0", 1: "2.0", 2: "3.0", 3: "3.1"]
                    if let version = pdVersionMap[pdRev] {
                        pdInfo.pdSpecification = "USB PD \(version)"
                        // Debug: print("Set PD Spec to: USB PD \(version)")
                    } else {
                        pdInfo.pdSpecification = "USB PD \(pdRev)"
                    }
                } else {
                    // Debug: print("FedPdSpecRevision not found or wrong type")
                }
            }
        }

        // Search for AppleTypeCPortController service
        let matching = IOServiceMatching("AppleTypeCPortController")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }

        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        // Extract PD information (fallback to PDSpecification if FedDetails not available)
        if pdInfo.pdSpecification == nil, let pdSpec = props["PDSpecification"] as? String {
            pdInfo.pdSpecification = pdSpec
        }

        if let powerRole = props["PowerRole"] as? String {
            pdInfo.powerRole = powerRole
        }

        if let dataRole = props["DataRole"] as? String {
            pdInfo.dataRole = dataRole
        }

        if let rdo = props["ActiveRDO"] as? Int {
            pdInfo.activeRDO = String(format: "0x%08X", rdo)
        }

        if let selectedPDO = props["SelectedPDO"] as? Int {
            pdInfo.selectedPDO = selectedPDO
        }

        if let current = props["OperatingCurrent"] as? Int {
            pdInfo.operatingCurrent = Double(current) / 1000.0  // mA to A
        }

        if let maxCurrent = props["MaxCurrent"] as? Int {
            pdInfo.maxCurrent = Double(maxCurrent) / 1000.0  // mA to A
        }

        if let fwVersion = props["PortFWVersion"] as? String {
            pdInfo.portFWVersion = fwVersion
        }

        if let numPDOs = props["NumberOfPDOs"] as? Int {
            pdInfo.numberOfPDOs = numPDOs
        }

        if let numEPR = props["NumberOfEPRPDOs"] as? Int {
            pdInfo.numberOfEPRPDOs = numEPR
        }

        if let portMode = props["PortMode"] as? String {
            pdInfo.portMode = portMode
        }

        if let powerState = props["PowerState"] as? Int {
            pdInfo.powerState = String(format: "0x%02X", powerState)
        }

        // Parse sink capabilities (PDOs)
        if let sinkCaps = props["SinkCapabilities"] as? [Int] {
            for (index, pdo) in sinkCaps.enumerated() {
                if let capability = parsePDO(pdo, number: index + 1) {
                    pdInfo.sinkCapabilities.append(capability)
                }
            }
        }

        return pdInfo.numberOfPDOs > 0 ? pdInfo : nil
    }

    private static func parsePDO(_ pdo: Int, number: Int) -> PDOCapability? {
        // PDO format (simplified):
        // Bits 31-30: Type (00=Fixed, 01=Battery, 10=Variable, 11=APDO/PPS)
        // Bits 29-20: Voltage (50mV units)
        // Bits 9-0: Current (10mA units)

        let pdoType = (pdo >> 30) & 0x3

        if pdoType == 0 {  // Fixed Supply
            let voltage = Double((pdo >> 10) & 0x3FF) * 0.05  // 50mV units
            let current = Double(pdo & 0x3FF) * 0.01  // 10mA units
            let power = voltage * current

            return PDOCapability(
                pdoNumber: number,
                voltage: voltage,
                current: current,
                power: power,
                isPPS: false
            )
        } else if pdoType == 3 {  // APDO (PPS)
            let maxVoltage = Double((pdo >> 17) & 0xFF) * 0.1  // 100mV units
            let minVoltage = Double((pdo >> 8) & 0xFF) * 0.1   // 100mV units
            let maxCurrent = Double(pdo & 0x7F) * 0.05  // 50mA units

            return PDOCapability(
                pdoNumber: number,
                voltage: (minVoltage + maxVoltage) / 2.0,  // Average
                current: maxCurrent,
                power: maxVoltage * maxCurrent,
                isPPS: true,
                ppsMinVoltage: minVoltage,
                ppsMaxVoltage: maxVoltage
            )
        }

        return nil
    }

    /// Simplify cryptic power assertion names to human-readable format
    private static func simplifyAssertionName(_ name: String) -> String {
        // Check for common system assertions
        if name.contains("Powerd") && name.lowercased().contains("display") {
            return "Display active (system)"
        }
        if name.contains("Powerd") {
            return "System power management"
        }
        if name.lowercased().contains("kernel") {
            return "Kernel task"
        }
        if name.lowercased().contains("coreaudio") {
            return "Audio playback"
        }

        // Extract app bundle ID if present (e.g., application.com.apple.MobileSMS)
        if let appRange = name.range(of: "application\\.com\\.apple\\.([A-Za-z]+)", options: .regularExpression) {
            let appMatch = name[appRange]
            let appName = appMatch.replacingOccurrences(of: "application.com.apple.", with: "")

            // Map common app names
            let appNames: [String: String] = [
                "MobileSMS": "Messages",
                "Safari": "Safari",
                "Music": "Music",
                "Mail": "Mail",
                "Photos": "Photos",
                "FaceTime": "FaceTime"
            ]

            let readableName = appNames[appName] ?? appName
            return "\(readableName) app"
        }

        // If no simplification possible, return cleaned up version (truncate if too long)
        if name.count > 60 {
            return String(name.prefix(57)) + "..."
        }
        return name
    }
}
