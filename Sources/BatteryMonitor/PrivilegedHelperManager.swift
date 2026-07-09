import AppKit
import BatteryMonitorShared
import Foundation
import ServiceManagement

enum PrivilegedHelperRegistration: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unsupported
    case unknown
}

struct PrivilegedHelperControlState: Equatable {
    static let toggleTitle = "Run as root at startup"

    let registration: PrivilegedHelperRegistration
    let telemetryStatus: String

    var isToggleOn: Bool {
        registration == .enabled || registration == .requiresApproval
    }

    var statusText: String {
        switch registration {
        case .enabled:
            return "Root helper registered"
        case .requiresApproval:
            return "Admin approval needed"
        case .notRegistered:
            return "Root helper off"
        case .notFound:
            return "Bundled helper not found"
        case .unsupported:
            return "Unsupported on this macOS version"
        case .unknown:
            return "Unknown helper status"
        }
    }

    var detailText: String {
        switch registration {
        case .enabled:
            if telemetryStatus.lowercased().contains("active") {
                return "The root LaunchDaemon persists across login and boot after registration. \(telemetryStatus)."
            }
            return "The root LaunchDaemon persists across login and boot after registration."
        case .requiresApproval:
            return "macOS needs admin approval before the root LaunchDaemon can run."
        case .notRegistered:
            return "Enable this to register the root LaunchDaemon for privileged thermal data."
        case .notFound:
            return "Install the app from the DMG so the bundled LaunchDaemon plist is available."
        case .unsupported:
            return "LaunchDaemon registration requires macOS 13 or later."
        case .unknown:
            return "Refresh or open System Settings to check helper registration."
        }
    }

    var showsApprovalButton: Bool {
        registration == .requiresApproval
    }
}

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

    func registrationState() -> PrivilegedHelperRegistration {
        guard #available(macOS 13.0, *) else {
            return .unsupported
        }

        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    func statusText() -> String {
        switch registrationState() {
        case .enabled:
            return "Registered, waiting for telemetry"
        case .requiresApproval:
            return "Needs admin approval in System Settings"
        case .notRegistered:
            return "Not registered"
        case .notFound:
            return "Bundled daemon plist not found"
        case .unsupported:
            return "Unsupported on this macOS version"
        case .unknown:
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
