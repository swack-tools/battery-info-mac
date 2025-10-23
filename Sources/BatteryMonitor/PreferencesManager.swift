import Foundation
import ServiceManagement

class PreferencesManager: ObservableObject {
    static let shared = PreferencesManager()

    @Published var launchAtLogin: Bool {
        didSet {
            setLaunchAtLogin(launchAtLogin)
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }

    @Published var autoRefreshInterval: Double {
        didSet {
            UserDefaults.standard.set(autoRefreshInterval, forKey: "autoRefreshInterval")
        }
    }

    private init() {
        // Load saved preferences
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.autoRefreshInterval = UserDefaults.standard.double(forKey: "autoRefreshInterval")

        // Set default values if not set
        if autoRefreshInterval == 0 {
            autoRefreshInterval = 30.0 // 30 seconds default
        }

        // Sync launch at login state with system
        syncLaunchAtLoginState()
    }

    private func syncLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            let currentStatus = service.status == .enabled

            // Update our stored preference to match system state
            if currentStatus != launchAtLogin {
                launchAtLogin = currentStatus
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp

            // Check if app is in Applications folder
            let bundlePath = Bundle.main.bundlePath
            if !bundlePath.contains("/Applications/") {
                print("⚠️  Launch at Login requires app to be in /Applications")
                print("   Current location: \(bundlePath)")
                print("   Run: ./install_app.sh")
                return
            }

            do {
                if enabled {
                    if service.status != .enabled {
                        try service.register()
                        print("✓ Launch at login enabled")
                    }
                } else {
                    if service.status == .enabled {
                        try service.unregister()
                        print("✓ Launch at login disabled")
                    }
                }
            } catch {
                print("❌ Failed to \(enabled ? "enable" : "disable") launch at login:")
                print("   \(error.localizedDescription)")
                print("   App location: \(bundlePath)")
                print("   Tip: Make sure the app is in /Applications and has proper bundle structure")
            }
        }
    }
}
