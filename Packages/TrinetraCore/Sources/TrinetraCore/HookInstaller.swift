import Foundation

/// Agents Trinetra can install hooks for.
/// Claude Code, Codex and Gemini CLI share the nested shape
/// `{"hooks": {"<Event>": [{"matcher": "…", "hooks": [{"type": "command", "command": "…", "timeout": N}]}]}}`.
/// Cursor uses a flat shape: `{"version": 1, "hooks": {"<event>": [{"command": "…", "timeout": N}]}}`.
public enum HookAgent: String, CaseIterable, Sendable {
    case claude, codex, gemini, cursor

    enum Format { case nested, flat }

    var format: Format { self == .cursor ? .flat : .nested }

    /// Path relative to the home folder.
    public var configPath: String {
        switch self {
        case .claude: return ".claude/settings.json"
        case .codex: return ".codex/hooks.json"
        case .gemini: return ".gemini/settings.json"
        case .cursor: return ".cursor/hooks.json"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex / ChatGPT"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        }
    }

    struct Spec {
        let event: String
        let matcher: String?
        let state: AgentState
        var timeout: Int = 5
    }

    var specs: [Spec] {
        switch self {
        case .claude:
            return [
                Spec(event: "SessionStart", matcher: nil, state: .idle),
                Spec(event: "UserPromptSubmit", matcher: nil, state: .working),
                Spec(event: "PreToolUse", matcher: "*", state: .working),
                Spec(event: "Notification", matcher: "permission_prompt", state: .waiting),
                Spec(event: "Notification", matcher: "idle_prompt", state: .idle),
                Spec(event: "Stop", matcher: nil, state: .idle),
                Spec(event: "SessionEnd", matcher: nil, state: .ended),
            ]
        case .codex:
            // SessionEnd and Interrupt allow at most 3 s in Codex.
            return [
                Spec(event: "SessionStart", matcher: nil, state: .idle),
                Spec(event: "UserPromptSubmit", matcher: nil, state: .working),
                Spec(event: "PreToolUse", matcher: "*", state: .working),
                Spec(event: "PermissionRequest", matcher: "*", state: .waiting),
                Spec(event: "PostToolUse", matcher: "*", state: .working),
                Spec(event: "Stop", matcher: nil, state: .idle),
                Spec(event: "Interrupt", matcher: nil, state: .idle, timeout: 3),
                Spec(event: "SessionEnd", matcher: nil, state: .ended, timeout: 3),
            ]
        case .gemini:
            // Gemini CLI timeouts are in milliseconds.
            return [
                Spec(event: "SessionStart", matcher: nil, state: .idle, timeout: 5_000),
                Spec(event: "BeforeAgent", matcher: nil, state: .working, timeout: 5_000),
                Spec(event: "BeforeTool", matcher: ".*", state: .working, timeout: 5_000),
                Spec(event: "AfterTool", matcher: ".*", state: .working, timeout: 5_000),
                Spec(event: "Notification", matcher: nil, state: .waiting, timeout: 5_000),
                Spec(event: "AfterAgent", matcher: nil, state: .idle, timeout: 5_000),
                Spec(event: "SessionEnd", matcher: nil, state: .ended, timeout: 5_000),
            ]
        case .cursor:
            // Only observational events: Cursor's permission hooks (preToolUse, beforeShellExecution…)
            // must answer with JSON, so Trinetra stays out of them.
            return [
                Spec(event: "sessionStart", matcher: nil, state: .idle),
                Spec(event: "beforeSubmitPrompt", matcher: nil, state: .working),
                Spec(event: "afterFileEdit", matcher: nil, state: .working),
                Spec(event: "afterShellExecution", matcher: nil, state: .working),
                Spec(event: "postToolUse", matcher: nil, state: .working),
                Spec(event: "stop", matcher: nil, state: .idle),
                Spec(event: "sessionEnd", matcher: nil, state: .ended),
            ]
        }
    }
}

/// Merges Trinetra's hooks into an agent's hook config and removes them again.
/// Pure: works on `[String: Any]`; file I/O lives in the CLI. Other hooks are never touched.
public enum AgentHookInstaller {
    public static func command(binary: String, agent: HookAgent, state: AgentState) -> String {
        let quoted = binary.contains(" ") ? "'\(binary)'" : binary
        return "\(quoted) hook \(agent.rawValue) \(state.rawValue)"
    }

    /// Idempotent: existing Trinetra entries for this agent are replaced.
    public static func install(into settings: [String: Any], binary: String, agent: HookAgent) -> [String: Any] {
        var result = uninstall(from: settings, agent: agent)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for spec in agent.specs {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            let cmd = command(binary: binary, agent: agent, state: spec.state)
            switch agent.format {
            case .nested:
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": cmd, "timeout": spec.timeout] as [String: Any]],
                ]
                if let matcher = spec.matcher { group["matcher"] = matcher }
                groups.append(group)
            case .flat:
                groups.append(["command": cmd, "timeout": spec.timeout])
            }
            hooks[spec.event] = groups
        }
        result["hooks"] = hooks
        if agent.format == .flat, result["version"] == nil { result["version"] = 1 }
        return result
    }

    /// Removes this agent's Trinetra hooks; groups and events left empty are dropped.
    public static func uninstall(from settings: [String: Any], agent: HookAgent) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    // Flat format (Cursor): the group is the hook entry itself.
                    if !isTrinetra(group, agent: agent) { kept.append(group) }
                    continue
                }
                let filtered = entries.filter { !isTrinetra($0, agent: agent) }
                if filtered.isEmpty && !entries.isEmpty { continue }
                group["hooks"] = filtered
                kept.append(group)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    public static func isInstalled(in settings: [String: Any], agent: HookAgent) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { group in
                if let entries = group["hooks"] as? [[String: Any]] {
                    return entries.contains { isTrinetra($0, agent: agent) }
                }
                return isTrinetra(group, agent: agent)
            } ?? false
        }
    }

    static func isTrinetra(_ entry: [String: Any], agent: HookAgent) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        let hookArgs = " hook \(agent.rawValue) "
        guard command.contains(hookArgs) else { return false }
        // Also match entries from before the rename (the app was called "Vig" + "il"),
        // so installing Trinetra's hooks cleans up the old ones instead of doubling them.
        return command.contains("trinetra") || command.contains("/" + legacyName + hookArgs)
    }

    static let legacyName = "vig" + "il"
}

/// Claude Code convenience wrapper (kept for existing callers and tests).
public enum ClaudeHookInstaller {
    public static let marker = "trinetra hook "

    public static func command(binary: String, state: AgentState) -> String {
        AgentHookInstaller.command(binary: binary, agent: .claude, state: state)
    }

    public static func install(into settings: [String: Any], binary: String) -> [String: Any] {
        AgentHookInstaller.install(into: settings, binary: binary, agent: .claude)
    }

    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        AgentHookInstaller.uninstall(from: settings, agent: .claude)
    }

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        AgentHookInstaller.isInstalled(in: settings, agent: .claude)
    }
}
