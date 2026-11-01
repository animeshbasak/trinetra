#if canImport(ObjectiveC)
import Foundation

/// XPC contract between Trinetra.app and the root helper (Sprint 2).
/// Keep this surface tiny: Bool arguments only, no paths, no shell.
@objc public protocol TrinetraHelperProtocol {
    func setLidSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func heartbeat(reply: @escaping () -> Void)
    func state(reply: @escaping (_ lidSleepDisabled: Bool, _ lowPower: Bool) -> Void)
}

public enum HelperConstants {
    public static let machServiceName = "com.insanemesh.trinetra.helper"
    public static let daemonPlistName = "com.insanemesh.trinetra.helper.plist"
    public static let appBundleID = "com.insanemesh.trinetra"
    public static let heartbeatInterval: TimeInterval = 30
    public static let deadManTimeout: TimeInterval = 120
}
#endif
