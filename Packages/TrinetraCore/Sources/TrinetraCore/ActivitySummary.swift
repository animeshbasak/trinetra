import Foundation

/// Turns an agent hook payload into short, privacy-safe labels.
/// Never includes prompt text, reply text or full commands: only tool kinds, file names and a command's first word.
public enum ActivitySummary {
    /// What kind of thing an agent did, for counting in session summaries.
    public enum Kind: String, Codable, Sendable {
        case start, prompt, edit, read, command, search, web, subagent, plan, tool, approval, progress, turnEnd, end
    }

    /// One-line label for the menu, e.g. "Editing AppModel.swift" or "Waiting for approval · Running npm".
    public static func describe(state: AgentState, payload: [String: Any]) -> String {
        if let (kind, detail) = classifyTool(payload) {
            let doing = label(kind: kind, detail: detail)
            return state == .waiting ? "Waiting for approval · \(doing)" : doing
        }
        switch state {
        case .working: return "Thinking"
        case .waiting:
            if let message = payload["message"] as? String, !message.isEmpty {
                return truncate(message, to: 70)
            }
            return "Waiting for your approval"
        case .idle: return "Waiting for your next prompt"
        case .ended: return "Session ended"
        }
    }

    /// Classifies a hook event for the session log. Post-tool events are `.progress` so a tool is counted once.
    public static func classify(state: AgentState, payload: [String: Any]) -> (Kind, String?) {
        let event = (payload["hook_event_name"] as? String) ?? ""
        switch event {
        case "SessionStart", "sessionStart": return (.start, nil)
        case "SessionEnd", "sessionEnd": return (.end, nil)
        case "UserPromptSubmit", "BeforeAgent", "beforeSubmitPrompt": return (.prompt, nil)
        case "Stop", "AfterAgent", "stop", "Interrupt": return (.turnEnd, nil)
        case "PostToolUse", "AfterTool", "postToolUse": return (.progress, nil)
        default: break
        }
        if state == .waiting { return (.approval, classifyTool(payload)?.1) }
        if let tool = classifyTool(payload) { return tool }
        switch state {
        case .ended: return (.end, nil)
        case .idle: return (.turnEnd, nil)
        case .working, .waiting: return (.progress, nil)
        }
    }

    // MARK: Tools

    static func classifyTool(_ payload: [String: Any]) -> (Kind, String?)? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        if let tool = payload["tool_name"] as? String, !tool.isEmpty {
            return classify(tool: tool, input: input)
        }
        // Cursor's file / shell events carry the details at the top level.
        if let path = payload["file_path"] as? String { return (.edit, fileName(path)) }
        if let command = payload["command"] as? String { return (.command, firstWord(command)) }
        return nil
    }

    static func classify(tool: String, input: [String: Any]) -> (Kind, String?) {
        let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
            ?? (input["path"] as? String) ?? (input["absolute_path"] as? String)
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "write_file", "replace", "edit_file":
            return (.edit, path.map(fileName))
        case "apply_patch":
            return (.edit, nil)
        case "Read", "read_file", "read_many_files":
            return (.read, path.map(fileName))
        case "Bash", "run_shell_command":
            return (.command, (input["command"] as? String).flatMap(firstWord))
        case "shell", "local_shell", "exec_command", "container.exec":
            let argv = input["command"] as? [String]
            let first = argv?.first(where: { !["bash", "zsh", "sh", "-lc", "-c"].contains($0) })
            return (.command, first.flatMap(firstWord))
        case "Grep", "Glob", "LS", "glob", "search_file_content", "list_directory", "grep":
            return (.search, nil)
        case "WebFetch", "WebSearch", "web_fetch", "google_web_search", "web_search":
            return (.web, nil)
        case "Task", "Agent":
            return (.subagent, nil)
        case "TodoWrite", "update_plan", "write_todos":
            return (.plan, nil)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return (.tool, parts.count >= 2 ? String(parts[1]) : nil)
            }
            return (.tool, tool)
        }
    }

    static func label(kind: Kind, detail: String?) -> String {
        switch kind {
        case .edit: return detail.map { "Editing \($0)" } ?? "Editing files"
        case .read: return detail.map { "Reading \($0)" } ?? "Reading files"
        case .command: return detail.map { "Running \($0)" } ?? "Running a command"
        case .search: return "Searching the code"
        case .web: return "Looking things up on the web"
        case .subagent: return "Running a subagent"
        case .plan: return "Planning next steps"
        case .tool: return detail.map { "Using \($0)" } ?? "Using a tool"
        default: return "Working"
        }
    }

    static func fileName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// First word of a command, path stripped. Commands can contain secrets, so nothing more.
    static func firstWord(_ command: String) -> String? {
        command.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent }
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit - 1)) + "…"
    }
}

/// Agent-neutral fields from a hook payload (Claude Code, Codex, Gemini CLI, Cursor).
public enum HookPayload {
    public static func sessionID(_ payload: [String: Any]) -> String? {
        for key in ["session_id", "conversation_id"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    public static func cwd(_ payload: [String: Any]) -> String? {
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
        return (payload["workspace_roots"] as? [String])?.first
    }
}
