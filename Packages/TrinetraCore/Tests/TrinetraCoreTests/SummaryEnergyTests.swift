import XCTest
@testable import TrinetraCore

final class SessionSummaryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func ev(_ s: TimeInterval, _ state: AgentState, _ kind: ActivitySummary.Kind, _ detail: String? = nil) -> SessionEvent {
        SessionEvent(t: t0.addingTimeInterval(s), state: state, kind: kind, detail: detail)
    }

    func testCountsAndUniqueFiles() {
        let events = [
            ev(0, .idle, .start),
            ev(10, .working, .prompt),
            ev(20, .working, .edit, "AppModel.swift"),
            ev(30, .working, .progress),
            ev(40, .working, .edit, "AppModel.swift"),
            ev(50, .working, .edit, "README.md"),
            ev(60, .working, .command, "swift"),
            ev(70, .working, .command, "swift"),
            ev(80, .working, .command, "git"),
            ev(90, .waiting, .approval, "npm"),
            ev(100, .working, .read, "LLD.md"),
            ev(110, .idle, .turnEnd),
        ]
        let s = SessionSummary.build(events, now: t0.addingTimeInterval(200))
        XCTAssertEqual(s.prompts, 1)
        XCTAssertEqual(s.turns, 1)
        XCTAssertEqual(s.filesEdited, ["AppModel.swift", "README.md"])
        XCTAssertEqual(s.editCount, 3)
        XCTAssertEqual(s.commandCount, 3)
        XCTAssertEqual(s.topCommands.first?.0, "swift")
        XCTAssertEqual(s.approvals, 1)
        XCTAssertEqual(s.filesRead, 1)
        XCTAssertEqual(s.activeSeconds, 90, accuracy: 0.001) // 10→90 working, then waiting, then 100→110
        XCTAssertEqual(s.headline, "1 prompt · 2 files edited · 3 commands · 1m active")
        XCTAssertEqual(s.detailLines.first, "Edited AppModel.swift, README.md")
        XCTAssertEqual(s.detailLines[1], "Ran swift ×2, git")
    }

    func testLongGapsAreCapped() {
        let s = SessionSummary.build([ev(0, .working, .prompt)], now: t0.addingTimeInterval(10_000))
        XCTAssertEqual(s.activeSeconds, SessionSummary.maxActiveGap)
    }

    func testEmpty() {
        XCTAssertEqual(SessionSummary.build([], now: t0).headline, "No activity yet")
    }

    func testClassifyCountsToolsOnce() {
        let pre = ActivitySummary.classify(state: .working,
                                           payload: ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                                                     "tool_input": ["command": "swift test"]])
        XCTAssertEqual(pre.0, .command)
        XCTAssertEqual(pre.1, "swift")
        let post = ActivitySummary.classify(state: .working,
                                            payload: ["hook_event_name": "PostToolUse", "tool_name": "Bash"])
        XCTAssertEqual(post.0, .progress)
        XCTAssertEqual(ActivitySummary.classify(state: .working, payload: ["hook_event_name": "BeforeAgent"]).0, .prompt)
        XCTAssertEqual(ActivitySummary.classify(state: .idle, payload: ["hook_event_name": "stop"]).0, .turnEnd)
    }

    func testCursorAndGeminiPayloads() {
        let edit = ActivitySummary.classify(state: .working,
                                            payload: ["hook_event_name": "afterFileEdit", "file_path": "/x/y/Main.swift"])
        XCTAssertEqual(edit.0, .edit)
        XCTAssertEqual(edit.1, "Main.swift")
        let shell = ActivitySummary.classify(state: .working,
                                             payload: ["hook_event_name": "BeforeTool", "tool_name": "run_shell_command",
                                                       "tool_input": ["command": "npm run build"]])
        XCTAssertEqual(shell.1, "npm")
        XCTAssertEqual(HookPayload.sessionID(["conversation_id": "c1"]), "c1")
        XCTAssertEqual(HookPayload.cwd(["workspace_roots": ["/Users/x/proj"]]), "/Users/x/proj")
    }

    func testLogRoundTripAndTrim() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trinetra-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var log = SessionLog(paths: Paths(base: dir))
        log.maxBytes = 2_000
        for i in 0..<100 { try log.append(ev(Double(i), .working, .command, "swift"), key: "k") }
        let loaded = log.load(key: "k")
        XCTAssertFalse(loaded.isEmpty)
        XCTAssertLessThan(loaded.count, 100, "trimmed")
        XCTAssertEqual(loaded.last?.t, t0.addingTimeInterval(99))
    }
}

final class EnergyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDrainRateFromMeasuredHolds() {
        let h = HoldRecord(start: t0, end: t0.addingTimeInterval(3_600), batteryStart: 80, batteryEnd: 70,
                           onBatteryStart: true, onBatteryEnd: true)
        XCTAssertEqual(EnergyEstimate.drainPerHour([h]), 10, accuracy: 0.001)
    }

    func testDefaultRateWithoutData() {
        XCTAssertEqual(EnergyEstimate.drainPerHour([]), EnergyEstimate.defaultDrainPerHour)
        let plugged = HoldRecord(start: t0, end: t0.addingTimeInterval(3_600), batteryStart: 80, batteryEnd: 80,
                                 onBatteryStart: false, onBatteryEnd: false)
        XCTAssertNil(plugged.batteryUsed)
    }

    func testSleepCreditOnlyRightAfterHold() {
        var holds = [HoldRecord(start: t0, end: t0.addingTimeInterval(600), onBatteryStart: true, onBatteryEnd: true)]
        EnergyEstimate.creditSleep(&holds, sleptAt: t0.addingTimeInterval(700), wokeAt: t0.addingTimeInterval(700 + 7_200))
        XCTAssertEqual(holds[0].sleptAfterSeconds, 7_200)
        EnergyEstimate.creditSleep(&holds, sleptAt: t0.addingTimeInterval(20_000), wokeAt: t0.addingTimeInterval(30_000))
        XCTAssertEqual(holds[0].sleptAfterSeconds, 7_200, "sleep long after the hold is not credited")
    }

    func testDaySavedUsesRateAndCaps() {
        let holds = [
            HoldRecord(start: t0, end: t0.addingTimeInterval(3_600), batteryStart: 60, batteryEnd: 50,
                       onBatteryStart: true, onBatteryEnd: true, sleptAfterSeconds: 7_200),
        ]
        let day = EnergyEstimate.day(holds, now: t0.addingTimeInterval(4_000), calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(day.holds, 1)
        XCTAssertEqual(day.batteryUsed, 10)
        XCTAssertEqual(day.batterySaved, 20, accuracy: 0.001) // 2 h × 10 %/h
        XCTAssertEqual(day.heldSeconds, 3_600)
    }
}
