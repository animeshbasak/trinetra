import Foundation

/// Turns an agent hook payload into a short, privacy-safe activity line for the menu,
/// e.g. "Editing AppModel.swift" or "Running swift". Never includes prompt text or full commands.
public enum ActivitySummary {
    public static func describe(state: AgentState, payload: [String: Any]) -> String {
        if let tool = payload["tool_name"] as? String, !tool.isEmpty {
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let doing = describeTool(tool, input: input)
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

    static func describeTool(_ tool: String, input: [String: Any]) -> String {
        func fileName() -> String? {
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String)
            return path.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        switch tool {
        case "apply_patch":
            return "Editing files"
        case "shell", "local_shell", "exec_command", "container.exec":
            let argv = input["command"] as? [String]
            let first = argv?.first(where: { $0 != "bash" && $0 != "-lc" && $0 != "zsh" })?
                .split(separator: " ").first.map(String.init)
            return first.map { "Running \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Running a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return fileName().map { "Editing \($0)" } ?? "Editing files"
        case "Read":
            return fileName().map { "Reading \($0)" } ?? "Reading files"
        case "Bash":
            // First word only: commands can contain secrets.
            let first = (input["command"] as? String)?
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
            return first.map { "Running \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Running a command"
        case "Grep", "Glob", "LS":
            return "Searching the code"
        case "WebFetch", "WebSearch":
            return "Looking things up on the web"
        case "Task", "Agent":
            return "Running a subagent"
        case "TodoWrite":
            return "Planning next steps"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return parts.count >= 2 ? "Using \(parts[1])" : "Using a tool"
            }
            return "Using \(tool)"
        }
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit - 1)) + "…"
    }
}
