import Foundation

/// One line of a session's activity log (`sessions/<key>.events.jsonl`).
/// Holds only a kind, a file name or a command's first word, and a timestamp: never prompt or reply text.
public struct SessionEvent: Codable, Equatable, Sendable {
    public var t: Date
    public var state: AgentState
    public var kind: ActivitySummary.Kind
    public var detail: String?

    public init(t: Date, state: AgentState, kind: ActivitySummary.Kind, detail: String? = nil) {
        self.t = t
        self.state = state
        self.kind = kind
        self.detail = detail
    }
}

/// Append-only, size-capped log of `SessionEvent`s. Corrupt lines are skipped.
public struct SessionLog: Sendable {
    public let paths: Paths
    /// The log is trimmed to its newest half when it grows past this.
    public var maxBytes = 256 * 1024

    public init(paths: Paths) { self.paths = paths }

    public func append(_ event: SessionEvent, key: String) throws {
        try paths.ensureDirectories()
        let url = paths.events(for: key)
        var line = try JSON.lineEncoder.encode(event)
        line.append(0x0A)
        let fm = FileManager.default
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            trim(url)
        }
    }

    public func load(key: String) -> [SessionEvent] {
        guard let data = try? Data(contentsOf: paths.events(for: key)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSON.decoder.decode(SessionEvent.self, from: Data($0)) }
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: paths.events(for: key))
    }

    private func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        let kept = lines.suffix(lines.count / 2)
        var out = Data()
        for line in kept { out.append(contentsOf: line); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }
}

/// What an agent did in one session, computed from its log. Pure.
public struct SessionSummary: Equatable, Sendable {
    public var prompts = 0
    public var turns = 0
    public var approvals = 0
    public var filesEdited: [String] = []
    public var editCount = 0
    public var filesRead = 0
    public var commands: [String: Int] = [:]
    public var searches = 0
    public var webLookups = 0
    public var subagents = 0
    public var otherTools = 0
    public var activeSeconds: TimeInterval = 0
    public var firstAt: Date?
    public var lastAt: Date?

    public var commandCount: Int { commands.values.reduce(0, +) }

    /// Most-used commands first, e.g. [("swift", 8), ("git", 3)].
    public var topCommands: [(String, Int)] {
        commands.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Longest gap between two events that still counts as continuous work.
    public static let maxActiveGap: TimeInterval = 1_800

    public static func build(_ events: [SessionEvent], now: Date) -> SessionSummary {
        var s = SessionSummary()
        let sorted = events.sorted { $0.t < $1.t }
        s.firstAt = sorted.first?.t
        s.lastAt = sorted.last?.t
        var editedSet = Set<String>()
        for (i, e) in sorted.enumerated() {
            switch e.kind {
            case .prompt: s.prompts += 1
            case .turnEnd: s.turns += 1
            case .approval: s.approvals += 1
            case .edit:
                s.editCount += 1
                if let file = e.detail, !editedSet.contains(file) {
                    editedSet.insert(file)
                    s.filesEdited.append(file)
                }
            case .read: s.filesRead += 1
            case .command: s.commands[e.detail ?? "command", default: 0] += 1
            case .search: s.searches += 1
            case .web: s.webLookups += 1
            case .subagent: s.subagents += 1
            case .tool: s.otherTools += 1
            case .start, .end, .plan, .progress: break
            }
            if e.state == .working {
                let next = i + 1 < sorted.count ? sorted[i + 1].t : now
                s.activeSeconds += min(max(0, next.timeIntervalSince(e.t)), maxActiveGap)
            }
        }
        return s
    }

    /// e.g. "6 prompts · 9 files edited · 14 commands · 42m active"
    public var headline: String {
        var parts: [String] = []
        if prompts > 0 { parts.append(prompts == 1 ? "1 prompt" : "\(prompts) prompts") }
        if !filesEdited.isEmpty { parts.append(filesEdited.count == 1 ? "1 file edited" : "\(filesEdited.count) files edited") }
        else if editCount > 0 { parts.append(editCount == 1 ? "1 edit" : "\(editCount) edits") }
        if commandCount > 0 { parts.append(commandCount == 1 ? "1 command" : "\(commandCount) commands") }
        if activeSeconds >= 60 { parts.append("\(DurationFormat.short(activeSeconds)) active") }
        return parts.isEmpty ? "No activity yet" : parts.joined(separator: " · ")
    }

    /// Detail lines for the menu and `trinetra summary`.
    public var detailLines: [String] {
        var lines: [String] = []
        if !filesEdited.isEmpty {
            let shown = filesEdited.prefix(4).joined(separator: ", ")
            let more = filesEdited.count > 4 ? " +\(filesEdited.count - 4) more" : ""
            lines.append("Edited \(shown)\(more)")
        }
        if commandCount > 0 {
            let shown = topCommands.prefix(4).map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
            lines.append("Ran \(shown)")
        }
        var other: [String] = []
        if filesRead > 0 { other.append("read \(filesRead) file\(filesRead == 1 ? "" : "s")") }
        if searches > 0 { other.append("\(searches) search\(searches == 1 ? "" : "es")") }
        if webLookups > 0 { other.append("\(webLookups) web lookup\(webLookups == 1 ? "" : "s")") }
        if subagents > 0 { other.append("\(subagents) subagent\(subagents == 1 ? "" : "s")") }
        if approvals > 0 { other.append("asked you \(approvals)×") }
        if !other.isEmpty { lines.append(other.joined(separator: " · ").prefix(1).uppercased() + other.joined(separator: " · ").dropFirst()) }
        return lines
    }
}
