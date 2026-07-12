import Foundation

public enum ThermalCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case cpu
    case gpu
    case battery
    case memory
    case storage
    case pmu
    case enclosure
    case system
    case unknown
}

public enum ThermalReadingKind: String, Codable, Equatable, Sendable {
    case temperature
    case thermalPressure
}

public enum ThermalClassification: String, Codable, Equatable, Sendable {
    case known
    case heuristic
    case unclassified
}

public enum ThermalSourceState: String, Codable, Equatable, Sendable {
    case success
    case partial
    case unavailable
    case failed
}

public struct DetailedThermalReading: Codable, Equatable, Sendable {
    public var source: String
    public var identifier: String
    public var label: String
    public var category: ThermalCategory
    public var kind: ThermalReadingKind
    public var numericValue: Double?
    public var textValue: String?
    public var unit: String?
    public var classification: ThermalClassification
    public var warnings: [String]

    public init(
        source: String,
        identifier: String,
        label: String,
        category: ThermalCategory,
        kind: ThermalReadingKind,
        numericValue: Double? = nil,
        textValue: String? = nil,
        unit: String? = nil,
        classification: ThermalClassification,
        warnings: [String] = []
    ) {
        self.source = source
        self.identifier = identifier
        self.label = label
        self.category = category
        self.kind = kind
        self.numericValue = numericValue
        self.textValue = textValue
        self.unit = unit
        self.classification = classification
        self.warnings = warnings
    }

    public static func temperature(
        source: String,
        identifier: String,
        label: String,
        category: ThermalCategory,
        celsius: Double,
        classification: ThermalClassification = .known,
        warnings: [String] = []
    ) -> DetailedThermalReading {
        DetailedThermalReading(
            source: source,
            identifier: identifier,
            label: label,
            category: category,
            kind: .temperature,
            numericValue: celsius,
            unit: "C",
            classification: classification,
            warnings: warnings
        )
    }
}

public struct ThermalSourceStatus: Codable, Equatable, Sendable {
    public var source: String
    public var state: ThermalSourceState
    public var readingCount: Int
    public var durationMilliseconds: Double
    public var warnings: [String]
    public var error: String?
    public var scannedRecordCount: Int?

    public init(
        source: String,
        state: ThermalSourceState,
        readingCount: Int,
        durationMilliseconds: Double,
        warnings: [String] = [],
        error: String? = nil,
        scannedRecordCount: Int? = nil
    ) {
        self.source = source
        self.state = state
        self.readingCount = readingCount
        self.durationMilliseconds = durationMilliseconds
        self.warnings = warnings
        self.error = error
        self.scannedRecordCount = scannedRecordCount
    }
}

public enum ThermalSummaryBuilder {
    private static let categoryOrder: [ThermalCategory] = [
        .cpu, .gpu, .battery, .memory, .storage, .pmu, .enclosure, .system, .unknown
    ]

    private static let excludedCurrentValueTerms = [
        "lifetime", "minimum", "maximum", "average"
    ]

    public static func build(from readings: [DetailedThermalReading]) -> [ThermalReading] {
        let candidates = readings.compactMap { reading -> Candidate? in
            guard reading.kind == .temperature,
                  let celsius = reading.numericValue,
                  isNormalizedCelsiusUnit(reading.unit),
                  celsius.isFinite,
                  isPlausible(celsius, for: reading.category),
                  !isAggregateOrLifetime(reading) else {
                return nil
            }

            return Candidate(reading: reading, celsius: celsius)
        }

        return categoryOrder.compactMap { category in
            let categoryCandidates = candidates.filter { $0.reading.category == category }
            guard !categoryCandidates.isEmpty else { return nil }

            let selectedSource = categoryCandidates
                .map(\.reading.source)
                .min { lhs, rhs in
                    let lhsRank = sourceRank(lhs, for: category)
                    let rhsRank = sourceRank(rhs, for: category)
                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }

                    let lhsNormalized = lhs.lowercased()
                    let rhsNormalized = rhs.lowercased()
                    if lhsNormalized != rhsNormalized {
                        return lhsNormalized < rhsNormalized
                    }
                    return lhs < rhs
                }

            guard let selectedSource,
                  let hottest = categoryCandidates
                    .filter({ $0.reading.source == selectedSource })
                    .max(by: { $0.celsius < $1.celsius }) else {
                return nil
            }

            return ThermalReading(
                name: stableName(for: category),
                celsius: hottest.celsius,
                source: hottest.reading.source
            )
        }
    }

    private static func isNormalizedCelsiusUnit(_ unit: String?) -> Bool {
        guard let unit else { return false }
        return ["c", "\u{00B0}c", "degc", "celsius"].contains(unit.lowercased())
    }

    private static func isPlausible(_ celsius: Double, for category: ThermalCategory) -> Bool {
        let upperBound = category == .battery ? 100.0 : 150.0
        return (-40.0...upperBound).contains(celsius)
    }

    private static func isAggregateOrLifetime(_ reading: DetailedThermalReading) -> Bool {
        let searchableText = "\(reading.identifier) \(reading.label)".lowercased()
        return excludedCurrentValueTerms.contains { searchableText.contains($0) }
    }

    private static func sourceRank(_ source: String, for category: ThermalCategory) -> Int {
        let source = source.lowercased()

        switch category {
        case .cpu, .gpu, .memory:
            if source.contains("smc") { return 0 }
            if source.contains("iohid") { return 1 }
            if source.contains("powermetrics") { return 2 }
        case .battery:
            if source.contains("applesmartbattery") || source.contains("iokit") { return 0 }
            if source.contains("smc") { return 1 }
            if source.contains("iohid") { return 2 }
            if source.contains("powermetrics") { return 3 }
        case .storage, .pmu, .enclosure, .system:
            if source.contains("iohid") { return 0 }
            if source.contains("smc") { return 1 }
            if source.contains("powermetrics") { return 2 }
        case .unknown:
            if source.contains("iohid") { return 0 }
            if source.contains("smc") { return 1 }
            if source.contains("powermetrics") { return 2 }
        }

        return 10
    }

    private static func stableName(for category: ThermalCategory) -> String {
        switch category {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .pmu: return "PMU"
        case .enclosure: return "Enclosure"
        case .system: return "System"
        case .unknown: return "Unknown"
        }
    }

    private struct Candidate {
        var reading: DetailedThermalReading
        var celsius: Double
    }
}
