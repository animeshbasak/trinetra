import Foundation

/// Reads and writes session files under `Paths.sessions`. Corrupt files are skipped, never fatal.
public struct SessionStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func url(for key: String) -> URL {
        paths.sessions.appendingPathComponent("\(key).json")
    }

    public func load(key: String) -> SessionRecord? {
        try? JSON.read(SessionRecord.self, from: url(for: key))
    }

    public func loadAll() -> [SessionRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSON.read(SessionRecord.self, from: $0) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func save(_ record: SessionRecord) throws {
        try paths.ensureDirectories()
        try JSON.write(record, to: url(for: record.key))
    }

    /// Inserts a new record or transitions the existing one.
    @discardableResult
    public func upsert(agent: String, id: String, state: AgentState, pid: Int32,
                       cwd: String?, now: Date, activity: String? = nil) throws -> SessionRecord {
        let key = SessionRecord(agent: agent, id: id, state: state, pid: pid,
                                startedAt: now, updatedAt: now).key
        let record: SessionRecord
        if let existing = load(key: key) {
            record = existing.transitioned(to: state, at: now, pid: pid, cwd: cwd, activity: activity)
        } else {
            record = SessionRecord(agent: agent, id: id, state: state, pid: pid, cwd: cwd,
                                   startedAt: now, updatedAt: now,
                                   lastActiveAt: state.isActive ? now : nil, activity: activity,
                                   turnStartedAt: state == .working ? now : nil)
        }
        try save(record)
        return record
    }

    /// Deletes ended or dead sessions not updated for `olderThan` seconds. Returns removed keys.
    @discardableResult
    public func prune(now: Date, olderThan: TimeInterval = 86_400,
                      isAlive: (Int32) -> Bool) -> [String] {
        var removed: [String] = []
        for record in loadAll() where now.timeIntervalSince(record.updatedAt) > olderThan {
            if record.state == .ended || !isAlive(record.pid) {
                try? FileManager.default.removeItem(at: url(for: record.key))
                removed.append(record.key)
            }
        }
        return removed
    }
}
