import Foundation

/// Locations of Trinetra's on-disk state. `TRINETRA_HOME` overrides the base dir (tests, dev).
public struct Paths: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let override = environment["TRINETRA_HOME"], !override.isEmpty {
            return Paths(base: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(base: home.appendingPathComponent("Library/Application Support/Trinetra", isDirectory: true))
    }

    public var sessions: URL { base.appendingPathComponent("sessions", isDirectory: true) }
    public var control: URL { base.appendingPathComponent("control.json") }
    public var settings: URL { base.appendingPathComponent("settings.json") }
    public var journal: URL { base.appendingPathComponent("journal.json") }
    public var holds: URL { base.appendingPathComponent("holds.json") }

    /// Append-only activity log for one session, next to its session file.
    public func events(for key: String) -> URL { sessions.appendingPathComponent("\(key).events.jsonl") }

    /// Creates the base and sessions directories with owner-only permissions.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [base, sessions] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Single-line encoder for JSON Lines logs.
    static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Atomic write with 0600 permissions.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }
}
