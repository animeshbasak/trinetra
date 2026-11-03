import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Process helpers. Darwin-specific parts compile to safe fallbacks elsewhere.
enum Proc {
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    #if os(macOS)
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
    #endif

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    /// Finds the agent process that ran this hook. Claude Code runs hooks through a shell,
    /// and its native binary may be named after its version (…/claude/versions/2.1.x),
    /// so match on the executable name *or* a `/claude/` path segment.
    static func agentPID(agent: String) -> Int32 {
        let ppid = getppid()
        #if os(macOS)
        var pid = ppid
        for _ in 0..<4 {
            if let p = path(of: pid) {
                let name = URL(fileURLWithPath: p).lastPathComponent.lowercased()
                let lower = p.lowercased()
                // claude/codex binaries, node-based CLIs (Gemini), and app bundles like Cursor.app.
                if name == agent || name == "node" || lower.contains("/\(agent)/") || lower.contains("/\(agent).app/") {
                    return pid
                }
            }
            guard let up = parent(of: pid), up > 1 else { break }
            pid = up
        }
        // No match: skip a short-lived wrapper shell so liveness tracks something durable.
        if let p = path(of: ppid), shells.contains(URL(fileURLWithPath: p).lastPathComponent),
           let up = parent(of: ppid), up > 1 {
            return up
        }
        #endif
        return ppid
    }
}
