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
    /// Toolkit modules the user turned on (architecture/TOOLKIT.md). All off by default.
    public var modules = ModuleSet()
    public var alerts = AlertThresholds()
    /// What the menu bar shows next to the eye while the system monitor is on.
    public var menuBarReadout: MenuBarReadout = .none

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
        modules = try c.decodeIfPresent(ModuleSet.self, forKey: .modules) ?? d.modules
        alerts = try c.decodeIfPresent(AlertThresholds.self, forKey: .alerts) ?? d.alerts
        menuBarReadout = (try? c.decodeIfPresent(MenuBarReadout.self, forKey: .menuBarReadout)) ?? d.menuBarReadout
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

/// Menu bar text beside the eye (system monitor on only).
public enum MenuBarReadout: String, Codable, CaseIterable, Sendable {
    case none, cpu, temperature, power, memory, network

    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .cpu: return "CPU"
        case .temperature: return "Temperature"
        case .power: return "Power draw"
        case .memory: return "Memory"
        case .network: return "Network"
        }
    }

    /// Short text for the menu bar, or nil when there is nothing to show.
    public func text(for s: SystemSnapshot?) -> String? {
        guard let s else { return nil }
        switch self {
        case .none: return nil
        case .cpu: return s.cpu.map(MetricFormat.percent)
        case .temperature: return s.hottest.map(MetricFormat.celsius)
        case .power: return s.battery?.drawWatts.map(MetricFormat.watts)
        case .memory: return s.memory.map { MetricFormat.percent($0.usedFraction) }
        case .network:
            guard let d = s.downBytesPerSec, let u = s.upBytesPerSec else { return nil }
            return "↓\(MetricFormat.rate(d)) ↑\(MetricFormat.rate(u))"
        }
    }
}
