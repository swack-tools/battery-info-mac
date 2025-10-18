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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusButton()
        }

        // Create the popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BatteryDetailView())
        self.popover = popover

        // Start auto-refresh timer (every 30 seconds)
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateStatusButton()
            self?.refreshPopover()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        // Get battery data
        let batteryData = IOKitBattery.getBatteryInfo()

        // Use computed battery percentage
        let percentage = batteryData.batteryPercentage
        let isCharging = batteryData.isCharging
        let isPluggedIn = batteryData.externalConnected

        // Debug logging
        print("DEBUG: currentCapacity=\(batteryData.currentCapacity), maxCapacity=\(batteryData.maxCapacity), percentage=\(percentage)")

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

    func refreshPopover() {
        // Refresh the popover content if it's showing
        if let popover = popover, popover.isShown {
            popover.contentViewController = NSHostingController(rootView: BatteryDetailView())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
}
