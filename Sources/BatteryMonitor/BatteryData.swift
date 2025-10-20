import Foundation

// MARK: - Battery Data Models

struct BatteryData: Sendable {
    // Basic Info
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var currentCapacity: Int = 0
    var maxCapacity: Int = 0  // This may be a percentage (0-100) on some systems
    var appleRawMaxCapacity: Int = 0  // Actual max capacity in mAh
    var nominalChargeCapacity: Int = 0  // Rated/nominal capacity in mAh
    var designCapacity: Int = 0
    var cycleCount: Int = 0
    var health: String = "Unknown"
    var healthPercent: Int = 0
    var condition: String = "Unknown"

    // Voltage & Current
    var voltage: Double = 0.0  // V
    var amperage: Double = 0.0  // mA
    var temperature: Double = 0.0  // °C

    // Charging Info
    var timeToFull: Int? = nil  // minutes
    var timeToEmpty: Int? = nil  // minutes
    var isCharged: Bool = false
    var externalConnected: Bool = false

    // Advanced Battery Info
    var manufacturer: String?
    var serialNumber: String?
    var manufactureDate: String?
    var firmwareVersion: String?  // From system_profiler (e.g., "0b00")
    var gasGaugeFirmwareVersion: String?  // From IORegistry GasGaugeFirmwareVersion (e.g., "v2")
    var deviceName: String?

    // Cell Info
    var cellVoltage1: Double?
    var cellVoltage2: Double?
    var cellVoltage3: Double?
    var cellVoltage4: Double?
    var cellVoltageImbalance: Double?

    // Advanced Metrics
    var internalResistance: Double?  // mΩ
    var gaugeSoC: Int?  // State of Charge %
    var virtualTemperature: Double?  // °C
    var packVoltage: Double?  // V

    // Chemistry & Manufacturing
    var chemID: Int?
    var chemistry: String?

    // Status Flags
    var permanentFailureStatus: Int?
    var gaugeFlagRaw: Int?
    var miscStatus: Int?
    var packReserve: Int?  // mAh reserved by battery management
    var atCriticalLevel: Bool = false

    // Diagnostic Counts
    var cellDisconnectCount: Int?
    var rsenseOpenCount: Int?
    var gaugeWriteCount: Int?

    // Advanced Diagnostics
    var gaugeStatus: Int?
    var postChargeWaitSeconds: Int?
    var postDischargeWaitSeconds: Int?
    var invalidWakeSeconds: Int?
    var chargeAccumulated: Int?  // mAh
    var bestChargerPort: Int?

    // Battery Model Info
    var batteryModel: String?
    var batteryModelRevision: String?

    // Lifetime Statistics
    var totalOperatingTime: Int?  // minutes
    var averageTemperature: Double?  // °C
    var maximumTemperature: Double?  // °C
    var minimumTemperature: Double?  // °C
    var cycleCountLastQmax: Int?
    var gaugeQmax: Int?  // mAh

    // Additional fields for full parity
    var instantAmperage: Double = 0.0  // mA (instant reading)
    var avgTimeToEmpty: Int?  // minutes
    var avgTimeToFull: Int?  // minutes
    var designCycleCount: Int = 1000  // Design lifespan cycles
    var serviceRecommended: Bool = false

    // Gauge and daily charge info
    var dailyChargeMin: Int?  // %
    var dailyChargeMax: Int?  // %
    var shippingModeActive: Bool = false
    var shippingModeVoltageMin: Double?  // V
    var shippingModeVoltageMax: Double?  // V

    // Battery age
    var batteryAgeDays: Int?

    // PowerTelemetryData fields
    var accumulatedSystemEnergy: Int64?  // Raw value for lifetime energy (can be very large)
    var adapterVoltage: Double?  // V (real-time from PowerTelemetryData)
    var adapterCurrent: Double?  // A (real-time from PowerTelemetryData)
    var adapterPower: Double?  // W (real-time from PowerTelemetryData)
    var systemLoadPower: Double?  // W (real-time system load from PowerTelemetryData)

    // Computed
    var batteryPercentage: Int {
        // Prefer maxCapacity when it's a percentage (0-100) and currentCapacity is also 0-100
        // This is what macOS officially reports and rounds to user-friendly values
        if maxCapacity > 0 && maxCapacity <= 100 && currentCapacity >= 0 && currentCapacity <= 100 {
            return currentCapacity
        }

        // Use appleRawMaxCapacity (FCC in mAh) if available for mAh-based calculation
        if appleRawMaxCapacity > 0 && currentCapacity > 0 {
            return min(100, Int((Double(currentCapacity) / Double(appleRawMaxCapacity)) * 100))
        }

        // Fallback: calculate from currentCapacity and maxCapacity
        // Note: maxCapacity can be either mAh or percentage depending on system
        guard maxCapacity > 0 else { return 0 }

        // If maxCapacity is > 100, it's in mAh, calculate percentage
        if maxCapacity > 100 {
            return min(100, Int((Double(currentCapacity) / Double(maxCapacity)) * 100))
        }

        // Last resort
        return 0
    }

    // Get the actual FCC (Full Charge Capacity) in mAh
    var actualMaxCapacityMah: Int {
        if appleRawMaxCapacity > 0 {
            return appleRawMaxCapacity
        }
        // Fallback to maxCapacity if it's a real mAh value (> 100)
        if maxCapacity > 100 {
            return maxCapacity
        }
        return 0
    }

    var currentPower: Double {
        return voltage * amperage / 1000.0  // Watts
    }

    // Lifespan used percentage
    var lifespanUsedPercent: Double {
        return (Double(cycleCount) / Double(designCycleCount)) * 100.0
    }

    // Estimated cycles to 80% health
    var estimatedCyclesTo80Percent: Int? {
        guard healthPercent > 80 else { return 0 }
        let degradationPerCycle = Double(100 - healthPercent) / Double(max(cycleCount, 1))
        guard degradationPerCycle > 0 else { return nil }
        let cyclesTo80 = (Double(healthPercent) - 80.0) / degradationPerCycle
        return Int(cyclesTo80)
    }

    // Lifetime energy estimate (kWh)
    var lifetimeEnergyKWh: Double? {
        // Use AccumulatedSystemEnergyConsumed if available
        if let energy = accumulatedSystemEnergy, energy > 1_000_000 {
            // Empirically determined conversion (units appear to be in billions)
            return Double(energy) / 1_000_000_000.0
        }
        // Fallback to estimation from operating time
        guard let totalMinutes = totalOperatingTime, totalMinutes > 0 else { return nil }
        let totalHours = Double(totalMinutes) / 60.0
        let avgPower = voltage * Double(abs(amperage)) / 1000.0  // Rough estimate
        guard avgPower > 0 else { return nil }
        return totalHours * avgPower / 1000.0  // Convert Wh to kWh
    }

    // Battery age in years
    var batteryAgeYears: Double? {
        guard let days = batteryAgeDays else { return nil }
        return Double(days) / 365.25
    }
}

struct ChargerData: Sendable {
    var adapterID: Int = 0
    var adapterWattage: Int = 0
    var adapterFamily: String?
    var adapterFamilyCode: Int64?
    var adapterName: String?
    var adapterSerial: String?
    var isCharging: Bool = false

    // Charger type and configuration
    var chargingType: String?  // e.g., "pd charger", "USB-C Wired"
    var isWireless: Bool = false
    var chargerConfiguration: Int?  // Charger config register
    var pmuConfiguration: Int?  // PMU configuration
    var externalChargeCapable: Bool = false

    // Active profile
    var activeProfileIndex: Int?
    var profileVoltage: Double?  // V (current profile voltage)
    var profileCurrent: Double?  // A (current profile current)

    // USB-C PD Info
    var usbPDVersion: String?
    var powerRole: String?
    var dataRole: String?

    // Real-time power
    var adapterVoltage: Double?  // V
    var adapterCurrent: Double?  // A
    var adapterPower: Double?    // W

    // Efficiency
    var chargingEfficiency: Double?
    var adapterEfficiency: Double?

    // Source Capabilities (charger PDOs)
    var sourceCapabilities: [PDOCapability] = []
}

struct PowerMetrics: Sendable {
    var cpuPower: Double = 0.0  // W
    var gpuPower: Double = 0.0  // W
    var anePower: Double = 0.0  // W
    var dramPower: Double = 0.0  // W
    var totalSystemPower: Double = 0.0  // W
    var thermalPressure: String?

    // Real-time power flow
    var adapterPowerIn: Double = 0.0  // W
    var batteryPower: Double = 0.0  // W (negative = discharging)
    var systemLoad: Double = 0.0  // W

    // Power distribution
    var displayPower: Double?  // W
    var otherComponentsPower: Double?  // W
}

struct SystemInfo: Sendable {
    var macModel: String = "Unknown"
    var chipModel: String = "Unknown"
    var ramGB: Int = 0
    var cpuCores: Int = 0
}

struct BatteryHealthScore: Sendable {
    var score: Int  // 0-100
    var grade: String  // A+, A, B, C, D
    var description: String  // Excellent, Good, Fair, Aging, Poor
    var factors: [String]  // Individual factor scores
}

struct DisplayInfo: Sendable {
    var brightness: Double = 0.0  // 0-100%
    var estimatedPower: Double?  // W
    var maxPower: Double = 6.0  // W (typical max for MacBook displays)
}

struct USBPortInfo: Sendable {
    var wakeCurrent: Double = 0.0  // A
    var sleepCurrent: Double = 0.0  // A
}

struct PowerManagementInfo: Sendable {
    var lowPowerMode: Bool = false
    var hibernationMode: String = "Unknown"
    var wakeOnLAN: Bool = false
    var powerNap: Bool = false
    var displaySleepMinutes: Int = 0
    var activeAssertions: [String] = []
    var powerSourceHistory: [String] = []
    var sleepWakeHistory: [String] = []
    var scheduledEvents: [String] = []
}

struct USBCPDInfo: Sendable {
    var pdSpecification: String?
    var powerRole: String?
    var dataRole: String?
    var activeRDO: String?
    var selectedPDO: Int?
    var operatingCurrent: Double?  // A
    var maxCurrent: Double?  // A
    var portFWVersion: String?
    var numberOfPDOs: Int = 0
    var numberOfEPRPDOs: Int = 0
    var portMode: String?
    var powerState: String?
    var portMaxPower: Double?  // W
    var sinkCapabilities: [PDOCapability] = []
}

struct PDOCapability: Sendable {
    var pdoNumber: Int
    var voltage: Double  // V
    var current: Double  // A
    var power: Double  // W
    var isPPS: Bool = false
    var ppsMinVoltage: Double?  // V (for PPS)
    var ppsMaxVoltage: Double?  // V (for PPS)
}

// MARK: - Complete System State

struct SystemPowerState: Sendable {
    var battery: BatteryData
    var charger: ChargerData?
    var powerMetrics: PowerMetrics?
    var systemInfo: SystemInfo
    var healthScore: BatteryHealthScore?
    var displayInfo: DisplayInfo?
    var usbPortInfo: USBPortInfo?
    var powerManagement: PowerManagementInfo?
    var usbcPDInfo: USBCPDInfo?
    var lastUpdated: Date

    init(
        battery: BatteryData = BatteryData(),
        charger: ChargerData? = nil,
        powerMetrics: PowerMetrics? = nil,
        systemInfo: SystemInfo = SystemInfo(),
        healthScore: BatteryHealthScore? = nil,
        displayInfo: DisplayInfo? = nil,
        usbPortInfo: USBPortInfo? = nil,
        powerManagement: PowerManagementInfo? = nil,
        usbcPDInfo: USBCPDInfo? = nil,
        lastUpdated: Date = Date()
    ) {
        self.battery = battery
        self.charger = charger
        self.powerMetrics = powerMetrics
        self.systemInfo = systemInfo
        self.healthScore = healthScore
        self.displayInfo = displayInfo
        self.usbPortInfo = usbPortInfo
        self.powerManagement = powerManagement
        self.usbcPDInfo = usbcPDInfo
        self.lastUpdated = lastUpdated
    }
}
