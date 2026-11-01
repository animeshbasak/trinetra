import Foundation

/// Manual controls shared by the CLI, the menu and (Sprint 3) Telegram.
public struct ControlState: Codable, Equatable, Sendable {
    /// Keep awake until this time regardless of agents.
    public var timerEnd: Date?
    /// "Stop now": activity with `lastActiveAt <= stopAt` is ignored.
    public var stopAt: Date?
    /// Remote-hold pids the app snapshotted when a stop was requested.
    public var ignoredPIDs: [Int32]

    public init(timerEnd: Date? = nil, stopAt: Date? = nil, ignoredPIDs: [Int32] = []) {
        self.timerEnd = timerEnd
        self.stopAt = stopAt
        self.ignoredPIDs = ignoredPIDs
    }

    public mutating func start(for duration: TimeInterval, now: Date) {
        timerEnd = now.addingTimeInterval(duration)
        stopAt = nil
        ignoredPIDs = []
    }

    public mutating func extend(by duration: TimeInterval, now: Date) {
        let base = max(now, timerEnd ?? now)
        timerEnd = base.addingTimeInterval(duration)
        stopAt = nil
        ignoredPIDs = []
    }

    public mutating func stop(now: Date) {
        timerEnd = nil
        stopAt = now
    }

    public static func load(from paths: Paths) -> ControlState {
        (try? JSON.read(ControlState.self, from: paths.control)) ?? ControlState()
    }

    public func save(to paths: Paths) throws {
        try paths.ensureDirectories()
        try JSON.write(self, to: paths.control)
    }
}
