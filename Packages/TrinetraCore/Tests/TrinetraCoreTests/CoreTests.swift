import XCTest
@testable import TrinetraCore

final class ProcessRulesTests: XCTestCase {
    let rules = ProcessRule.defaults

    func testClaudeRemoteFlagsMatch() {
        for args in [["--remote-control"], ["--rc"], ["remote-control"], ["--model", "opus", "--rc"]] {
            XCTAssertEqual(ProcessRules.match(executablePath: "/opt/homebrew/bin/claude", args: args, rules: rules)?.kind,
                           .remote, "\(args)")
        }
    }

    func testPlainClaudeDoesNotMatch() {
        XCTAssertNil(ProcessRules.match(executablePath: "/usr/local/bin/claude", args: ["-p", "hi"], rules: rules))
    }

    func testOtherExecutableDoesNotMatch() {
        XCTAssertNil(ProcessRules.match(executablePath: "/bin/zsh", args: ["--rc"], rules: rules))
    }

    func testEmptyArgsRuleMatchesAnyArgs() {
        let hold = ProcessRule(name: "trader", executable: "python3", argsContainAny: [], kind: .hold)
        XCTAssertEqual(ProcessRules.match(executablePath: "/usr/bin/python3", args: ["run.py"], rules: [hold]), hold)
    }
}

final class DurationTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(DurationParser.parse("90s"), 90)
        XCTAssertEqual(DurationParser.parse("30m"), 1_800)
        XCTAssertEqual(DurationParser.parse("2h"), 7_200)
        XCTAssertEqual(DurationParser.parse("1h30m"), 5_400)
        XCTAssertEqual(DurationParser.parse("1d"), 86_400)
        XCTAssertEqual(DurationParser.parse("45"), 2_700)
    }

    func testParseRejectsGarbage() {
        for bad in ["", "h", "10x", "1h3", "-5", "0m"] {
            XCTAssertNil(DurationParser.parse(bad), bad)
        }
    }

    func testFormat() {
        XCTAssertEqual(DurationFormat.short(45), "45s")
        XCTAssertEqual(DurationFormat.short(300), "5m")
        XCTAssertEqual(DurationFormat.short(5_400), "1h 30m")
        XCTAssertEqual(DurationFormat.short(7_200), "2h")
        XCTAssertEqual(DurationFormat.short(-3), "0s")
    }
}

final class SessionStoreTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trinetra-tests-\(UUID().uuidString)")
        store = SessionStore(paths: Paths(base: dir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testUpsertCreatesThenTransitions() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try store.upsert(agent: "claude", id: "s1", state: .working, pid: 10, cwd: "/x/foo", now: t)
        XCTAssertEqual(a.lastActiveAt, t)
        let b = try store.upsert(agent: "claude", id: "s1", state: .idle, pid: 10, cwd: nil,
                                 now: t.addingTimeInterval(60))
        XCTAssertEqual(b.state, .idle)
        XCTAssertEqual(b.startedAt, t)
        XCTAssertEqual(b.lastActiveAt, t.addingTimeInterval(60), "leaving working counts as activity")
        XCTAssertEqual(b.cwd, "/x/foo", "nil cwd keeps the previous value")
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testIdleToIdleDoesNotRefreshGrace() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try store.upsert(agent: "claude", id: "s1", state: .idle, pid: 10, cwd: nil, now: t)
        let b = try store.upsert(agent: "claude", id: "s1", state: .idle, pid: 10, cwd: nil, now: t.addingTimeInterval(9))
        XCTAssertNil(b.lastActiveAt)
    }

    func testCorruptFileSkipped() throws {
        try store.paths.ensureDirectories()
        try Data("{not json".utf8).write(to: store.url(for: "broken"))
        try store.upsert(agent: "run", id: "run-1", state: .working, pid: 1, cwd: nil, now: Date())
        XCTAssertEqual(store.loadAll().map(\.id), ["run-1"])
    }

    func testPruneRemovesOldEndedOnly() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(agent: "claude", id: "ended", state: .ended, pid: 1, cwd: nil, now: old)
        try store.upsert(agent: "claude", id: "alive", state: .idle, pid: 2, cwd: nil, now: old)
        let removed = store.prune(now: old.addingTimeInterval(100_000), isAlive: { $0 == 2 })
        XCTAssertEqual(removed, ["claude-ended"])
    }

    func testKeySanitisesIDs() {
        let r = SessionRecord(agent: "claude", id: "a/b c", state: .idle, pid: 1, startedAt: Date(), updatedAt: Date())
        XCTAssertEqual(r.key, "claude-a_b_c")
    }

    func testControlRoundTrip() throws {
        let paths = Paths(base: dir)
        var c = ControlState()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        c.start(for: 600, now: t)
        c.extend(by: 600, now: t)
        try c.save(to: paths)
        XCTAssertEqual(ControlState.load(from: paths).timerEnd, t.addingTimeInterval(1_200))
        c.stop(now: t)
        XCTAssertNil(c.timerEnd)
        XCTAssertEqual(c.stopAt, t)
    }

    func testSettingsPartialFileKeepsDefaults() throws {
        let paths = Paths(base: dir)
        try paths.ensureDirectories()
        try Data(#"{"graceSeconds": 60}"#.utf8).write(to: paths.settings)
        let s = Settings.load(from: paths)
        XCTAssertEqual(s.graceSeconds, 60)
        XCTAssertEqual(s.batteryEndPercent, 10)
        XCTAssertEqual(s.processRules, ProcessRule.defaults)
    }
}
