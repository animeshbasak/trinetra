import Foundation
import IOKit.pwr_mgt

/// Wraps a single `PreventUserIdleSystemSleep` assertion (same as `caffeinate -i`).
/// The display may still sleep. The assertion dies with the process, so a crash never leaves it held.
final class PowerAssertion {
    struct Failure: LocalizedError {
        let code: IOReturn
        var errorDescription: String? { "IOPMAssertionCreateWithName returned \(code)" }
    }

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var reason = ""
    private(set) var isActive = false

    func set(active: Bool, reason newReason: String) throws {
        if active {
            if isActive && newReason == reason { return }
            if isActive { release() } // reason changed: re-create so `pmset -g assertions` stays accurate
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                newReason as CFString,
                &id)
            guard result == kIOReturnSuccess else { throw Failure(code: result) }
            assertionID = id
            reason = newReason
            isActive = true
        } else if isActive {
            release()
        }
    }

    private func release() {
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }

    deinit { if isActive { IOPMAssertionRelease(assertionID) } }
}
