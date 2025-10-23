import SwiftUI

// MARK: - Constants
private let sectionHeaderFontSize: CGFloat = 18

// MARK: - Custom Font Styles
extension Font {
    static let appTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let sectionHeader = Font.system(size: 18, weight: .semibold, design: .default)
    static let batteryPercent = Font.system(size: 36, weight: .heavy, design: .rounded)
    static let infoLabel = Font.system(size: 14, weight: .regular, design: .default)
    static let infoValue = Font.system(size: 14, weight: .semibold, design: .default)
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
    static let buttonText = Font.system(size: 14, weight: .medium, design: .default)
}

// MARK: - Custom Disclosure Group Style
struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.colorScheme) var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    configuration.isExpanded.toggle()
                }
            }) {
                HStack {
                    configuration.label
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.03))
            )

            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.03)
                    : Color.white.opacity(0.5))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1),
                       radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark
                    ? Color.white.opacity(0.1)
                    : Color.black.opacity(0.05),
                    lineWidth: 1)
        )
    }
}

struct BatteryDetailView: View {
    @ObservedObject var dataManager = BatteryDataManager.shared
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Enhanced header with glassmorphism
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bolt.batteryblock.fill")
                            .font(.title2)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 2, x: 0, y: 1)
                        Text("Battery Monitor")
                            .font(.appTitle)
                            .tracking(0.5)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.primary, .blue.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        Spacer()
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                dataManager.refresh()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.blue)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .scaleEffect(dataManager.lastUpdate.timeIntervalSinceNow > -1 ? 1.1 : 1.0)
                    }

                    Text("Updated: \(formatTime(dataManager.lastUpdate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: colorScheme == .dark
                                        ? [Color.blue.opacity(0.25), Color.purple.opacity(0.25)]
                                        : [Color.blue.opacity(0.15), Color.purple.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        RoundedRectangle(cornerRadius: 16)
                            .fill(colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.white.opacity(0.3))
                            .blur(radius: 1)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color.blue.opacity(0.3), Color.purple.opacity(0.3)]
                                    : [Color.blue.opacity(0.2), Color.purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: Color.blue.opacity(0.2), radius: 10, x: 0, y: 4)
                .shadow(color: Color.purple.opacity(0.1), radius: 20, x: 0, y: 8)

                // System Information
                SystemInfoSection(info: dataManager.batteryInfo)

                // Battery Status Summary
                StatusSummarySection(info: dataManager.batteryInfo)

                // Battery Health
                BatteryHealthSection(info: dataManager.batteryInfo)

                // Capacity Analysis
                if !dataManager.batteryInfo.capacityAnalysis.isEmpty {
                    CapacityAnalysisSection(info: dataManager.batteryInfo)
                }

                // Battery Information
                BatteryInfoSection(info: dataManager.batteryInfo)

                // Electrical Information
                ElectricalInformationSection(info: dataManager.batteryInfo)

                // Charging/Power Source
                if dataManager.batteryInfo.isPluggedIn {
                    ChargingInfoSection(info: dataManager.batteryInfo)
                }

                // USB-C Power Delivery (always show - has sink capabilities even when unplugged)
                USBCPowerDeliverySection(info: dataManager.batteryInfo)

                // Power Breakdown
                if dataManager.batteryInfo.hasPowerMetrics {
                    PowerBreakdownSection(info: dataManager.batteryInfo)
                }

                // Advanced Diagnostics
                AdvancedDiagnosticsSection(info: dataManager.batteryInfo)

                // Lifetime Statistics
                LifetimeStatisticsSection(info: dataManager.batteryInfo)

                // Health Assessment
                HealthAssessmentSection(info: dataManager.batteryInfo)

                // USB Ports
                USBPortsSection(info: dataManager.batteryInfo)

                // Power Management
                PowerManagementSection(info: dataManager.batteryInfo)

                // Quick Actions
                QuickActionsSection()
            }
            .padding(20)
            .disclosureGroupStyle(FullWidthDisclosureStyle())
        }
        .frame(width: 540, height: 720)
        .background(
            ZStack {
                (colorScheme == .dark
                    ? Color(nsColor: .windowBackgroundColor)
                    : Color(red: 0.95, green: 0.96, blue: 0.97))

                if colorScheme != .dark {
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.03),
                            Color.purple.opacity(0.03),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        )
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - System Information Section
struct SystemInfoSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Mac Model", value: info.macModel)
                InfoRow(label: "Chip", value: info.chipModel, valueColor: .blue)
                InfoRow(label: "RAM", value: info.ramSize, valueColor: .purple)
                InfoRow(label: "CPU Cores", value: info.cpuCores, valueColor: .orange)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.blue)
                    .font(.system(size: sectionHeaderFontSize))
                Text("System Information")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Status Summary Section
struct StatusSummarySection: View {
    let info: BatteryDisplayInfo
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Status")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }

            // Enhanced battery status card with glassmorphism
            HStack(spacing: 16) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [batteryColor, batteryColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: batteryColor.opacity(0.3), radius: 4, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(info.percentage)%")
                        .font(.batteryPercent)
                        .tracking(1.0)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [batteryColor, batteryColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(info.statusText)
                        .font(.infoValue)
                        .tracking(0.2)
                        .foregroundColor(.secondary)

                    if let timeRemaining = info.timeRemaining {
                        Text(timeRemaining)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [batteryColor.opacity(0.25), batteryColor.opacity(0.15)]
                                    : [batteryColor.opacity(0.15), batteryColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 14)
                        .fill(colorScheme == .dark
                            ? Color.white.opacity(0.03)
                            : Color.white.opacity(0.4))
                        .blur(radius: 0.5)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        LinearGradient(
                            colors: [batteryColor.opacity(0.4), batteryColor.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: batteryColor.opacity(0.2), radius: 10, x: 0, y: 4)
            .shadow(color: batteryColor.opacity(0.1), radius: 20, x: 0, y: 8)

            InfoRow(label: "Power Source", value: info.powerSource, valueColor: info.isPluggedIn ? .green : .primary)

            if let timeToEmpty = info.timeToEmpty {
                InfoRow(label: "Avg Time to Empty", value: timeToEmpty)
            }
        }
    }

    var batteryIcon: String {
        if info.isCharging {
            return "battery.100.bolt"
        } else if info.percentage >= 75 {
            return "battery.100"
        } else if info.percentage >= 50 {
            return "battery.75"
        } else if info.percentage >= 25 {
            return "battery.50"
        } else {
            return "battery.25"
        }
    }

    var batteryColor: Color {
        if info.isCharging {
            return .green
        } else if info.percentage < 20 {
            return .red
        } else if info.percentage < 40 {
            return .orange
        } else {
            return .primary
        }
    }
}

// MARK: - Battery Health Section
struct BatteryHealthSection: View {
    let info: BatteryDisplayInfo

    var healthColor: Color {
        if info.healthPercentage >= 90 {
            return .green
        } else if info.healthPercentage >= 80 {
            return .yellow
        } else if info.healthPercentage >= 70 {
            return .orange
        } else {
            return .red
        }
    }

    var conditionColor: Color {
        switch info.condition.lowercased() {
        case "normal", "good": return .green
        case "fair": return .yellow
        case "poor", "check battery", "replace soon": return .orange
        case "replace now", "service battery": return .red
        default: return .primary
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Condition", value: info.condition, valueColor: conditionColor)

                if info.serviceRecommended {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        InfoRow(label: "Service Recommended", value: "Yes", valueColor: .red)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        InfoRow(label: "Service Recommended", value: "No", valueColor: .green)
                    }
                }

                InfoRow(label: "Health Percentage", value: "\(info.healthPercentage)%", valueColor: healthColor)
                InfoRow(label: "Cycle Count", value: "\(info.cycleCount) cycles")

                if info.designCycleCount > 0 {
                    InfoRow(label: "Design Cycle Count", value: "\(info.designCycleCount) cycles")
                }

                InfoRow(label: "Lifespan Used", value: info.lifespanUsed)

                if info.fullChargeCapacity > 0 {
                    InfoRow(label: "Battery FCC", value: "\(info.fullChargeCapacity) mAh")
                }

                if info.designCapacity > 0 {
                    InfoRow(label: "Design Capacity", value: "\(info.designCapacity) mAh")
                }

                if info.nominalCapacity > 0 {
                    InfoRow(label: "Nominal Capacity", value: "\(info.nominalCapacity) mAh")
                }

                // Temperature with color coding
                if let tempString = info.temperature.split(separator: "°").first,
                   let tempValue = Double(tempString) {
                    let tempColor: Color = {
                        if tempValue < 30 { return .blue }
                        else if tempValue < 40 { return .green }
                        else if tempValue < 45 { return .orange }
                        else { return .red }
                    }()
                    InfoRow(label: "Temperature", value: info.temperature, valueColor: tempColor)
                } else {
                    InfoRow(label: "Temperature", value: info.temperature)
                }

                if info.currentCapacity > 0 {
                    InfoRow(label: "Current Capacity", value: "\(info.currentCapacity) mAh")
                }

                if let reserve = info.packReserve {
                    InfoRow(label: "Pack Reserve", value: reserve)
                }

                if info.atCriticalLevel {
                    InfoRow(label: "At Critical Level", value: "Yes", valueColor: .red)
                }

                if let cycles = info.estimatedCyclesTo80 {
                    InfoRow(label: "Est. Cycles to 80%", value: cycles)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundColor(.pink)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Battery Health")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Capacity Analysis Section
struct CapacityAnalysisSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if info.designCapacity > 0 {
                    InfoRow(label: "Design (factory)",
                           value: "\(info.designCapacity) mAh (100%)")
                }

                if info.nominalCapacity > 0 && info.designCapacity > 0 {
                    let diff = info.nominalCapacity - info.designCapacity
                    let pct = (Double(info.nominalCapacity) / Double(info.designCapacity)) * 100.0
                    InfoRow(label: "Nominal (rated)",
                           value: String(format: "%d mAh (%.1f%%) [%+d mAh]",
                                       info.nominalCapacity, pct, diff))
                }

                if info.fullChargeCapacity > 0 && info.designCapacity > 0 {
                    let diff = info.fullChargeCapacity - info.designCapacity
                    let pct = (Double(info.fullChargeCapacity) / Double(info.designCapacity)) * 100.0
                    let color: Color = {
                        if pct >= 95 { return .green }
                        else if pct >= 85 { return .yellow }
                        else if pct >= 80 { return .orange }
                        else { return .red }
                    }()
                    InfoRow(label: "Current Max (FCC)",
                           value: String(format: "%d mAh (%.1f%%) [%+d mAh]",
                                       info.fullChargeCapacity, pct, diff),
                           valueColor: color)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.teal)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Capacity Analysis")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Battery Info Section
struct BatteryInfoSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let mfg = info.manufacturer {
                    InfoRow(label: "Manufacturer", value: mfg)
                }

                if let model = info.batteryModel {
                    InfoRow(label: "Battery Model", value: model)
                }

                if let serial = info.batterySerial {
                    InfoRow(label: "Serial Number", value: serial)
                }

                if let date = info.manufactureDate {
                    InfoRow(label: "Manufacture Date", value: date)
                }

                if let age = info.batteryAge {
                    InfoRow(label: "Battery Age", value: age)
                }

                if let chem = info.chemistry {
                    InfoRow(label: "Chemistry", value: chem, valueColor: .green)
                }

                if let deviceName = info.deviceName {
                    InfoRow(label: "Device Name", value: deviceName, valueColor: .cyan)
                }

                if let firmware = info.firmwareVersion {
                    InfoRow(label: "Firmware Version", value: firmware)
                }

                if let gasGauge = info.gasGaugeFirmwareVersion {
                    InfoRow(label: "Gas Gauge FW", value: gasGauge)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Battery Information")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Charging Info Section
struct ChargingInfoSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let wattage = info.chargerWattage {
                    InfoRow(label: "Charger Wattage", value: wattage, valueColor: .green)
                }

                if let type = info.chargerType {
                    InfoRow(label: "Charging Type", value: type, valueColor: .blue)
                }

                if let family = info.chargerFamily {
                    InfoRow(label: "Charger Family", value: family)
                }

                if let serial = info.chargerSerial {
                    InfoRow(label: "Charger Serial", value: serial)
                }

                if let voltage = info.voltage {
                    InfoRow(label: "Voltage", value: voltage, valueColor: .orange)
                }

                if let current = info.current {
                    InfoRow(label: "Current", value: current, valueColor: .purple)
                }

                if let power = info.power {
                    InfoRow(label: "Power", value: power, valueColor: .green)
                }

                if let id = info.chargerID {
                    InfoRow(label: "Charger ID", value: id)
                }

                if let adapterInput = info.adapterInput {
                    InfoRow(label: "Adapter Input", value: adapterInput, valueColor: .green)
                }

                if let efficiency = info.adapterEfficiency {
                    InfoRow(label: "Adapter Efficiency", value: efficiency)
                }

                if let config = info.chargerConfig {
                    InfoRow(label: "Charger Config", value: config, valueColor: .cyan)
                }

                if let externalCharge = info.externalChargeCapable {
                    InfoRow(label: "External Charge", value: externalCharge)
                }

                if let notChargingReason = info.notChargingReason {
                    InfoRow(label: "Not Charging Reason", value: notChargingReason)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.green)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Charger Information")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - USB-C Power Delivery Section
struct USBCPowerDeliverySection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let contract = info.pdContract {
                    InfoRow(label: "USB-C PD Contract", value: contract)
                }

                if let spec = info.pdSpecification {
                    InfoRow(label: "PD Specification", value: spec)
                }

                if let role = info.powerRole {
                    InfoRow(label: "Power Role", value: role)
                }

                if let role = info.dataRole {
                    InfoRow(label: "Data Role", value: role)
                }

                if let pdo = info.selectedPDO {
                    InfoRow(label: "Selected PDO", value: pdo)
                }

                if let current = info.operatingCurrent {
                    InfoRow(label: "Operating Current", value: current)
                }

                if let maxCurr = info.maxCurrent {
                    InfoRow(label: "Max Current", value: maxCurr)
                }

                if let rdo = info.activeRDO {
                    InfoRow(label: "Active RDO", value: rdo, valueColor: .cyan)
                }

                if let fwVer = info.portFWVersion {
                    InfoRow(label: "Port FW Version", value: fwVer)
                }

                if let numPDOs = info.numberOfPDOs {
                    InfoRow(label: "Number of PDOs", value: numPDOs)
                }

                if let numEPR = info.numberOfEPRPDOs {
                    InfoRow(label: "Number of EPR PDOs", value: numEPR)
                }

                if let mode = info.portMode {
                    InfoRow(label: "Port Mode", value: mode, valueColor: .blue)
                }

                if let state = info.powerState {
                    InfoRow(label: "Power State", value: state, valueColor: .green)
                }

                if let maxPower = info.portMaxPower {
                    InfoRow(label: "Port Max Power", value: maxPower, valueColor: .orange)
                }

                // Source Capabilities (Charger)
                Divider()
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "powerplug.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Source Capabilities (Charger)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    if info.sourceCapabilities.isEmpty {
                        Text("Not available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    } else {
                        ForEach(info.sourceCapabilities, id: \.self) { cap in
                            Text(cap)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                }

                // Sink Capabilities (Laptop)
                Divider()
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "laptopcomputer")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Sink Capabilities (Laptop)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    if info.sinkCapabilities.isEmpty {
                        Text("Not available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    } else {
                        ForEach(info.sinkCapabilities, id: \.self) { cap in
                            Text(cap)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "cable.connector")
                    .foregroundColor(.purple)
                    .font(.system(size: sectionHeaderFontSize))
                Text("USB-C Power Delivery")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Advanced Diagnostics Section
struct AdvancedDiagnosticsSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let resistance = info.internalResistance {
                    if let quality = info.internalResistanceQuality {
                        let color: Color = {
                            if quality.lowercased().contains("good") || quality.lowercased().contains("excellent") {
                                return .green
                            } else if quality.lowercased().contains("fair") || quality.lowercased().contains("normal") {
                                return .yellow
                            } else if quality.lowercased().contains("poor") {
                                return .orange
                            } else {
                                return .primary
                            }
                        }()
                        InfoRow(label: "Internal Resistance", value: "\(resistance) (\(quality))", valueColor: color)
                    } else {
                        InfoRow(label: "Internal Resistance", value: resistance, valueColor: .cyan)
                    }
                }

                if let qmax = info.gaugeQmax {
                    InfoRow(label: "Gauge Measured Qmax", value: qmax, valueColor: .teal)
                }

                if let vTemp = info.virtualTemperature {
                    let tempColor: Color = {
                        // Extract temperature value
                        if let tempString = vTemp.split(separator: "°").first,
                           let tempValue = Double(tempString) {
                            if tempValue < 30 { return .blue }
                            else if tempValue < 40 { return .green }
                            else if tempValue < 45 { return .orange }
                            else { return .red }
                        }
                        return .primary
                    }()
                    InfoRow(label: "Virtual Temperature", value: vTemp, valueColor: tempColor)
                }

                if let port = info.bestChargerPort {
                    InfoRow(label: "Best Charger Port", value: port, valueColor: .purple)
                }

                if let status = info.gaugeStatus {
                    let statusColor: Color = {
                        let lower = status.lowercased()
                        if lower.contains("ok") || lower.contains("good") || lower.contains("normal") {
                            return .green
                        } else if lower.contains("warning") {
                            return .yellow
                        } else if lower.contains("error") || lower.contains("fail") {
                            return .red
                        }
                        return .cyan
                    }()
                    InfoRow(label: "Gauge Status", value: status, valueColor: statusColor)
                }

                if let misc = info.miscStatus {
                    let miscColor: Color = {
                        let lower = misc.lowercased()
                        if lower.contains("ok") || lower.contains("good") || lower.contains("normal") {
                            return .green
                        } else if lower.contains("warning") {
                            return .yellow
                        } else if lower.contains("error") || lower.contains("fail") {
                            return .red
                        }
                        return .cyan
                    }()
                    InfoRow(label: "Misc Status", value: misc, valueColor: miscColor)
                }

                if let failure = info.permanentFailure {
                    let failureColor: Color = {
                        let lower = failure.lowercased()
                        if lower.contains("none") || lower.contains("healthy") || lower.contains("no") {
                            return .green
                        } else {
                            return .red
                        }
                    }()
                    InfoRow(label: "Permanent Failure", value: failure, valueColor: failureColor)
                }

                if let count = info.gaugeWriteCount {
                    InfoRow(label: "Gauge Write Count", value: "\(count)", valueColor: .cyan)
                }

                if let soc = info.gaugeSoC {
                    let socColor: Color = {
                        // Extract percentage if present
                        if let pctString = soc.split(separator: "%").first?.split(separator: " ").last,
                           let pctValue = Double(pctString) {
                            if pctValue >= 80 { return .green }
                            else if pctValue >= 50 { return .yellow }
                            else if pctValue >= 20 { return .orange }
                            else { return .red }
                        }
                        return .green
                    }()
                    InfoRow(label: "Gauge SOC", value: soc, valueColor: socColor)
                }

                if let range = info.dailyChargeRange {
                    InfoRow(label: "Daily Charge Range", value: range, valueColor: .teal)
                }

                if let shipping = info.shippingMode {
                    InfoRow(label: "Shipping Mode", value: shipping, valueColor: .secondary)
                }

                if let energy = info.lifetimeEnergy {
                    InfoRow(label: "Lifetime Energy", value: energy, valueColor: .orange)
                }

                if let wait = info.postChargeWait {
                    InfoRow(label: "Post-Charge Wait", value: wait, valueColor: .indigo)
                }

                if let wait = info.postDischargeWait {
                    InfoRow(label: "Post-Discharge Wait", value: wait, valueColor: .indigo)
                }

                if let wake = info.invalidWakeTime {
                    let wakeColor: Color = {
                        if wake.contains("0") && !wake.contains("00:") {
                            return .green
                        } else {
                            return .red
                        }
                    }()
                    InfoRow(label: "Invalid Wake Time", value: wake, valueColor: wakeColor)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundColor(.red)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Advanced Diagnostics")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - USB Ports Section
struct USBPortsSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let wake = info.usbWakeCurrent {
                    InfoRow(label: "USB Wake Current", value: wake, valueColor: .purple)
                }

                if let sleep = info.usbSleepCurrent {
                    InfoRow(label: "USB Sleep Current", value: sleep, valueColor: .indigo)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "cable.connector.horizontal")
                    .foregroundColor(.purple)
                    .font(.system(size: sectionHeaderFontSize))
                Text("USB Ports")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Power Management Section
struct PowerManagementSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let lowPower = info.lowPowerMode {
                    InfoRow(label: "Low Power Mode", value: lowPower)
                }

                if let hibernation = info.hibernationMode {
                    InfoRow(label: "Hibernation Mode", value: hibernation)
                }

                if let wakeOnLAN = info.wakeOnLAN {
                    InfoRow(label: "Wake on LAN", value: wakeOnLAN)
                }

                if let powerNap = info.powerNap {
                    InfoRow(label: "Power Nap", value: powerNap)
                }

                if let displaySleep = info.displaySleepMinutes {
                    InfoRow(label: "Display Sleep", value: displaySleep)
                }

                // Active Assertions
                if !info.activeAssertions.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Active Assertions")
                                .font(.infoValue)
                                .tracking(0.2)
                            Spacer()
                            Text("\(info.activeAssertions.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(8)
                        }

                        ForEach(Array(info.activeAssertions.prefix(5).enumerated()), id: \.offset) { index, assertion in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.orange.opacity(0.6))
                                    .frame(width: 20, alignment: .leading)

                                Text(assertion)
                                    .font(.system(size: 12))
                                    .tracking(0.1)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }

                // Power Source History
                if !info.powerSourceHistory.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Power Source History")
                                .font(.infoValue)
                                .tracking(0.2)
                        }

                        ForEach(Array(info.powerSourceHistory.prefix(5).enumerated()), id: \.offset) { index, history in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: history.contains("AC") ? "bolt.fill" : "battery.100")
                                    .font(.caption2)
                                    .foregroundColor(history.contains("AC") ? .green : .blue)
                                    .frame(width: 20, alignment: .leading)

                                Text(history)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .tracking(0.1)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Sleep/Wake History
                if !info.sleepWakeHistory.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "moon.stars.fill")
                                .foregroundColor(.indigo)
                                .font(.caption)
                            Text("Sleep/Wake History")
                                .font(.infoValue)
                                .tracking(0.2)
                        }

                        ForEach(Array(info.sleepWakeHistory.prefix(5).enumerated()), id: \.offset) { index, history in
                            let iconAndColor = getSleepWakeIcon(history: history)

                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: iconAndColor.icon)
                                    .font(.caption2)
                                    .foregroundColor(iconAndColor.color)
                                    .frame(width: 20, alignment: .leading)

                                Text(history)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .tracking(0.1)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Scheduled Events
                if !info.scheduledEvents.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text("Scheduled Events")
                                .font(.infoValue)
                                .tracking(0.2)
                        }

                        ForEach(Array(info.scheduledEvents.prefix(5).enumerated()), id: \.offset) { index, event in
                            if let parsed = parseScheduledEvent(event) {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("[\(index)]")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.blue)
                                        .frame(width: 30, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Image(systemName: parsed.type == "wake" ? "sun.max.fill" : "moon.fill")
                                                .font(.caption2)
                                                .foregroundColor(parsed.type == "wake" ? .orange : .indigo)
                                            Text(parsed.type.capitalized)
                                                .font(.infoLabel)
                                                .foregroundColor(.primary)
                                        }

                                        Text(parsed.datetime)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)

                                        if !parsed.reason.isEmpty {
                                            Text(parsed.reason)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "power")
                    .foregroundColor(.orange)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Power Management")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Power Breakdown Section
struct PowerBreakdownSection: View {
    let info: BatteryDisplayInfo
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                // Component Power
                VStack(alignment: .leading, spacing: 6) {
                    if let cpu = info.cpuPower {
                        InfoRow(label: "CPU Power", value: cpu, valueColor: .orange)
                    }
                    if let gpu = info.gpuPower {
                        InfoRow(label: "GPU Power", value: gpu, valueColor: .orange)
                    }
                    if let ane = info.anePower {
                        InfoRow(label: "ANE Power", value: ane, valueColor: .orange)
                    }
                    if let dram = info.dramPower {
                        InfoRow(label: "DRAM Power", value: dram, valueColor: .orange)
                    }
                    if let combined = info.combinedPower {
                        InfoRow(label: "Combined Power", value: combined, valueColor: .orange)
                    }
                    if let total = info.totalSystemPower {
                        InfoRow(label: "Total System Power", value: total, valueColor: .orange)
                    }

                    if let thermal = info.thermalPressure {
                        let thermalColor: Color = {
                            switch thermal.lowercased() {
                            case "nominal", "normal": return .green
                            case "light", "moderate": return .yellow
                            case "heavy": return .red
                            default: return .primary
                            }
                        }()
                        InfoRow(label: "Thermal Pressure", value: thermal, valueColor: thermalColor)
                    }

                    if let peak = info.peakComponent {
                        InfoRow(label: "Peak Component", value: peak, valueColor: .orange)
                    }

                    if let idle = info.idlePowerEstimate {
                        InfoRow(label: "Idle Power (est)", value: idle, valueColor: .green)
                    }
                }

                // Real-Time Power Flow
                if info.adapterPowerIn != nil || info.batteryPowerFlow != nil || info.systemLoad != nil {
                    Divider()
                    Text("Real-Time Power Flow")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    if let adapter = info.adapterPowerIn {
                        InfoRow(label: "  Adapter Power In", value: adapter, valueColor: .green)
                    }
                    if let battery = info.batteryPowerFlow {
                        let batteryValue = Double(battery.replacingOccurrences(of: "W", with: "")) ?? 0.0
                        let batteryColor: Color = batteryValue > 0 ? .green : .red
                        let displayValue = batteryValue > 0 ? "+\(battery)" : battery
                        InfoRow(label: "  Battery Power", value: displayValue, valueColor: batteryColor)
                    }
                    if let load = info.systemLoad {
                        InfoRow(label: "  System Load", value: load, valueColor: .orange)
                    }
                }

                // Power Distribution
                if info.componentsPowerPct != nil || info.displayPowerPct != nil || info.otherComponentsPowerPct != nil {
                    Divider()
                    Text("Power Distribution")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    if let components = info.componentsPowerPct {
                        VStack(alignment: .leading, spacing: 2) {
                            InfoRow(label: "  Components", value: components, valueColor: .orange)
                            Text("    CPU/GPU/ANE/DRAM")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let display = info.displayPowerPct {
                        VStack(alignment: .leading, spacing: 2) {
                            InfoRow(label: "  Display", value: display, valueColor: .orange)
                            if let brightness = info.displayBrightness {
                                Text("    Backlight @ \(brightness)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if let other = info.otherComponentsPowerPct {
                        VStack(alignment: .leading, spacing: 2) {
                            InfoRow(label: "  Other Components", value: other, valueColor: .orange)
                            Text("    SSD, WiFi, Thunderbolt, USB, etc.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let total = info.systemLoad {
                        InfoRow(label: "  Total System Load", value: total, valueColor: .primary)
                            .fontWeight(.semibold)
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Power Breakdown")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Electrical Information Section
struct ElectricalInformationSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let voltage = info.voltage {
                    InfoRow(label: "Voltage", value: voltage, valueColor: .orange)
                }
                if let current = info.currentAvg {
                    InfoRow(label: "Current (Avg)", value: current, valueColor: .purple)
                }
                if let currentInst = info.currentInstant {
                    InfoRow(label: "Current (Instant)", value: currentInst, valueColor: .purple)
                }
                if let batteryPower = info.batteryChargePower {
                    InfoRow(label: "Battery Charge Power", value: batteryPower, valueColor: .green)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Electrical Information")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Lifetime Statistics Section
struct LifetimeStatisticsSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let operatingTime = info.totalOperatingTime {
                    InfoRow(label: "Total Operating Time", value: operatingTime, valueColor: .blue)
                }
                if let maxTemp = info.maximumTemperature {
                    InfoRow(label: "Maximum Temperature", value: maxTemp, valueColor: .red)
                }
                if let minTemp = info.minimumTemperature {
                    InfoRow(label: "Minimum Temperature", value: minTemp, valueColor: .cyan)
                }
                if let avgTemp = info.averageTemperature {
                    InfoRow(label: "Average Temperature", value: avgTemp, valueColor: .orange)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.purple)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Lifetime Statistics")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Health Assessment Section
struct HealthAssessmentSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let healthScore = info.healthScore {
                    InfoRow(label: "Battery Health Score", value: healthScore, valueColor: .green)
                }
                if let cycleAssess = info.cycleAssessment {
                    InfoRow(label: "Cycle Count", value: cycleAssess, valueColor: .blue)
                }
                if let capAssess = info.capacityAssessment {
                    InfoRow(label: "Capacity", value: capAssess, valueColor: .green)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "heart.text.square.fill")
                    .foregroundColor(.pink)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Health Assessment")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }
        }
    }
}

// MARK: - Quick Actions Section
struct QuickActionsSection: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .font(.system(size: sectionHeaderFontSize))
                Text("Quick Actions")
                    .font(.sectionHeader)
                    .tracking(0.3)
            }

            VStack(spacing: 8) {
                Button(action: {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery")!
                    NSWorkspace.shared.open(url)
                }) {
                    HStack {
                        Image(systemName: "gear")
                            .foregroundColor(.blue)
                        Text("Open System Settings → Battery")
                            .font(.buttonText)
                            .tracking(0.2)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.white.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.red)
                        Text("Quit Battery Monitor")
                            .font(.buttonText)
                            .tracking(0.2)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.white.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.red.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.03)
                    : Color.white.opacity(0.5))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1),
                       radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark
                    ? Color.white.opacity(0.1)
                    : Color.black.opacity(0.05),
                    lineWidth: 1)
        )
    }
}

// MARK: - Helper Views
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.infoLabel)
                .foregroundColor(.secondary)
                .tracking(0.2)
                .lineSpacing(4)
            Spacer()
            Text(value)
                .font(.infoValue)
                .tracking(0.3)
                .lineSpacing(4)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Helper Functions
struct ScheduledEventInfo {
    let type: String  // "wake" or "sleep"
    let datetime: String
    let reason: String
}

struct IconAndColor {
    let icon: String
    let color: Color
}

func getSleepWakeIcon(history: String) -> IconAndColor {
    if history.contains("Wake") && !history.contains("DarkWake") {
        return IconAndColor(icon: "sun.max.fill", color: .orange)
    } else if history.contains("DarkWake") {
        return IconAndColor(icon: "moon.circle.fill", color: .purple)
    } else {
        return IconAndColor(icon: "moon.fill", color: .indigo)
    }
}

func parseScheduledEvent(_ event: String) -> ScheduledEventInfo? {
    // Format: "[0]  wake at 10/23/2025 12:14:24 by 'com.apple.alarm.user-invisible...'"
    // or: "[0]  sleep at 10/23/2025 12:14:24 by 'com.apple.alarm...'"

    let trimmed = event.trimmingCharacters(in: .whitespaces)

    // Extract type (wake/sleep)
    let type: String
    if trimmed.contains(" wake ") {
        type = "wake"
    } else if trimmed.contains(" sleep ") {
        type = "sleep"
    } else {
        return nil
    }

    // Extract datetime using regex
    // Pattern: "at MM/DD/YYYY HH:MM:SS"
    let datePattern = "at (\\d{1,2}/\\d{1,2}/\\d{4} \\d{1,2}:\\d{2}:\\d{2})"
    if let regex = try? NSRegularExpression(pattern: datePattern),
       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
       let dateRange = Range(match.range(at: 1), in: trimmed) {
        let datetime = String(trimmed[dateRange])

        // Extract reason (after "by '")
        var reason = ""
        if let byIndex = trimmed.range(of: " by '") {
            let afterBy = trimmed[byIndex.upperBound...]
            if let endQuote = afterBy.firstIndex(of: "'") {
                reason = String(afterBy[..<endQuote])
                // Simplify long bundle IDs
                if reason.hasPrefix("com.apple.") {
                    let components = reason.components(separatedBy: ".")
                    if components.count > 2 {
                        reason = components.suffix(min(3, components.count)).joined(separator: ".")
                    }
                }
            }
        }

        return ScheduledEventInfo(type: type, datetime: datetime, reason: reason)
    }

    return nil
}

// MARK: - Preview
struct BatteryDetailView_Previews: PreviewProvider {
    static var previews: some View {
        BatteryDetailView()
    }
}
