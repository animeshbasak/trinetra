import Foundation

/// One continuous period Trinetra held the Mac awake, plus how long the Mac slept right after.
public struct HoldRecord: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public var batteryStart: Int?
    public var batteryEnd: Int?
    public var onBatteryStart: Bool
    public var onBatteryEnd: Bool?
    /// Sleep that began within `EnergyEstimate.sleepCreditWindow` of the hold ending.
    public var sleptAfterSeconds: TimeInterval = 0

    public init(start: Date, end: Date? = nil, batteryStart: Int? = nil, batteryEnd: Int? = nil,
                onBatteryStart: Bool, onBatteryEnd: Bool? = nil, sleptAfterSeconds: TimeInterval = 0) {
        self.start = start
        self.end = end
        self.batteryStart = batteryStart
        self.batteryEnd = batteryEnd
        self.onBatteryStart = onBatteryStart
        self.onBatteryEnd = onBatteryEnd
        self.sleptAfterSeconds = sleptAfterSeconds
    }

    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }

    /// Battery percentage points used, only when the whole hold ran on battery.
    public var batteryUsed: Int? {
        guard onBatteryStart, onBatteryEnd == true, let a = batteryStart, let b = batteryEnd, a >= b else { return nil }
        return a - b
    }
}

/// Estimates what letting the Mac sleep after the work saved, compared with keeping it awake
/// (what a timer or `caffeinate` would have done). Pure; every number is labelled an estimate in the UI.
public enum EnergyEstimate {
    /// Typical drain of an awake, mostly idle Apple Silicon MacBook, used until Trinetra has measured this Mac.
    public static let defaultDrainPerHour = 8.0
    /// Sleep only counts as "saved" if it starts this soon after a hold ends.
    public static let sleepCreditWindow: TimeInterval = 15 * 60

    /// Average %/hour measured during holds of 15+ minutes that ran entirely on battery.
    public static func drainPerHour(_ holds: [HoldRecord]) -> Double {
        var used = 0.0, hours = 0.0
        for h in holds {
            guard let pts = h.batteryUsed, let d = h.duration, d >= 900, pts > 0 else { continue }
            used += Double(pts)
            hours += d / 3_600
        }
        guard hours >= 0.25 else { return defaultDrainPerHour }
        return min(max(used / hours, 1), 40)
    }

    public struct Day: Equatable, Sendable {
        public var heldSeconds: TimeInterval = 0
        public var batteryUsed = 0
        public var sleptSeconds: TimeInterval = 0
        /// Battery percentage points not spent because the Mac slept after on-battery holds.
        public var batterySaved = 0.0
        public var holds = 0
    }

    /// Totals for holds that started on the same calendar day as `now`.
    public static func day(_ holds: [HoldRecord], now: Date, calendar: Calendar = .current) -> Day {
        let rate = drainPerHour(holds)
        var d = Day()
        for h in holds where calendar.isDate(h.start, inSameDayAs: now) {
            d.holds += 1
            d.heldSeconds += max(0, (h.end ?? now).timeIntervalSince(h.start))
            d.batteryUsed += h.batteryUsed ?? 0
            d.sleptSeconds += h.sleptAfterSeconds
            if h.onBatteryEnd == true {
                let saved = h.sleptAfterSeconds / 3_600 * rate
                d.batterySaved += min(saved, Double(h.batteryEnd ?? 100))
            }
        }
        return d
    }

    /// Credits a sleep period to the most recent hold if it began soon after that hold ended.
    public static func creditSleep(_ holds: inout [HoldRecord], sleptAt: Date, wokeAt: Date) {
        guard let i = holds.lastIndex(where: { $0.end != nil }), let end = holds[i].end else { return }
        let gap = sleptAt.timeIntervalSince(end)
        guard gap >= 0, gap <= sleepCreditWindow, wokeAt > sleptAt else { return }
        holds[i].sleptAfterSeconds += wokeAt.timeIntervalSince(sleptAt)
    }

    public static func load(from paths: Paths) -> [HoldRecord] {
        (try? JSON.read([HoldRecord].self, from: paths.holds)) ?? []
    }

    /// Keeps the newest 200 holds.
    public static func save(_ holds: [HoldRecord], to paths: Paths) throws {
        try paths.ensureDirectories()
        try JSON.write(Array(holds.suffix(200)), to: paths.holds)
    }
}
