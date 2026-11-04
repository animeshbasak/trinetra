import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Safety rules the root helper enforces on its own, independent of the app (LLD §16).
/// The app's Reconciler already stops a hold at the battery floor; this is the second line:
/// if the app is napped, hung, or out of sync, the helper still restores normal sleep.
public enum HelperSafety {
    /// Hard floor on battery. Matches the default `Settings.batteryEndPercent`; the app may stop earlier.
    public static let batteryFloorPercent = 10

    /// True when lid sleep must not stay disabled: on battery at or below the floor, or thermal critical.
    public static func mustRestoreSleep(onAC: Bool, batteryPercent: Int?, thermalCritical: Bool) -> Bool {
        if thermalCritical { return true }
        guard !onAC, let pct = batteryPercent else { return false }
        return pct <= batteryFloorPercent
    }

    public static func refusalMessage(batteryPercent: Int?) -> String {
        let pct = batteryPercent.map { "\($0) %" } ?? "low"
        return "Battery at \(pct). Lid mode stays off at \(batteryFloorPercent) % or less on battery."
    }
}

/// What the app does with lid sleep on each tick. Pure, so the release path is unit-tested.
public enum LidAction: Equatable, Sendable {
    case none, disable, restore
}

public enum LidPlanner {
    /// - wanted: the Reconciler wants lid mode right now (awake, lid mode on, no safety trip)
    /// - appHolds: the app believes it asked the helper to disable lid sleep
    /// - systemSleepDisabled: the live `SleepDisabled` flag from `pmset -g`
    /// - lidModeOn: the user's lid mode switch (Trinetra only restores a flag it may have set)
    public static func action(wanted: Bool, appHolds: Bool, systemSleepDisabled: Bool,
                              lidModeOn: Bool, requestInFlight: Bool, helperReady: Bool) -> LidAction {
        if requestInFlight { return .none }
        if wanted {
            return (!appHolds && helperReady) ? .disable : .none
        }
        if appHolds { return .restore }
        // Out of sync: the app lost track, but sleep is still disabled. Put it back.
        if systemSleepDisabled && lidModeOn && helperReady { return .restore }
        return .none
    }
}

#if canImport(IOKit)
/// Battery and AC state from IOKit power sources. Safe to call from a root daemon.
public enum PowerSourceReader {
    public static func read() -> (onAC: Bool, batteryPercent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (true, nil)
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
        return (onAC, percent)
    }
}
#endif
