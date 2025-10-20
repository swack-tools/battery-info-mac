import Foundation

// MARK: - Battery Data Decoders

/// Decoders for converting hex/raw values to human-readable strings
struct BatteryDecoders {

    // MARK: - Charger Configuration

    /// Decode ChargerConfiguration bit flags
    ///
    /// NOTE: Apple does not document the meaning of ChargerConfiguration bits.
    /// This decoder only shows which bits are set without interpretation.
    static func decodeChargerConfig(_ config: Int) -> String {
        var activeBits: [Int] = []

        for bit in 0..<16 {
            if (config & (1 << bit)) != 0 {
                activeBits.append(bit)
            }
        }

        let bitsStr = activeBits.map { String($0) }.joined(separator: ", ")
        let result = String(format: "0x%04X (bits: %@)", config, bitsStr)

        if !activeBits.isEmpty {
            return result + "\n                     ⚠️  Bit meanings undocumented by Apple"
        }

        return result
    }

    // MARK: - Gauge Flags

    /// Decode GaugeFlagRaw bit flags
    static func decodeGaugeFlags(_ flags: Int) -> String {
        if flags == 0 {
            return "None (0x00)"
        }

        let flagBits: [Int: String] = [
            0x0001: "Discharge Detected",
            0x0002: "Charge Termination",
            0x0004: "Overcharge Detection",
            0x0008: "Terminate Discharge Alarm",
            0x0010: "Over-Temperature Alarm",
            0x0020: "Terminate Charge Alarm",
            0x0040: "Impedance Measured",
            0x0080: "Fully Charged (fast charge complete, trickle charging)",
            0x0100: "Discharge Inhibit",
            0x0200: "Charge Inhibit",
            0x0400: "Voltage OK (VOK)",
            0x0800: "Ready (RDY)",
            0x1000: "Qualified for Use (QEN)",
            0x2000: "Fast Charge OK",
            0x4000: "Battery Present",
            0x8000: "Valid Data"
        ]

        var activeFlags: [String] = []
        for (bit, desc) in flagBits {
            if (flags & bit) != 0 {
                activeFlags.append(desc)
            }
        }

        if !activeFlags.isEmpty {
            return activeFlags.joined(separator: ", ") + String(format: " (0x%04X)", flags)
        } else {
            return String(format: "0x%04X", flags)
        }
    }

    // MARK: - Misc Status

    /// Decode MiscStatus bit flags
    ///
    /// NOTE: Apple does not document the meaning of MiscStatus bits.
    /// This decoder only shows which bits are set without interpretation.
    static func decodeMiscStatus(_ status: Int) -> String {
        if status == 0 {
            return "None (0x00)"
        }

        var activeBits: [Int] = []

        for bit in 0..<16 {
            if (status & (1 << bit)) != 0 {
                activeBits.append(bit)
            }
        }

        let bitsStr = activeBits.map { String($0) }.joined(separator: ", ")
        return String(format: "0x%04X (bits: %@)", status, bitsStr)
    }

    // MARK: - Permanent Failure Status

    /// Decode PermanentFailureStatus bit flags
    static func decodePermanentFailure(_ status: Int) -> String {
        if status == 0 {
            return "None (battery healthy)"
        }

        let failures: [Int: String] = [
            0x0001: "Cell imbalance failure",
            0x0002: "Safety circuit failure",
            0x0004: "Charge FET failure",
            0x0008: "Discharge FET failure",
            0x0010: "Thermistor failure",
            0x0020: "Fuse blown",
            0x0040: "AFE (Analog Front End) failure",
            0x0080: "Cell failure",
            0x0100: "Over-temperature failure",
            0x0200: "Under-temperature failure"
        ]

        var activeFailures: [String] = []
        for (bit, desc) in failures {
            if (status & bit) != 0 {
                activeFailures.append(desc)
            }
        }

        if !activeFailures.isEmpty {
            return "⚠️  " + activeFailures.joined(separator: ", ") + String(format: " (0x%04X)", status)
        } else {
            return String(format: "⚠️  Unknown failure (0x%04X)", status)
        }
    }

    // MARK: - Not Charging Reason

    /// Decode NotChargingReason
    static func decodeNotChargingReason(_ reason: Int) -> String {
        if reason == 0 {
            return "None (charging normally)"
        }

        let reasons: [Int: String] = [
            0x0001: "Battery fully charged",
            0x0002: "Optimized Battery Charging active",
            0x0004: "Battery too hot",
            0x0008: "Battery too cold",
            0x0010: "Charging suspended (system load)",
            0x0020: "Battery health management",
            0x0040: "Charge limit reached (80%)",
            0x0080: "Adapter insufficient power",
            0x0100: "System using more than adapter provides",
            0x0200: "Waiting for optimal charging time"
        ]

        var activeReasons: [String] = []
        for (bit, desc) in reasons {
            if (reason & bit) != 0 {
                activeReasons.append(desc)
            }
        }

        if !activeReasons.isEmpty {
            return activeReasons.joined(separator: ", ") + String(format: " (0x%04X)", reason)
        } else {
            return String(format: "Unknown (0x%04X)", reason)
        }
    }

    // MARK: - Charger Inhibit Reason

    /// Decode ChargerInhibitReason
    static func decodeChargerInhibitReason(_ reason: Int) -> String {
        if reason == 0 {
            return "None"
        }

        let reasons: [Int: String] = [
            1: "Battery too hot",
            2: "Battery too cold",
            4: "System thermal limiting",
            8: "Optimized battery charging",
            16: "Battery charge limit (80%)",
            32: "Adapter insufficient",
            64: "Battery health protection"
        ]

        var activeReasons: [String] = []
        for (bit, desc) in reasons {
            if (reason & bit) != 0 {
                activeReasons.append(desc)
            }
        }

        if !activeReasons.isEmpty {
            return activeReasons.joined(separator: ", ")
        } else {
            return String(format: "Unknown (0x%02X)", reason)
        }
    }

    // MARK: - Time Formatting

    /// Format time in minutes to human-readable string
    static func formatTime(_ minutes: Int?) -> String {
        guard let minutes = minutes, minutes > 0 else {
            return "Calculating..."
        }

        if minutes == -1 || minutes >= 1440 {  // >= 24 hours
            return "Calculating..."
        }

        let hours = minutes / 60
        let mins = minutes % 60

        if hours > 0 {
            return String(format: "%d:%02d", hours, mins)
        } else {
            return String(format: "%d min", mins)
        }
    }

    // MARK: - Temperature Assessment

    /// Get temperature assessment color and description
    static func assessTemperature(_ celsius: Double) -> (color: String, description: String) {
        switch celsius {
        case ..<0:
            return ("🔵", "Very Cold")
        case 0..<20:
            return ("❄️", "Cold")
        case 20..<35:
            return ("✅", "Normal")
        case 35..<45:
            return ("⚠️", "Warm")
        case 45..<55:
            return ("🔥", "Hot")
        default:
            return ("🚨", "Very Hot")
        }
    }

    // MARK: - Capacity Assessment

    /// Get capacity assessment based on health percentage
    static func assessCapacity(_ healthPercent: Int) -> (emoji: String, description: String) {
        switch healthPercent {
        case 90...100:
            return ("✅", "Excellent")
        case 80..<90:
            return ("✅", "Good")
        case 70..<80:
            return ("⚠️", "Fair")
        case 60..<70:
            return ("⚠️", "Aging")
        default:
            return ("🔴", "Poor")
        }
    }

    // MARK: - Cycle Count Assessment

    /// Get cycle count assessment
    static func assessCycleCount(_ cycles: Int) -> (emoji: String, description: String) {
        switch cycles {
        case 0..<100:
            return ("✅", "Excellent")
        case 100..<300:
            return ("✅", "Good")
        case 300..<500:
            return ("⚠️", "Fair")
        case 500..<800:
            return ("⚠️", "Aging")
        default:
            return ("🔴", "High")
        }
    }

    // MARK: - Battery Age

    /// Calculate battery age from manufacture date
    static func calculateBatteryAge(from dateString: String) -> String? {
        // Parse date string (format: "YYYY-MM-DD" or "YYYY-MM-DD (Lot: X)")
        let components = dateString.components(separatedBy: " ")
        guard let dateStr = components.first else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let mfgDate = formatter.date(from: dateStr) else { return nil }

        let now = Date()
        let days = Calendar.current.dateComponents([.day], from: mfgDate, to: now).day ?? 0

        if days < 30 {
            return "\(days) days"
        } else if days < 365 {
            let months = days / 30
            return "\(days) days (\(months) months)"
        } else {
            let years = Double(days) / 365.25
            return String(format: "%d days (%.1f years)", days, years)
        }
    }

    // MARK: - Power Flow

    /// Format power flow string
    static func formatPowerFlow(adapterPower: Double?, batteryPower: Double?, systemLoad: Double?) -> String {
        var parts: [String] = []

        if let adapter = adapterPower {
            parts.append(String(format: "Adapter: %.1fW", adapter))
        }

        if let battery = batteryPower {
            if battery > 0 {
                parts.append(String(format: "Battery: +%.1fW (charging)", battery))
            } else if battery < 0 {
                parts.append(String(format: "Battery: %.1fW (discharging)", -battery))
            }
        }

        if let system = systemLoad {
            parts.append(String(format: "System: %.1fW", system))
        }

        return parts.joined(separator: " → ")
    }
}
