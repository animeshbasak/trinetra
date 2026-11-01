import XCTest
@testable import TrinetraCore

final class ReconcilerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ state: AgentState, pid: Int32 = 100, updatedAgo: TimeInterval = 0,
                 lastActiveAgo: TimeInterval? = 0, id: String = "a") -> SessionRecord {
        SessionRecord(agent: "claude", id: id, state: state, pid: pid, cwd: "/Users/x/foo",
                      startedAt: t0.addingTimeInterval(-3_600),
                      updatedAt: t0.addingTimeInterval(-updatedAgo),
                      lastActiveAt: lastActiveAgo.map { t0.addingTimeInterval(-$0) })
    }

    func decide(sessions: [SessionRecord] = [], remote: [Int32] = [],
                control: ControlState = ControlState(), power: PowerState = .unknownAC,
                settings: Settings = Settings(), holdStartedAt: Date? = nil,
                dead: Set<Int32> = []) -> Decision {
        Reconciler.decide(ReconcileInput(now: t0, sessions: sessions, remotePIDs: remote,
                                         control: control, power: power, settings: settings,
                                         holdStartedAt: holdStartedAt,
                                         isAlive: { !dead.contains($0) }))
    }

    // MARK: Rule 1 — active sessions

    func testNothingRunningSleeps() {
        let d = decide()
        XCTAssertFalse(d.awake)
        XCTAssertNil(d.trip)
        XCTAssertTrue(d.reasons.isEmpty)
    }

    func testWorkingSessionKeepsAwake() {
        let d = decide(sessions: [session(.working)])
        XCTAssertTrue(d.awake)
        XCTAssertEqual(d.activeSessions.count, 1)
        XCTAssertEqual(d.reasons.first, "1 agent working")
    }

    func testWaitingSessionKeepsAwakeUntilTimeout() {
        XCTAssertTrue(decide(sessions: [session(.waiting, updatedAgo: 1_000, lastActiveAgo: 1_000)]).awake)
        XCTAssertFalse(decide(sessions: [session(.waiting, updatedAgo: 2_000, lastActiveAgo: 2_000)]).awake)
    }

    func testStaleWorkingSessionIgnored() {
        XCTAssertFalse(decide(sessions: [session(.working, updatedAgo: 20_000, lastActiveAgo: 20_000)]).awake)
    }

    func testDeadPidIgnoredButGraceStillApplies() {
        // Process died 60 s after its last activity: grace (180 s) still holds.
        let d = decide(sessions: [session(.working, pid: 7, updatedAgo: 60, lastActiveAgo: 60)], dead: [7])
        XCTAssertTrue(d.awake)
        XCTAssertTrue(d.activeSessions.isEmpty)
        XCTAssertTrue(d.reasons.first?.hasPrefix("grace") ?? false)
    }

    // MARK: Rule 2 — grace

    func testIdleWithinGraceKeepsAwake() {
        XCTAssertTrue(decide(sessions: [session(.idle, updatedAgo: 100, lastActiveAgo: 100)]).awake)
    }

    func testIdleAfterGraceSleeps() {
        XCTAssertFalse(decide(sessions: [session(.idle, updatedAgo: 200, lastActiveAgo: 200)]).awake)
    }

    func testIdleNeverActiveSleeps() {
        XCTAssertFalse(decide(sessions: [session(.idle, lastActiveAgo: nil)]).awake)
    }

    // MARK: Rule 3 — remote holds

    func testRemoteHoldKeepsAwakeWithIdleSession() {
        let d = decide(sessions: [session(.idle, updatedAgo: 3_000, lastActiveAgo: 3_000)], remote: [42])
        XCTAssertTrue(d.awake)
        XCTAssertEqual(d.reasons.first, "1 remote session")
    }

    func testDeadRemoteIgnored() {
        XCTAssertFalse(decide(remote: [42], dead: [42]).awake)
    }

    func testIgnoredRemotePidIgnored() {
        XCTAssertFalse(decide(remote: [42], control: ControlState(ignoredPIDs: [42])).awake)
    }

    // MARK: Rule 4 — timer

    func testTimerKeepsAwake() {
        let d = decide(control: ControlState(timerEnd: t0.addingTimeInterval(1_800)))
        XCTAssertTrue(d.awake)
        XCTAssertEqual(d.reasons.first, "timer: 30m left")
    }

    func testExpiredTimerSleeps() {
        XCTAssertFalse(decide(control: ControlState(timerEnd: t0.addingTimeInterval(-1))).awake)
    }

    // MARK: Stop

    func testStopIgnoresEarlierActivity() {
        let control = ControlState(stopAt: t0.addingTimeInterval(-5))
        XCTAssertFalse(decide(sessions: [session(.working, updatedAgo: 10, lastActiveAgo: 10)], control: control).awake)
    }

    func testActivityAfterStopResumes() {
        let control = ControlState(stopAt: t0.addingTimeInterval(-60))
        XCTAssertTrue(decide(sessions: [session(.working, updatedAgo: 5, lastActiveAgo: 5)], control: control).awake)
    }

    // MARK: Rule 6 — safety trips

    func testThermalCriticalTrips() {
        let d = decide(sessions: [session(.working)],
                       power: PowerState(onAC: true, batteryPercent: 90, thermal: .critical))
        XCTAssertFalse(d.awake)
        XCTAssertEqual(d.trip, .thermalCritical)
    }

    func testBatteryFloorTripsOnBatteryOnly() {
        let low = PowerState(onAC: false, batteryPercent: 10)
        XCTAssertEqual(decide(sessions: [session(.working)], power: low).trip, .batteryFloor)
        XCTAssertFalse(decide(sessions: [session(.working)], power: low).awake)
        let charging = PowerState(onAC: true, batteryPercent: 5)
        XCTAssertTrue(decide(sessions: [session(.working)], power: charging).awake)
    }

    func testMaxHoldTrips() {
        let d = decide(sessions: [session(.working)], holdStartedAt: t0.addingTimeInterval(-43_200))
        XCTAssertEqual(d.trip, .maxHold)
        XCTAssertFalse(d.awake)
    }

    func testNoTripReportedWhenNothingWantsAwake() {
        let d = decide(power: PowerState(onAC: false, batteryPercent: 3))
        XCTAssertNil(d.trip)
    }

    // MARK: Rule 7 — lid mode and low power

    func testLidModeOnAC() {
        XCTAssertTrue(decide(sessions: [session(.working)]).lidMode)
    }

    func testLidModeOnBatteryRespectsSetting() {
        var s = Settings()
        let battery = PowerState(onAC: false, batteryPercent: 80)
        XCTAssertTrue(decide(sessions: [session(.working)], power: battery, settings: s).lidMode)
        s.allowBatteryLid = false
        XCTAssertFalse(decide(sessions: [session(.working)], power: battery, settings: s).lidMode)
        XCTAssertTrue(decide(sessions: [session(.working)], power: battery, settings: s).awake)
    }

    func testLidModeOffWhenDisabled() {
        var s = Settings()
        s.lidClosedMode = false
        XCTAssertFalse(decide(sessions: [session(.working)], settings: s).lidMode)
    }

    func testLowPowerOnLowBattery() {
        XCTAssertTrue(decide(sessions: [session(.working)], power: PowerState(onAC: false, batteryPercent: 35)).lowPower)
        XCTAssertFalse(decide(sessions: [session(.working)], power: PowerState(onAC: false, batteryPercent: 60)).lowPower)
    }

    func testLowPowerOnSeriousThermal() {
        XCTAssertTrue(decide(sessions: [session(.working)],
                             power: PowerState(onAC: true, batteryPercent: nil, thermal: .serious)).lowPower)
    }

    func testNotAwakeMeansNoLidOrLowPower() {
        let d = decide(power: PowerState(onAC: false, batteryPercent: 20))
        XCTAssertFalse(d.lidMode)
        XCTAssertFalse(d.lowPower)
    }

    func testMultipleAgentsReason() {
        let d = decide(sessions: [session(.working, pid: 1, id: "a"), session(.waiting, pid: 2, id: "b")])
        XCTAssertEqual(d.reasons.first, "2 agents working")
    }
}
