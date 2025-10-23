import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences = PreferencesManager.shared
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Preferences")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 10)

            Divider()

            // General Section
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.headline)
                    .foregroundColor(.secondary)

                // Launch at Login Toggle
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch at Login")
                            .font(.body)
                        Text("Automatically start Battery Monitor when you log in")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $preferences.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider()
                    .padding(.vertical, 4)

                // Auto-refresh interval
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-refresh Interval")
                        .font(.body)

                    HStack(spacing: 12) {
                        Slider(value: $preferences.autoRefreshInterval, in: 10...120, step: 10)
                            .frame(maxWidth: .infinity)

                        Text("\(Int(preferences.autoRefreshInterval))s")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(width: 45, alignment: .trailing)
                            .monospacedDigit()
                    }

                    Text("How often battery information is updated")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.03))
            )

            Spacer()

            // About Section
            VStack(alignment: .leading, spacing: 4) {
                Text("Battery Monitor v1.0.3")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("macOS Battery & Power Monitoring Tool")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 450, height: 300)
        .background(colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(nsColor: .controlBackgroundColor))
    }
}
