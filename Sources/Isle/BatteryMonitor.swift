import Foundation
import IOKit.ps

final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Int?      // nil on Macs without a battery
    @Published private(set) var charging = false
    private var timer: Timer?

    func start() {
        update()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func update() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [AnyObject] else {
            level = nil
            return
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            let maxCapacity = max(desc[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            level = Int((Double(current) / Double(maxCapacity) * 100).rounded())
            charging = (desc[kIOPSIsChargingKey] as? Bool ?? false)
                || (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return
        }
        level = nil
    }

    var symbol: String {
        if charging { return "battery.100.bolt" }
        switch level ?? 0 {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
