import Foundation

public enum AgentState: String, Codable, Sendable, CaseIterable {
    case working, waiting, idle, ended

    /// Working and waiting both mean "an agent needs the Mac right now".
    public var isActive: Bool { self == .working || self == .waiting }
}

/// One agent session (or one `trinetra run` child), written by the CLI and read by the app.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var agent: String
    public var id: String
    public var state: AgentState
    public var pid: Int32
    public var cwd: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var lastActiveAt: Date?
    /// Short, privacy-safe description of what the agent is doing (see ActivitySummary).
    public var activity: String?
    /// When the current (or last) working turn began.
    public var turnStartedAt: Date?

    public init(agent: String, id: String, state: AgentState, pid: Int32, cwd: String? = nil,
                startedAt: Date, updatedAt: Date, lastActiveAt: Date? = nil,
                activity: String? = nil, turnStartedAt: Date? = nil) {
        self.agent = agent
        self.id = id
        self.state = state
        self.pid = pid
        self.cwd = cwd
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastActiveAt = lastActiveAt
        self.activity = activity
        self.turnStartedAt = turnStartedAt
    }

    /// File-safe key, e.g. `claude-3f2a…`.
    public var key: String {
        let safeID = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return "\(agent)-\(String(safeID))"
    }

    /// Only the last path component is ever shown or logged.
    public var cwdName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Returns a copy moved to `state` at `now`, keeping `lastActiveAt` current.
    public func transitioned(to newState: AgentState, at now: Date, pid newPID: Int32? = nil,
                             cwd newCwd: String? = nil, activity newActivity: String? = nil) -> SessionRecord {
        var next = self
        next.state = newState
        next.updatedAt = now
        if let newPID { next.pid = newPID }
        if let newCwd { next.cwd = newCwd }
        if let newActivity { next.activity = newActivity }
        if newState == .working && state != .working { next.turnStartedAt = now }
        // Leaving an active state also counts as activity, so grace starts from the end of the turn.
        if newState.isActive || state.isActive { next.lastActiveAt = now }
        return next
    }
}
