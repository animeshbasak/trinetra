import Foundation
import TrinetraCore

// TrinetraHelper — root LaunchDaemon (Sprint 2). See architecture/LLD.md §9.
// The entire privileged surface: run /usr/bin/pmset with one of four fixed argument lists.
// No shell, no paths, no strings from the caller. Reverts on launch, when the app disconnects,
// and on a missed heartbeat (dead-man switch).

enum PMSet {
    static func run(_ args: [String]) -> (Bool, String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        guard p.terminationStatus == 0 else {
            let err = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (false, err.isEmpty ? "pmset exited \(p.terminationStatus)" : err)
        }
        return (true, nil)
    }

    static func disableSleep(_ on: Bool) -> (Bool, String?) { run(["-a", "disablesleep", on ? "1" : "0"]) }
    static func lowPower(_ on: Bool) -> (Bool, String?) { run(["-b", "lowpowermode", on ? "1" : "0"]) }
}

final class HelperState {
    private let queue = DispatchQueue(label: "com.insanemesh.trinetra.helper.state")
    private var lidSleepDisabled = false
    private var lowPower = false
    private var lastHeartbeat = Date()

    func setLid(_ disabled: Bool) -> (Bool, String?) {
        queue.sync {
            let result = PMSet.disableSleep(disabled)
            if result.0 { lidSleepDisabled = disabled; lastHeartbeat = Date() }
            return result
        }
    }

    func setLowPower(_ enabled: Bool) -> (Bool, String?) {
        queue.sync {
            let result = PMSet.lowPower(enabled)
            if result.0 { lowPower = enabled }
            return result
        }
    }

    func beat() { queue.sync { lastHeartbeat = Date() } }

    func snapshot() -> (Bool, Bool) { queue.sync { (lidSleepDisabled, lowPower) } }

    /// Dead-man switch: the app stopped talking to us while lid sleep is off → put everything back.
    func checkDeadMan() {
        queue.sync {
            guard lidSleepDisabled || lowPower,
                  Date().timeIntervalSince(lastHeartbeat) > HelperConstants.deadManTimeout else { return }
            NSLog("TrinetraHelper: no heartbeat for %.0fs — reverting", Date().timeIntervalSince(lastHeartbeat))
            if PMSet.disableSleep(false).0 { lidSleepDisabled = false }
            if PMSet.lowPower(false).0 { lowPower = false }
        }
    }

    /// The app went away (quit, crash, rebuild): put normal sleep back immediately.
    func revertAll(reason: String) {
        queue.sync {
            guard lidSleepDisabled || lowPower else { return }
            NSLog("TrinetraHelper: %@ — reverting", reason)
            if PMSet.disableSleep(false).0 { lidSleepDisabled = false }
            if PMSet.lowPower(false).0 { lowPower = false }
        }
    }

    func resetOnLaunch() {
        queue.sync {
            _ = PMSet.disableSleep(false)
            _ = PMSet.lowPower(false)
            lidSleepDisabled = false
            lowPower = false
        }
    }
}

final class HelperService: NSObject, TrinetraHelperProtocol {
    let store: HelperState
    init(store: HelperState) { self.store = store }

    func setLidSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        let (ok, err) = store.setLid(disabled)
        reply(ok, err)
    }

    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        let (ok, err) = store.setLowPower(enabled)
        reply(ok, err)
    }

    func heartbeat(reply: @escaping () -> Void) {
        store.beat()
        reply()
    }

    func state(reply: @escaping (Bool, Bool) -> Void) {
        let (lid, low) = store.snapshot()
        reply(lid, low)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let store: HelperState
    /// Filled from Sprint 0: the app's designated requirement. Local builds can pin the team id;
    /// v1.0 Developer ID builds use `anchor apple generic and identifier … and certificate leaf[subject.OU] = …`.
    let requirement: String

    init(store: HelperState, requirement: String) {
        self.store = store
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement) // rejects any caller that isn't Trinetra.app
        connection.exportedInterface = NSXPCInterface(with: TrinetraHelperProtocol.self)
        connection.exportedObject = HelperService(store: store)
        let store = self.store
        connection.invalidationHandler = { store.revertAll(reason: "app disconnected") }
        connection.interruptionHandler = { store.revertAll(reason: "app connection interrupted") }
        connection.resume()
        return true
    }
}

// Only Trinetra.app signed by this team may connect. Personal Team id from Sprint 0 (HLD §12).
// A v1.0 Developer ID build keeps the same shape with the paid team id.
let requirement = #"anchor apple generic and identifier "com.insanemesh.trinetra" and certificate leaf[subject.OU] = "KNBZ4G3K97""#

let helperState = HelperState()
helperState.resetOnLaunch()

let deadMan = DispatchSource.makeTimerSource(queue: .global())
deadMan.schedule(deadline: .now() + 10, repeating: 10)
deadMan.setEventHandler { helperState.checkDeadMan() }
deadMan.resume()

let delegate = ListenerDelegate(store: helperState, requirement: requirement)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
