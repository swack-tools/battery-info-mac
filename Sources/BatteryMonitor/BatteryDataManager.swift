import Foundation
import Combine

/// Shared battery data manager that can be observed by multiple views
class BatteryDataManager: ObservableObject {
    @Published var batteryInfo: BatteryDisplayInfo = BatteryDisplayInfo()
    @Published var lastUpdate: Date = Date()

    static let shared = BatteryDataManager()

    private let refreshQueue = DispatchQueue(label: "com.batterymonitor.refresh", qos: .userInitiated)
    private var isRefreshing = false

    private init() {
        refresh()
    }

    func refresh() {
        // Prevent multiple simultaneous refreshes
        guard !isRefreshing else { return }
        isRefreshing = true

        // Fetch data on background queue to avoid blocking UI
        refreshQueue.async { [weak self] in
            let newInfo = BatteryDisplayInfo.fetch()
            let updateTime = Date()

            // Update @Published properties on main thread
            DispatchQueue.main.async {
                self?.batteryInfo = newInfo
                self?.lastUpdate = updateTime
                self?.isRefreshing = false
            }
        }
    }
}
