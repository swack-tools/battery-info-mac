import Foundation

public enum ThermalBand: String, Codable, Equatable, Sendable {
    case green
    case orange
    case red

    public static func band(for celsius: Double, component: String) -> ThermalBand {
        let name = component.lowercased()

        if name.contains("battery") {
            if celsius < 40 {
                return .green
            }
            if celsius < 45 {
                return .orange
            }
            return .red
        }

        if name.contains("ssd") || name.contains("storage") {
            if celsius < 50 {
                return .green
            }
            if celsius < 70 {
                return .orange
            }
            return .red
        }

        if celsius < 70 {
            return .green
        }
        if celsius < 90 {
            return .orange
        }
        return .red
    }
}

public struct ThermalReading: Codable, Equatable, Sendable {
    public var name: String
    public var celsius: Double
    public var band: ThermalBand
    public var source: String

    public init(name: String, celsius: Double, band: ThermalBand? = nil, source: String) {
        self.name = name
        self.celsius = celsius
        self.band = band ?? ThermalBand.band(for: celsius, component: name)
        self.source = source
    }
}

public struct ComponentPowerReading: Codable, Equatable, Sendable {
    public var name: String
    public var watts: Double
    public var source: String

    public init(name: String, watts: Double, source: String) {
        self.name = name
        self.watts = watts
        self.source = source
    }
}

public struct ThrottlingStatus: Codable, Equatable, Sendable {
    public var level: String
    public var percentage: Int
    public var source: String

    public init(level: String, percentage: Int, source: String) {
        self.level = level
        self.percentage = max(0, min(100, percentage))
        self.source = source
    }

    public static func nominal(source: String) -> ThrottlingStatus {
        ThrottlingStatus(level: "Nominal", percentage: 0, source: source)
    }
}

public struct ThermalSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var thermalReadings: [ThermalReading]
    public var componentPowers: [ComponentPowerReading]
    public var throttling: ThrottlingStatus
    public var thermalPressure: String?
    public var messages: [String]

    public init(
        generatedAt: Date,
        thermalReadings: [ThermalReading] = [],
        componentPowers: [ComponentPowerReading] = [],
        throttling: ThrottlingStatus = .nominal(source: "unknown"),
        thermalPressure: String? = nil,
        messages: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.thermalReadings = thermalReadings
        self.componentPowers = componentPowers
        self.throttling = throttling
        self.thermalPressure = thermalPressure
        self.messages = messages
    }
}

public enum PMSetThermalParser {
    public static func parse(_ output: String) -> ThrottlingStatus {
        let normalized = output.lowercased()

        if normalized.contains("no thermal warning level")
            && normalized.contains("no performance warning level") {
            return .nominal(source: "pmset")
        }

        if let percentage = firstPercentage(in: normalized) {
            return ThrottlingStatus(
                level: level(for: percentage, pressure: normalized),
                percentage: percentage,
                source: "pmset"
            )
        }

        if normalized.contains("heavy") || normalized.contains("critical") {
            return ThrottlingStatus(level: "Heavy", percentage: 90, source: "pmset")
        }
        if normalized.contains("moderate") {
            return ThrottlingStatus(level: "Moderate", percentage: 60, source: "pmset")
        }
        if normalized.contains("light") {
            return ThrottlingStatus(level: "Light", percentage: 30, source: "pmset")
        }

        return .nominal(source: "pmset")
    }
}

public enum PowermetricsThermalParser {
    public static func parse(_ output: String, generatedAt: Date = Date()) -> ThermalSnapshot {
        var powers: [ComponentPowerReading] = []
        var readings: [ThermalReading] = []
        var thermalPressure: String?
        var powerLimitPercentages: [Int] = []
        var forcedIdlePercentages: [Int] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = line.lowercased()

            if let power = parseComponentPower(line) {
                powers.append(power)
            }

            if let reading = parseTemperature(line) {
                readings.append(reading)
            }

            if lowercased.contains("thermal pressure"),
               let pressure = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pressure.isEmpty {
                thermalPressure = normalizedLevelName(pressure)
            }

            if lowercased.contains("power limit"),
               let percentage = firstPercentage(in: lowercased) {
                powerLimitPercentages.append(percentage)
            }

            if lowercased.contains("forced idle"),
               let percentage = firstPercentage(in: lowercased) {
                forcedIdlePercentages.append(percentage)
            }
        }

        let throttlingPercentage =
            powerLimitPercentages.max()
            ?? forcedIdlePercentages.max()
            ?? pressurePercentage(for: thermalPressure)
            ?? 0

        return ThermalSnapshot(
            generatedAt: generatedAt,
            thermalReadings: readings,
            componentPowers: powers,
            throttling: ThrottlingStatus(
                level: level(for: throttlingPercentage, pressure: thermalPressure?.lowercased() ?? ""),
                percentage: throttlingPercentage,
                source: throttlingPercentage > 0 ? "powermetrics" : "powermetrics"
            ),
            thermalPressure: thermalPressure
        )
    }

    private static func parseComponentPower(_ line: String) -> ComponentPowerReading? {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let label = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.hasSuffix(" Power") else { return nil }

        let name = label.replacingOccurrences(of: " Power", with: "")
        guard ["CPU", "GPU", "ANE", "DRAM"].contains(name),
              let valueRange = parts[1].range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
              let milliwatts = Double(parts[1][valueRange]) else {
            return nil
        }

        return ComponentPowerReading(name: name, watts: milliwatts / 1000.0, source: "powermetrics")
    }

    private static func parseTemperature(_ line: String) -> ThermalReading? {
        let lowercased = line.lowercased()
        guard lowercased.contains("temperature") else { return nil }

        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2,
              let valueRange = parts[1].range(of: #"-?[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
              let celsius = Double(parts[1][valueRange]) else {
            return nil
        }

        let rawName = parts[0]
            .replacingOccurrences(of: "temperature", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let name = normalizedSensorName(rawName.isEmpty ? "Thermal Sensor" : rawName)
        return ThermalReading(name: name, celsius: celsius, source: "powermetrics")
    }
}

private func firstPercentage(in text: String) -> Int? {
    guard let range = text.range(of: #"[0-9]{1,3}\s*%"#, options: .regularExpression) else {
        return nil
    }

    let digits = text[range].filter(\.isNumber)
    return Int(String(digits))
}

private func level(for percentage: Int, pressure: String) -> String {
    let normalized = pressure.lowercased()

    if normalized.contains("heavy") || normalized.contains("critical") {
        return "Heavy"
    }
    if normalized.contains("moderate") {
        return "Moderate"
    }
    if normalized.contains("light") {
        return "Light"
    }
    if percentage >= 80 {
        return "Heavy"
    }
    if percentage >= 40 {
        return "Moderate"
    }
    if percentage > 0 {
        return "Light"
    }
    return "Nominal"
}

private func normalizedLevelName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "Unknown" }
    return first.uppercased() + trimmed.dropFirst().lowercased()
}

private func pressurePercentage(for pressure: String?) -> Int? {
    guard let pressure else { return nil }
    switch pressure.lowercased() {
    case let value where value.contains("heavy") || value.contains("critical"):
        return 90
    case let value where value.contains("moderate"):
        return 60
    case let value where value.contains("light"):
        return 30
    default:
        return nil
    }
}

private func normalizedSensorName(_ name: String) -> String {
    let knownUppercase = ["CPU", "GPU", "ANE", "DRAM", "SSD"]
    return name
        .split(separator: " ")
        .map { part in
            let value = String(part)
            let uppercased = value.uppercased()
            if knownUppercase.contains(uppercased) {
                return uppercased
            }
            return value.prefix(1).uppercased() + value.dropFirst().lowercased()
        }
        .joined(separator: " ")
}
