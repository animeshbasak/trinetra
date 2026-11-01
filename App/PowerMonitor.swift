import Foundation
import IOKit.ps
import TrinetraCore

/// Reads AC / battery from IOKit power sources and thermal state from ProcessInfo.
enum PowerMonitor {
    static func snapshot() -> PowerState {
        let thermal = thermalLevel(ProcessInfo.processInfo.thermalState)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerState(onAC: true, batteryPercent: nil, thermal: thermal)
        }
        let providing = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        let onAC = providing == kIOPMACPowerKey

        var percent: Int?
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = Int((Double(current) / Double(max) * 100).rounded())
        }
        return PowerState(onAC: onAC, batteryPercent: percent, thermal: thermal)
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
