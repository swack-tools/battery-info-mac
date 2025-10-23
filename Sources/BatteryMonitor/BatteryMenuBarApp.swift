import SwiftUI
import AppKit

@main
struct BatteryMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var timer: Timer?
    var contextMenu: NSMenu?
    var preferencesWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pre-cache battery data at startup for instant popover display
        BatteryDataManager.shared.refresh()

        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            updateStatusButton()
        }

        // Create the context menu (but don't assign it yet)
        contextMenu = createMenu()

        // Create the popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BatteryDetailView())
        self.popover = popover

        // Start auto-refresh timer using preference interval
        startRefreshTimer()

        // Observe preference changes to update timer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func startRefreshTimer() {
        timer?.invalidate()
        let interval = PreferencesManager.shared.autoRefreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateStatusButton()
            self?.refreshPopover()
        }
    }

    @objc func preferencesDidChange() {
        // Restart timer with new interval
        startRefreshTimer()
    }

    func createMenu() -> NSMenu {
        let menu = NSMenu()

        // Refresh item
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences item
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(menuPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        // Quit item
        let quitItem = NSMenuItem(title: "Quit Battery Monitor", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc func menuRefresh() {
        updateStatusButton()
        BatteryDataManager.shared.refresh()
    }

    @objc func menuPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let preferencesView = PreferencesView()
            let hostingController = NSHostingController(rootView: preferencesView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Preferences"
            window.styleMask = [.titled, .closable]
            window.level = .floating
            window.center()
            window.setFrameAutosaveName("PreferencesWindow")
            window.isReleasedWhenClosed = false

            preferencesWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc func handleClick() {
        guard let button = statusItem?.button else { return }

        // Check if this is a right-click
        if let event = NSApp.currentEvent {
            if event.type == .rightMouseUp {
                // Right-click: show context menu
                statusItem?.menu = contextMenu
                statusItem?.button?.performClick(nil)
                // Clear menu after it's shown so left-click works
                DispatchQueue.main.async { [weak self] in
                    self?.statusItem?.menu = nil
                }
                return
            }
        }

        // Left-click: show/hide popover
        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    func updateStatusButton() {
        // Fetch battery data on background queue to avoid UI lag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let batteryData = IOKitBattery.getBatteryInfo()

            // Use computed battery percentage
            let percentage = batteryData.batteryPercentage
            let isCharging = batteryData.isCharging
            let isPluggedIn = batteryData.externalConnected

            // Update UI on main thread
            DispatchQueue.main.async {
                guard let self = self, let button = self.statusItem?.button else { return }

                if percentage >= 0 {
                    // Create status text
                    let chargingSymbol = isCharging ? "⚡" : (isPluggedIn ? "🔌" : "")
                    button.title = String(format: "%@%.0f%%", chargingSymbol, Double(percentage))

                    // Set tooltip
                    button.toolTip = String(format: "Battery: %.0f%%\n%@",
                                           percentage,
                                           isCharging ? "Charging" : (isPluggedIn ? "Plugged In" : "On Battery"))
                } else {
                    button.title = "🔋?"
                    button.toolTip = "Battery information unavailable"
                }
            }
        }
    }

    func refreshPopover() {
        // Refresh the data (SwiftUI will automatically update the view)
        BatteryDataManager.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
}
