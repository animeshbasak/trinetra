import XCTest
@testable import TrinetraCore

final class HelperSafetyTests: XCTestCase {
    func testOnBatteryAtFloorRestoresSleep() {
        XCTAssertTrue(HelperSafety.mustRestoreSleep(onAC: false, batteryPercent: 10, thermalCritical: false))
        XCTAssertTrue(HelperSafety.mustRestoreSleep(onAC: false, batteryPercent: 1, thermalCritical: false))
    }

    func testOnBatteryAboveFloorKeepsLidMode() {
        XCTAssertFalse(HelperSafety.mustRestoreSleep(onAC: false, batteryPercent: 11, thermalCritical: false))
    }

    func testOnACNeverTripsBatteryFloor() {
        XCTAssertFalse(HelperSafety.mustRestoreSleep(onAC: true, batteryPercent: 3, thermalCritical: false))
    }

    func testUnknownBatteryDoesNotTrip() {
        XCTAssertFalse(HelperSafety.mustRestoreSleep(onAC: false, batteryPercent: nil, thermalCritical: false))
    }

    func testThermalCriticalAlwaysRestores() {
        XCTAssertTrue(HelperSafety.mustRestoreSleep(onAC: true, batteryPercent: 90, thermalCritical: true))
    }

    func testRefusalMessageNamesTheFloor() {
        XCTAssertTrue(HelperSafety.refusalMessage(batteryPercent: 8).contains("8 %"))
        XCTAssertTrue(HelperSafety.refusalMessage(batteryPercent: 8).contains("10 %"))
    }
}

final class LidPlannerTests: XCTestCase {
    private func plan(wanted: Bool = false, holds: Bool = false, system: Bool = false,
                      on: Bool = true, inFlight: Bool = false, ready: Bool = true) -> LidAction {
        LidPlanner.action(wanted: wanted, appHolds: holds, systemSleepDisabled: system,
                          lidModeOn: on, requestInFlight: inFlight, helperReady: ready)
    }

    func testDisablesWhenWantedAndNotHeld() {
        XCTAssertEqual(plan(wanted: true), .disable)
    }

    func testNothingWhenWantedAndAlreadyHeld() {
        XCTAssertEqual(plan(wanted: true, holds: true, system: true), .none)
    }

    func testRestoresWhenNoLongerWanted() {
        XCTAssertEqual(plan(wanted: false, holds: true, system: true), .restore)
    }

    /// The bug from 4 Nov: the app lost track of the hold, but SleepDisabled was still 1.
    func testRestoresWhenOutOfSyncAndSleepStillDisabled() {
        XCTAssertEqual(plan(wanted: false, holds: false, system: true), .restore)
    }

    func testLeavesSomeoneElsesFlagAloneWhenLidModeOff() {
        XCTAssertEqual(plan(wanted: false, holds: false, system: true, on: false), .none)
    }

    func testWaitsForInFlightRequest() {
        XCTAssertEqual(plan(wanted: false, holds: true, system: true, inFlight: true), .none)
    }

    func testNeedsHelperToDisable() {
        XCTAssertEqual(plan(wanted: true, ready: false), .none)
    }
}
