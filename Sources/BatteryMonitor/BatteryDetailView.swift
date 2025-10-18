import SwiftUI

struct BatteryDetailView: View {
    @State private var batteryInfo: BatteryDisplayInfo = BatteryDisplayInfo()
    @State private var lastUpdate: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text("Battery Monitor")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: { refreshData() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.bottom, 4)

                // Last Update
                Text("Updated: \(formatTime(lastUpdate))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // Battery Status Summary
                SummarySection(info: batteryInfo)

                Divider()

                // Battery Health
                HealthSection(info: batteryInfo)

                Divider()

                // Charging Info
                ChargingSection(info: batteryInfo)

                Divider()

                // USB-C PD Info
                if batteryInfo.isPluggedIn {
                    USBCSection(info: batteryInfo)
                    Divider()
                }

                // Advanced Diagnostics
                AdvancedSection(info: batteryInfo)

                Divider()

                // Quick Actions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Actions")
                        .font(.headline)

                    Button("Open System Settings → Battery") {
                        openBatterySettings()
                    }
                    .buttonStyle(.link)

                    Button("Quit Battery Monitor") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 600)
        .onAppear {
            refreshData()
        }
    }

    func refreshData() {
        batteryInfo = BatteryDisplayInfo.fetch()
        lastUpdate = Date()
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    func openBatterySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Summary Section
struct SummarySection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)

            HStack {
                Image(systemName: batteryIcon)
                    .font(.system(size: 40))
                    .foregroundColor(batteryColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(info.percentage)%")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text(info.statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if let timeRemaining = info.timeRemaining {
                        Text(timeRemaining)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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

// MARK: - Health Section
struct HealthSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery Health")
                .font(.headline)

            InfoRow(label: "Condition", value: info.condition)
            InfoRow(label: "Health", value: "\(info.healthPercentage)%")

            if info.fullChargeCapacity > 0 {
                InfoRow(label: "FCC", value: "\(info.fullChargeCapacity) mAh")
            }

            if info.designCapacity > 0 {
                InfoRow(label: "Design Capacity", value: "\(info.designCapacity) mAh")
            }

            InfoRow(label: "Cycle Count", value: "\(info.cycleCount)")

            let lifespanPercent = info.designCycleCount > 0 ?
                String(format: "%.1f%%", Double(info.cycleCount) / Double(info.designCycleCount) * 100) : "N/A"
            InfoRow(label: "Lifespan Used", value: lifespanPercent)

            InfoRow(label: "Temperature", value: info.temperature)
        }
    }
}

// MARK: - Charging Section
struct ChargingSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power Source")
                .font(.headline)

            InfoRow(label: "Status", value: info.powerSource)

            if info.isPluggedIn {
                if let chargerWattage = info.chargerWattage {
                    InfoRow(label: "Charger", value: chargerWattage)
                }
                if let voltage = info.voltage, let current = info.current {
                    InfoRow(label: "Power", value: "\(voltage)V @ \(current)A")
                }
            }
        }
    }
}

// MARK: - USB-C Section
struct USBCSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USB-C Power Delivery")
                .font(.headline)

            if let pdContract = info.pdContract {
                InfoRow(label: "Contract", value: pdContract)
            }
            if let pdVersion = info.pdVersion {
                InfoRow(label: "PD Version", value: pdVersion)
            }
        }
    }
}

// MARK: - Advanced Section
struct AdvancedSection: View {
    let info: BatteryDisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced Diagnostics")
                .font(.headline)

            if let resistance = info.internalResistance {
                InfoRow(label: "Internal Resistance", value: resistance)
            }

            if let cellVoltages = info.cellVoltages {
                InfoRow(label: "Cell Voltages", value: cellVoltages)
            }

            if let manufacturer = info.manufacturer {
                InfoRow(label: "Manufacturer", value: manufacturer)
            }
        }
    }
}

// MARK: - Helper Views
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
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
