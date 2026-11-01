import XCTest
@testable import TrinetraCore

final class HookInstallerTests: XCTestCase {
    let bin = "/Users/x/.local/bin/trinetra"

    func entries(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    func testInstallIntoEmpty() {
        let out = ClaudeHookInstaller.install(into: [:], binary: bin)
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(in: out))
        XCTAssertEqual(entries(out, "UserPromptSubmit").count, 1)
        XCTAssertEqual(entries(out, "Notification").count, 2)
        let cmd = (entries(out, "Stop").first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(cmd, "\(bin) hook claude idle")
    }

    func testInstallPreservesExistingHooksAndKeys() {
        let stop: [String: Any] = ["hooks": [["type": "command", "command": "say done"]]]
        let post: [String: Any] = ["matcher": "Edit", "hooks": [["type": "command", "command": "prettier"]]]
        let hooks: [String: Any] = ["Stop": [stop], "PostToolUse": [post]]
        let existing: [String: Any] = ["model": "opus", "hooks": hooks]
        let out = ClaudeHookInstaller.install(into: existing, binary: bin)
        XCTAssertEqual(out["model"] as? String, "opus")
        XCTAssertEqual(entries(out, "Stop").count, 2)
        XCTAssertEqual(entries(out, "PostToolUse").count, 1)
    }

    func testInstallIsIdempotent() {
        let once = ClaudeHookInstaller.install(into: [:], binary: bin)
        let twice = ClaudeHookInstaller.install(into: once, binary: bin)
        XCTAssertEqual(entries(twice, "Notification").count, 2)
        XCTAssertEqual(entries(twice, "Stop").count, 1)
    }

    func testUninstallRestoresOriginal() {
        let stop: [String: Any] = ["hooks": [["type": "command", "command": "say done"]]]
        let hooks: [String: Any] = ["Stop": [stop]]
        let existing: [String: Any] = ["hooks": hooks]
        let out = ClaudeHookInstaller.uninstall(from: ClaudeHookInstaller.install(into: existing, binary: bin))
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(in: out))
        XCTAssertEqual(entries(out, "Stop").count, 1)
        XCTAssertTrue(entries(out, "UserPromptSubmit").isEmpty)
        XCTAssertNil((out["hooks"] as? [String: Any])?["Notification"])
    }

    func testUninstallFromEmptyDropsHooksKey() {
        let out = ClaudeHookInstaller.uninstall(from: ClaudeHookInstaller.install(into: [:], binary: bin))
        XCTAssertNil(out["hooks"])
    }

    func testBinaryWithSpacesIsQuoted() {
        XCTAssertEqual(ClaudeHookInstaller.command(binary: "/Users/x/My Tools/trinetra", state: .working),
                       "'/Users/x/My Tools/trinetra' hook claude working")
    }
}

final class CodexHookInstallerTests: XCTestCase {
    let bin = "/Users/x/.local/bin/trinetra"

    func testCodexInstallUsesCodexEventsAndTimeouts() {
        let out = AgentHookInstaller.install(into: [:], binary: bin, agent: .codex)
        let hooks = out["hooks"] as? [String: Any] ?? [:]
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNil(hooks["Notification"])
        let end = ((hooks["SessionEnd"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(end?["timeout"] as? Int, 3)
        XCTAssertEqual(end?["command"] as? String, "\(bin) hook codex ended")
    }

    func testClaudeAndCodexDoNotRemoveEachOther() {
        let both = AgentHookInstaller.install(
            into: AgentHookInstaller.install(into: [:], binary: bin, agent: .claude), binary: bin, agent: .codex)
        let withoutCodex = AgentHookInstaller.uninstall(from: both, agent: .codex)
        XCTAssertTrue(AgentHookInstaller.isInstalled(in: withoutCodex, agent: .claude))
        XCTAssertFalse(AgentHookInstaller.isInstalled(in: withoutCodex, agent: .codex))
    }
}

final class LegacyHookCleanupTests: XCTestCase {
    func testInstallReplacesHooksFromBeforeTheRename() {
        let old = "/Users/x/.local/bin/" + AgentHookInstaller.legacyName + " hook claude working"
        let group: [String: Any] = ["hooks": [["type": "command", "command": old]]]
        let hooks: [String: Any] = ["UserPromptSubmit": [group]]
        let out = AgentHookInstaller.install(into: ["hooks": hooks], binary: "/Users/x/.local/bin/trinetra", agent: .claude)
        let entries = ((out["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]]) ?? []
        XCTAssertEqual(entries.count, 1)
        let command = (entries.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(command, "/Users/x/.local/bin/trinetra hook claude working")
    }
}
