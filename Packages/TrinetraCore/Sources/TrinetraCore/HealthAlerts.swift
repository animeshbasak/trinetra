import Foundation

/// When to warn. Stored in settings.json under `alerts`; missing keys keep these defaults.
public struct AlertThresholds: Codable, Equatable, Sendable {
    /// Whole-Mac CPU above this (0…100) …
    public var cpuPercent: Double = 90
    /// … for at least this long.
    public var cpuSustainSeconds: TimeInterval = 120
    /// Hottest die sensor, °C.
    public var temperatureC: Double = 95
    /// Warn at macOS memory pressure "high" (warning) or only at "critical".
    public var memoryPressure: MemoryPressure = .warning
    /// Free space on the startup disk, GB.
    public var diskFreeGB: Double = 10
    /// On battery, at or below this percent.
    public var batteryPercent: Int = 20
    /// Re-warn about the same thing no sooner than this after it cleared.
    public var cooldownSeconds: TimeInterval = 900

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertThresholds()
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? d.cpuPercent
        cpuSustainSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .cpuSustainSeconds) ?? d.cpuSustainSeconds
        temperatureC = try c.decodeIfPresent(Double.self, forKey: .temperatureC) ?? d.temperatureC
        memoryPressure = try c.decodeIfPresent(MemoryPressure.self, forKey: .memoryPressure) ?? d.memoryPressure
        diskFreeGB = try c.decodeIfPresent(Double.self, forKey: .diskFreeGB) ?? d.diskFreeGB
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent) ?? d.batteryPercent
        cooldownSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .cooldownSeconds) ?? d.cooldownSeconds
    }
}

public enum HealthAlertKind: String, Codable, CaseIterable, Sendable {
    case cpu, temperature, thermal, memory, disk, battery
}

public struct HealthAlert: Equatable, Sendable {
    public var kind: HealthAlertKind
    public var title: String
    public var body: String

    public init(kind: HealthAlertKind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// What the evaluator remembers between samples.
public struct HealthAlertState: Equatable, Sendable {
    /// When CPU first went over the threshold in the current stretch.
    public var cpuHighSince: Date?
    /// Conditions currently raised (warned about and not yet cleared).
    public var raised: Set<HealthAlertKind> = []
    /// When each condition last cleared, for the cooldown.
    public var clearedAt: [HealthAlertKind: Date] = [:]

    public init() {}
}

/// Pure: snapshot + thresholds + memory → alerts to post now. Each condition warns once when it
/// starts, stays quiet while it lasts, and clears only with some margin (hysteresis), so a value
/// hovering at the line doesn't produce a stream of notifications.
public enum HealthAlerts {
    static let cpuClearMargin = 15.0      // percentage points
    static let temperatureClearMargin = 8.0
    static let diskClearMarginGB = 2.0
    static let batteryClearMargin = 5

    public static func evaluate(_ s: SystemSnapshot, thresholds t: AlertThresholds,
                                state: HealthAlertState) -> (alerts: [HealthAlert], state: HealthAlertState) {
        var next = state
        var alerts: [HealthAlert] = []
        let now = s.at

        func update(_ kind: HealthAlertKind, raise: Bool, clear: Bool, alert: @autoclosure () -> HealthAlert) {
            if next.raised.contains(kind) {
                if clear {
                    next.raised.remove(kind)
                    next.clearedAt[kind] = now
                }
            } else if raise {
                if let cleared = next.clearedAt[kind], now.timeIntervalSince(cleared) < t.cooldownSeconds { return }
                next.raised.insert(kind)
                alerts.append(alert())
            }
        }

        // CPU: sustained load only; a compile spike is normal.
        if let cpu = s.cpu.map({ $0 * 100 }) {
            if cpu >= t.cpuPercent {
                if next.cpuHighSince == nil { next.cpuHighSince = now }
            } else if cpu < t.cpuPercent - cpuClearMargin {
                next.cpuHighSince = nil
            }
            let sustained = next.cpuHighSince.map { now.timeIntervalSince($0) >= t.cpuSustainSeconds } ?? false
            let minutes = max(1, Int((t.cpuSustainSeconds / 60).rounded()))
            update(.cpu, raise: sustained, clear: next.cpuHighSince == nil,
                   alert: HealthAlert(kind: .cpu, title: "CPU busy",
                                      body: "The Mac has been above \(Int(t.cpuPercent)) % CPU for \(minutes) min (now \(Int(cpu.rounded())) %)."))
        }

        if let hot = s.hottest {
            update(.temperature, raise: hot >= t.temperatureC, clear: hot < t.temperatureC - temperatureClearMargin,
                   alert: HealthAlert(kind: .temperature, title: "Mac running hot",
                                      body: "Hottest sensor at \(MetricFormat.celsius(hot)). Check that the vents are clear."))
        }

        update(.thermal, raise: s.thermal >= .serious, clear: s.thermal <= .fair,
               alert: HealthAlert(kind: .thermal, title: "macOS is slowing the Mac to cool it",
                                  body: "Thermal state is \(s.thermal == .critical ? "critical" : "serious"). Long agent runs will be slower until it cools."))

        update(.memory, raise: s.memoryPressure >= t.memoryPressure, clear: s.memoryPressure == .normal,
               alert: HealthAlert(kind: .memory, title: "Memory pressure \(s.memoryPressure.label)",
                                  body: memoryBody(s)))

        if let free = s.diskFree {
            let gb = Double(free) / 1_073_741_824
            update(.disk, raise: gb < t.diskFreeGB, clear: gb >= t.diskFreeGB + diskClearMarginGB,
                   alert: HealthAlert(kind: .disk, title: "Startup disk almost full",
                                      body: "\(MetricFormat.bytes(free)) free. Builds and agents may start failing."))
        }

        if let b = s.battery, let pct = b.percent {
            let draining = !b.onAC && !b.charging
            update(.battery, raise: draining && pct <= t.batteryPercent,
                   clear: !draining || pct > t.batteryPercent + batteryClearMargin,
                   alert: HealthAlert(kind: .battery, title: "Battery at \(pct) %",
                                      body: batteryBody(b)))
        }

        return (alerts, next)
    }

    static func memoryBody(_ s: SystemSnapshot) -> String {
        guard let m = s.memory else { return "Apps may slow down." }
        var body = "\(MetricFormat.bytes(m.used)) of \(MetricFormat.bytes(m.total)) used"
        if m.swapUsed > 0 { body += ", \(MetricFormat.bytes(m.swapUsed)) swapped to disk" }
        return body + "."
    }

    static func batteryBody(_ b: BatteryInfo) -> String {
        var body = "On battery"
        if let mins = b.minutesRemaining, mins > 0 { body += ", about \(DurationFormat.short(Double(mins) * 60)) left" }
        return body + ". Plug in to keep agents running."
    }
}
