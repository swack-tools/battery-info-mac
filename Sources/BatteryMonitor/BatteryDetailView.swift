import SwiftUI

// MARK: - Constants
private let sectionHeaderFontSize: CGFloat = 17

// MARK: - Custom Disclosure Group Style
struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation {
                    configuration.isExpanded.toggle()
                }
            }) {
                HStack {
                    configuration.label
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct BatteryDetailView: View {
    @ObservedObject var dataManager = BatteryDataManager.shared
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header with gradient background
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bolt.batteryblock.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                        Text("Battery Monitor")
                            .font(.title2)
                            .fontWeight(.bold)
                        Spacer()
                        Button(action: { dataManager.refresh() }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("Updated: \(formatTime(dataManager.lastUpdate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.blue.opacity(0.2), Color.purple.opacity(0.2)]
                            : [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)

                Divider()

                // System Information
                SystemInfoSection(info: dataManager.batteryInfo)
                Divider()

                // Battery Status Summary
                StatusSummarySection(info: dataManager.batteryInfo)
                Divider()

                // Battery Health
                BatteryHealthSection(info: dataManager.batteryInfo)
                Divider()

                // Capacity Analysis
                if !dataManager.batteryInfo.capacityAnalysis.isEmpty {
                    CapacityAnalysisSection(info: dataManager.batteryInfo)
                    Divider()
                }

                // Cell Diagnostics
                CellDiagnosticsSection(info: dataManager.batteryInfo)
                Divider()

                // Battery Information
                BatteryInfoSection(info: dataManager.batteryInfo)
                Divider()

                // Battery Details (Firmware, Age, etc.)
                BatteryDetailsSection(info: dataManager.batteryInfo)
                Divider()

                // Electrical Information
                ElectricalInformationSection(info: dataManager.batteryInfo)
                Divider()

                // Charging/Power Source
                if dataManager.batteryInfo.isPluggedIn {
                    ChargingInfoSection(info: dataManager.batteryInfo)
                    Divider()
                }

                // USB-C Power Delivery (always show - has sink capabilities even when unplugged)
                USBCPowerDeliverySection(info: dataManager.batteryInfo)
                Divider()

                // Power Breakdown
                if dataManager.batteryInfo.hasPowerMetrics {
                    PowerBreakdownSection(info: dataManager.batteryInfo)
                    Divider()
                }

                // Advanced Diagnostics
                AdvancedDiagnosticsSection(info: dataManager.batteryInfo)
                Divider()

                // Lifetime Statistics
                LifetimeStatisticsSection(info: dataManager.batteryInfo)
                Divider()

                // Health Assessment
                HealthAssessmentSection(info: dataManager.batteryInfo)
                Divider()

                // USB Ports
                USBPortsSection(info: dataManager.batteryInfo)
                Divider()

                // Power Management
                PowerManagementSection(info: dataManager.batteryInfo)
                Divider()

                // Quick Actions
                QuickActionsSection()
            }
            .padding()
            .disclosureGroupStyle(FullWidthDisclosureStyle())
        }
        .frame(width: 500, height: 700)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor))
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
            }

            // Battery status card with gradient background
            HStack {
                Image(systemName: batteryIcon)
                    .font(.system(size: 40))
                    .foregroundColor(batteryColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(info.percentage)%")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(batteryColor)

                    Text(info.statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if let timeRemaining = info.timeRemaining {
                        Text(timeRemaining)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(batteryColor.opacity(colorScheme == .dark ? 0.2 : 0.1))
            )

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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Capacity Analysis Section
struct CapacityAnalysisSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(info.capacityAnalysis, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.teal)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Capacity Analysis")
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Cell Diagnostics Section
struct CellDiagnosticsSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let voltages = info.cellVoltages {
                    InfoRow(label: "Cell Voltages", value: voltages, valueColor: .cyan)
                }

                if let delta = info.cellVoltageDelta {
                    InfoRow(label: "Cell Voltage Delta", value: delta, valueColor: .yellow)
                }

                if let count = info.cellDisconnectCount {
                    let color: Color = count > 0 ? .red : .green
                    InfoRow(label: "Cell Disconnect Count", value: "\(count)", valueColor: color)
                }

                if let count = info.rsenseOpenCount {
                    let color: Color = count > 0 ? .red : .green
                    InfoRow(label: "R-sense Open Count", value: "\(count)", valueColor: color)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "circlebadge.2.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Cell Diagnostics")
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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

                if let chem = info.chemistry {
                    InfoRow(label: "Chemistry", value: chem, valueColor: .green)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Battery Information")
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                        InfoRow(label: "Internal Resistance", value: "\(resistance) (\(quality))")
                    } else {
                        InfoRow(label: "Internal Resistance", value: resistance)
                    }
                }

                if let qmax = info.gaugeQmax {
                    InfoRow(label: "Gauge Measured Qmax", value: qmax)
                }

                if let vTemp = info.virtualTemperature {
                    InfoRow(label: "Virtual Temperature", value: vTemp)
                }

                if let port = info.bestChargerPort {
                    InfoRow(label: "Best Charger Port", value: port)
                }

                if let status = info.gaugeStatus {
                    InfoRow(label: "Gauge Status", value: status)
                }

                if let misc = info.miscStatus {
                    InfoRow(label: "Misc Status", value: misc)
                }

                if let failure = info.permanentFailure {
                    InfoRow(label: "Permanent Failure", value: failure)
                }

                if let count = info.gaugeWriteCount {
                    InfoRow(label: "Gauge Write Count", value: "\(count)")
                }

                if let soc = info.gaugeSoC {
                    InfoRow(label: "Gauge SOC", value: soc)
                }

                if let range = info.dailyChargeRange {
                    InfoRow(label: "Daily Charge Range", value: range)
                }

                if let shipping = info.shippingMode {
                    InfoRow(label: "Shipping Mode", value: shipping)
                }

                if let energy = info.lifetimeEnergy {
                    InfoRow(label: "Lifetime Energy", value: energy)
                }

                if let wait = info.postChargeWait {
                    InfoRow(label: "Post-Charge Wait", value: wait)
                }

                if let wait = info.postDischargeWait {
                    InfoRow(label: "Post-Discharge Wait", value: wait)
                }

                if let wake = info.invalidWakeTime {
                    InfoRow(label: "Invalid Wake Time", value: wake)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundColor(.red)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Advanced Diagnostics")
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    Text("Active Assertions")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.top, 8)

                    ForEach(info.activeAssertions.prefix(5), id: \.self) { assertion in
                        Text(assertion)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Power Source History
                if !info.powerSourceHistory.isEmpty {
                    Text("Power Source History")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.top, 8)

                    ForEach(info.powerSourceHistory.prefix(5), id: \.self) { history in
                        Text(history)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Sleep/Wake History
                if !info.sleepWakeHistory.isEmpty {
                    Text("Sleep/Wake History")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.top, 8)

                    ForEach(info.sleepWakeHistory.prefix(5), id: \.self) { history in
                        Text(history)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Scheduled Events
                if !info.scheduledEvents.isEmpty {
                    Text("Scheduled Events")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.top, 8)

                    ForEach(info.scheduledEvents.prefix(5), id: \.self) { event in
                        Text(event)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Battery Details Section
struct BatteryDetailsSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let deviceName = info.deviceName {
                    InfoRow(label: "Device Name", value: deviceName, valueColor: .cyan)
                }
                if let firmware = info.firmwareVersion {
                    InfoRow(label: "Firmware Version", value: firmware)
                }
                if let gasGauge = info.gasGaugeFirmwareVersion {
                    InfoRow(label: "Gas Gauge FW", value: gasGauge)
                }
                if let age = info.batteryAge {
                    InfoRow(label: "Battery Age", value: age)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: sectionHeaderFontSize))
                Text("Battery Details")
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
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
                    .font(.system(size: sectionHeaderFontSize))
                    .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Quick Actions Section
struct QuickActionsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.blue)
                Text("Quick Actions")
                    .font(.headline)
            }

            Button("Open System Settings → Battery") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)

            Button("Quit Battery Monitor") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
    }
}

// MARK: - Helper Views
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - Preview
struct BatteryDetailView_Previews: PreviewProvider {
    static var previews: some View {
        BatteryDetailView()
    }
}
