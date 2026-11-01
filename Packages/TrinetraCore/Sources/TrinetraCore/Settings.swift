import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var graceSeconds: TimeInterval = 180
    public var waitingTimeoutSeconds: TimeInterval = 1_800
    public var staleWorkingSeconds: TimeInterval = 14_400
    public var maxHoldSeconds: TimeInterval = 43_200
    public var batteryEndPercent: Int = 10
    public var batteryLowPowerPercent: Int = 40
    public var lidClosedMode: Bool = true
    public var allowBatteryLid: Bool = true
    public var processRules: [ProcessRule] = ProcessRule.defaults

    public init() {}

    // Decode field by field so a partial or older settings.json keeps defaults for missing keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        graceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .graceSeconds) ?? d.graceSeconds
        waitingTimeoutSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .waitingTimeoutSeconds) ?? d.waitingTimeoutSeconds
        staleWorkingSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .staleWorkingSeconds) ?? d.staleWorkingSeconds
        maxHoldSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .maxHoldSeconds) ?? d.maxHoldSeconds
        batteryEndPercent = try c.decodeIfPresent(Int.self, forKey: .batteryEndPercent) ?? d.batteryEndPercent
        batteryLowPowerPercent = try c.decodeIfPresent(Int.self, forKey: .batteryLowPowerPercent) ?? d.batteryLowPowerPercent
        lidClosedMode = try c.decodeIfPresent(Bool.self, forKey: .lidClosedMode) ?? d.lidClosedMode
        allowBatteryLid = try c.decodeIfPresent(Bool.self, forKey: .allowBatteryLid) ?? d.allowBatteryLid
        processRules = try c.decodeIfPresent([ProcessRule].self, forKey: .processRules) ?? d.processRules
    }

    /// Missing or invalid file → defaults (the file is left untouched).
    public static func load(from paths: Paths) -> Settings {
        (try? JSON.read(Settings.self, from: paths.settings)) ?? Settings()
    }

    public func save(to paths: Paths) throws {
        try paths.ensureDirectories()
        try JSON.write(self, to: paths.settings)
    }
}
