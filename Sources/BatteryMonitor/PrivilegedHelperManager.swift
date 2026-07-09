import AppKit
import BatteryMonitorShared
import Foundation
import ServiceManagement

final class PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()

    static let cacheURL = URL(fileURLWithPath: "/Library/Application Support/BatteryMonitor/privileged-telemetry.json")
    static let plistName = "com.swacktools.batterymonitor.helper.plist"

    private init() {}

    struct CachedTelemetry {
        let snapshot: ThermalSnapshot
        let age: TimeInterval
    }

    static func cachedTelemetry(maxAge: TimeInterval = 120) -> CachedTelemetry? {
        guard let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let snapshot = try? decoder.decode(ThermalSnapshot.self, from: data) else {
            return nil
        }

        let age = Date().timeIntervalSince(snapshot.generatedAt)
        guard age >= 0, age <= maxAge else {
            return nil
        }

        return CachedTelemetry(snapshot: snapshot, age: age)
    }

    func statusText() -> String {
        guard #available(macOS 13.0, *) else {
            return "Unsupported on this macOS version"
        }

        switch service.status {
        case .enabled:
            return "Registered, waiting for telemetry"
        case .requiresApproval:
            return "Needs admin approval in System Settings"
        case .notRegistered:
            return "Not registered"
        case .notFound:
            return "Bundled daemon plist not found"
        @unknown default:
            return "Unknown helper status"
        }
    }

    func registerHelper() -> String {
        guard #available(macOS 13.0, *) else {
            return "Helper registration requires macOS 13 or later"
        }

        do {
            try service.register()
            return statusText()
        } catch {
            return "Registration failed: \(error.localizedDescription)"
        }
    }

    func unregisterHelper() -> String {
        guard #available(macOS 13.0, *) else {
            return "Helper registration requires macOS 13 or later"
        }

        do {
            try service.unregister()
            return statusText()
        } catch {
            return "Unregister failed: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    static func ageDescription(_ age: TimeInterval) -> String {
        if age < 1 {
            return "just now"
        }
        if age < 60 {
            return "\(Int(age))s ago"
        }
        return "\(Int(age / 60))m ago"
    }

    @available(macOS 13.0, *)
    private var service: SMAppService {
        SMAppService.daemon(plistName: Self.plistName)
    }
}
