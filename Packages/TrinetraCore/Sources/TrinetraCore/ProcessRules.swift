import Foundation

/// A rule that turns a running process into a remote hold (or a plain hold).
public struct ProcessRule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case remote, hold }

    public var name: String
    /// Basename of the executable, e.g. "claude".
    public var executable: String
    /// Any of these must appear as an exact argument. Empty means any arguments match.
    public var argsContainAny: [String]
    public var kind: Kind

    public init(name: String, executable: String, argsContainAny: [String], kind: Kind) {
        self.name = name
        self.executable = executable
        self.argsContainAny = argsContainAny
        self.kind = kind
    }

    /// Only rules whose argv is confirmed ship as defaults. Others are user-added in Settings.
    public static let defaults: [ProcessRule] = [
        ProcessRule(name: "claude-remote", executable: "claude",
                    argsContainAny: ["--remote-control", "--rc", "remote-control"], kind: .remote),
    ]
}

public enum ProcessRules {
    /// `args` excludes argv[0]. Returns the first matching rule.
    public static func match(executablePath: String, args: [String], rules: [ProcessRule]) -> ProcessRule? {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return rules.first { rule in
            guard rule.executable == name else { return false }
            return rule.argsContainAny.isEmpty || args.contains { rule.argsContainAny.contains($0) }
        }
    }
}
