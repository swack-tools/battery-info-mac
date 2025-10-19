import Foundation
import Combine

/// Shared battery data manager that can be observed by multiple views
class BatteryDataManager: ObservableObject {
    @Published var batteryInfo: BatteryDisplayInfo = BatteryDisplayInfo()
    @Published var lastUpdate: Date = Date()

    static let shared = BatteryDataManager()

    private init() {
        refresh()
    }

    func refresh() {
        batteryInfo = BatteryDisplayInfo.fetch()
        lastUpdate = Date()
    }
}
