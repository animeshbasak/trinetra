import Foundation

public enum SafetyTrip: String, Equatable, Sendable {
    case thermalCritical, batteryFloor, maxHold
}

public struct ReconcileInput {
    public var now: Date
    public var sessions: [SessionRecord]
    public var remotePIDs: [Int32]
    public var control: ControlState
    public var power: PowerState
    public var settings: Settings
    public var holdStartedAt: Date?
    public var isAlive: (Int32) -> Bool

    public init(now: Date, sessions: [SessionRecord], remotePIDs: [Int32] = [],
                control: ControlState = ControlState(), power: PowerState = .unknownAC,
                settings: Settings = Settings(), holdStartedAt: Date? = nil,
                isAlive: @escaping (Int32) -> Bool) {
        self.now = now
        self.sessions = sessions
        self.remotePIDs = remotePIDs
        self.control = control
        self.power = power
        self.settings = settings
        self.holdStartedAt = holdStartedAt
        self.isAlive = isAlive
    }
}

public struct Decision: Equatable, Sendable {
    public var awake: Bool
    public var lidMode: Bool
    public var lowPower: Bool
    public var trip: SafetyTrip?
    public var reasons: [String]
    public var activeSessions: [SessionRecord]

    public init(awake: Bool, lidMode: Bool, lowPower: Bool, trip: SafetyTrip?,
                reasons: [String], activeSessions: [SessionRecord]) {
        self.awake = awake
        self.lidMode = lidMode
        self.lowPower = lowPower
        self.trip = trip
        self.reasons = reasons
        self.activeSessions = activeSessions
    }

    public static let idle = Decision(awake: false, lidMode: false, lowPower: false,
                                      trip: nil, reasons: [], activeSessions: [])
}

/// The heart of Trinetra: a pure function from inputs to the desired power state.
/// No I/O, no clock, no globals. Every rule is covered in ReconcilerTests.
public enum Reconciler {
    public static func decide(_ input: ReconcileInput) -> Decision {
        let s = input.settings
        let now = input.now

        func ignored(_ r: SessionRecord) -> Bool {
            guard let stopAt = input.control.stopAt else { return false }
            return (r.lastActiveAt ?? r.updatedAt) <= stopAt
        }

        // 1. Active sessions
        let active = input.sessions.filter { r in
            guard !ignored(r), input.isAlive(r.pid) else { return false }
            let age = now.timeIntervalSince(r.updatedAt)
            switch r.state {
            case .working: return age < s.staleWorkingSeconds
            case .waiting: return age < s.waitingTimeoutSeconds
            case .idle, .ended: return false
            }
        }

        // 2. Grace after the last activity
        let graceUntil = input.sessions
            .filter { !ignored($0) }
            .compactMap { $0.lastActiveAt?.addingTimeInterval(s.graceSeconds) }
            .max()
        let inGrace = graceUntil.map { $0 > now } ?? false

        // 3. Remote holds
        let ignoredPIDs = Set(input.control.ignoredPIDs)
        let remote = input.remotePIDs.filter { !ignoredPIDs.contains($0) && input.isAlive($0) }

        // 4. Manual timer
        let timerOn = input.control.timerEnd.map { $0 > now } ?? false

        // 5. Want awake?
        var reasons: [String] = []
        if !active.isEmpty {
            reasons.append(active.count == 1 ? "1 agent working" : "\(active.count) agents working")
        }
        if !remote.isEmpty {
            reasons.append(remote.count == 1 ? "1 remote session" : "\(remote.count) remote sessions")
        }
        if timerOn, let end = input.control.timerEnd {
            reasons.append("timer: \(DurationFormat.short(end.timeIntervalSince(now))) left")
        }
        if active.isEmpty && remote.isEmpty && inGrace, let until = graceUntil {
            reasons.append("grace: \(DurationFormat.short(until.timeIntervalSince(now))) left")
        }
        let wantAwake = !active.isEmpty || !remote.isEmpty || inGrace || timerOn

        // 6. Safety trips (first match wins)
        let p = input.power
        var trip: SafetyTrip?
        if p.thermal == .critical {
            trip = .thermalCritical
        } else if !p.onAC, let pct = p.batteryPercent, pct <= s.batteryEndPercent {
            trip = .batteryFloor
        } else if let started = input.holdStartedAt, now.timeIntervalSince(started) >= s.maxHoldSeconds {
            trip = .maxHold
        }
        if let trip, wantAwake {
            reasons.append("stopped: \(trip.message)")
        }

        // 7. Outputs
        let awake = wantAwake && trip == nil
        let lidMode = awake && s.lidClosedMode && (p.onAC || s.allowBatteryLid)
        let lowBattery = !p.onAC && (p.batteryPercent.map { $0 <= s.batteryLowPowerPercent } ?? false)
        let lowPower = awake && (lowBattery || p.thermal >= .serious)

        return Decision(awake: awake, lidMode: lidMode, lowPower: lowPower,
                        trip: wantAwake ? trip : nil, reasons: reasons, activeSessions: active)
    }
}

public extension SafetyTrip {
    var message: String {
        switch self {
        case .thermalCritical: return "Mac is critically hot"
        case .batteryFloor: return "battery floor reached"
        case .maxHold: return "maximum hold time reached"
        }
    }
}
