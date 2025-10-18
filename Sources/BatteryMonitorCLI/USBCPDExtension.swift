import Foundation
import IOKit
import IOKit.ps

// MARK: - USB-C PD Extraction Extension

extension IOKitBattery {

    /// Get USB-C Power Delivery information from AppleSmartBattery PortControllerInfo
    static func getUSBCPDInfoFromBattery() -> USBCPDInfo? {
        guard let service = getAppleSmartBatteryService() else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        // Get PortControllerInfo array
        guard let portInfo = props["PortControllerInfo"] as? [[String: Any]], !portInfo.isEmpty else {
            return nil
        }

        // Find the active port (the one with non-zero RDO and MaxPower)
        var activePortIdx: Int? = nil
        var fallbackPortIdx: Int? = nil

        for (idx, port) in portInfo.enumerated() {
            if let rdo = port["PortControllerActiveContractRdo"] as? Int, rdo != 0 {
                if let maxPower = port["PortControllerMaxPower"] as? Int, maxPower > 0 {
                    activePortIdx = idx
                    break
                } else if fallbackPortIdx == nil {
                    fallbackPortIdx = idx
                }
            }
        }

        let activeIdx = activePortIdx ?? fallbackPortIdx
        guard let idx = activeIdx, idx < portInfo.count else {
            return nil
        }

        let port = portInfo[idx]
        var pdInfo = USBCPDInfo()

        // Extract PD information from active port
        if let rdo = port["PortControllerActiveContractRdo"] as? Int {
            pdInfo.activeRDO = String(format: "0x%08X", rdo)

            // Decode Selected PDO from RDO (bits 30-28 contain PDO position)
            let selectedPDO = (rdo >> 28) & 0x7
            if selectedPDO > 0 {
                pdInfo.selectedPDO = selectedPDO
            }

            // Decode Operating Current from RDO (bits 9-0 in 10mA units)
            let opCurrent = Double(rdo & 0x3FF) * 0.01  // 10mA units to A
            if opCurrent > 0 {
                pdInfo.operatingCurrent = opCurrent
            }

            // Decode Max Current from RDO (bits 19-10 in 10mA units)
            let maxCurrent = Double((rdo >> 10) & 0x3FF) * 0.01  // 10mA units to A
            if maxCurrent > 0 {
                pdInfo.maxCurrent = maxCurrent
            }
        }

        if let maxPower = port["PortControllerMaxPower"] as? Int {
            pdInfo.portMaxPower = Double(maxPower) / 1000.0  // mW to W
        }

        if let npdos = port["PortControllerNPDOs"] as? Int {
            pdInfo.numberOfPDOs = npdos
        }

        if let nepr = port["PortControllerNEprPDOs"] as? Int {
            pdInfo.numberOfEPRPDOs = nepr
        }

        if let portMode = port["PortControllerPortMode"] as? Int {
            pdInfo.portMode = decodePortMode(portMode)
        }

        if let powerState = port["PortControllerPowerState"] as? Int {
            pdInfo.powerState = String(format: "0x%02X", powerState)
        }

        if let fwVersion = port["PortControllerFwVersion"] as? Int {
            pdInfo.portFWVersion = String(format: "%d.%d.%d",
                (fwVersion >> 16) & 0xFF,
                (fwVersion >> 8) & 0xFF,
                fwVersion & 0xFF)
        }

        // Parse sink capabilities (PDOs)
        if let portPDOs = port["PortControllerPortPDO"] as? [Int] {
            for (index, pdo) in portPDOs.enumerated() {
                if pdo == 0 || pdo == 0xFFFFFFFF {
                    continue  // Skip invalid PDOs
                }
                if let capability = parsePDOFromPortController(pdo, number: index + 1) {
                    pdInfo.sinkCapabilities.append(capability)
                }
            }
        }

        // Get PD Specification from FedDetails (matching Python behavior)
        if let fedDetails = props["FedDetails"] as? [[String: Any]], idx < fedDetails.count {
            let fed = fedDetails[idx]

            // PD Spec Revision (0=1.0, 1=2.0, 2=3.0, 3=3.1)
            if let pdRev = fed["FedPdSpecRevision"] as? Int {
                let pdVersionMap: [Int: String] = [0: "1.0", 1: "2.0", 2: "3.0", 3: "3.1"]
                if let version = pdVersionMap[pdRev] {
                    pdInfo.pdSpecification = "USB PD \(version)"
                } else {
                    pdInfo.pdSpecification = "USB PD \(pdRev)"
                }
            } else {
                pdInfo.pdSpecification = "USB-C PD"  // Fallback
            }
        } else {
            pdInfo.pdSpecification = "USB-C PD"  // Fallback
        }

        pdInfo.powerRole = "Sink"
        pdInfo.dataRole = "UFP"

        return pdInfo.numberOfPDOs > 0 ? pdInfo : nil
    }

    /// Decode port mode
    private static func decodePortMode(_ mode: Int) -> String {
        switch mode {
        case 0: return "Unknown"
        case 1: return "UFP (Device)"
        case 2: return "DFP (Host)"
        case 3: return "DRP (Dual Role)"
        default: return "Mode \(mode)"
        }
    }

    /// Parse PDO from PortControllerPortPDO
    private static func parsePDOFromPortController(_ pdo: Int, number: Int) -> PDOCapability? {
        // PDO format (USB PD specification):
        // Bits 31-30: Type (00=Fixed, 01=Battery, 10=Variable, 11=APDO/PPS)
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
}
