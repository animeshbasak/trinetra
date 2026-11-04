import Combine
import Foundation
import SwiftUI
import TrinetraCore

/// Poll → reconcile → apply.
/// Holds the idle-sleep assertion, drives lid-closed mode through the privileged helper,
/// and publishes everything the menu shows.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var decision = Decision.idle
    @Published private(set) var power = PowerState.unknownAC
    @Published private(set) var timerEnd: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var claudeHooksInstalled = false
    /// Every open agent session (alive, not ended), active first.
    @Published private(set) var liveSessions: [SessionRecord] = []
    /// System `SleepDisabled` flag: true means a closed lid won't sleep the Mac.
    @Published private(set) var sleepDisabled = false
    @Published private(set) var helperStatus: LidGuard.HelperStatus = .notRegistered
    /// Exact reason the last helper registration failed, shown in the menu.
    @Published private(set) var helperError: String?
    /// Summaries keyed by session key, for open and recent sessions.
    @Published private(set) var summaries: [String: SessionSummary] = [:]
    /// Sessions that ended (or whose process is gone) in the last 24 h, newest first.
    @Published private(set) var recentSessions: [SessionRecord] = []
    @Published private(set) var today = EnergyEstimate.Day()
    @Published private(set) var lidNote: String?
    @Published private(set) var batteryFloor = TrinetraCore.Settings().batteryEndPercent
    @Published private(set) var graceMinutes = Int(TrinetraCore.Settings().graceSeconds / 60)
    /// Current frame of the animated menu bar eye (mirrors `eye.frameName`).
    @Published private(set) var eyeFrame = "MenuBarEye4"
    /// Toolkit modules the user turned on, and the menu bar readout (settings.json).
    @Published private(set) var modules = ModuleSet()
    @Published private(set) var menuBarReadout: MenuBarReadout = .none
    /// Text beside the eye, from the system monitor; nil shows the eye alone.
    @Published private(set) var readoutText: String?

    /// User preference: keep the Mac awake with the lid closed while holding.
    @Published var lidModeOn: Bool = UserDefaults.standard.bool(forKey: "lidModeOn") {
        didSet {
            UserDefaults.standard.set(lidModeOn, forKey: "lidModeOn")
            lidNote = nil
            if lidModeOn {
                prepareHelper(openSettingsIfNeeded: true)
            } else if lidHeld {
                setLid(false)
            }
            tick()
        }
    }

    let eye = EyeAnimator()
    let monitor = SystemMonitor()
    var lidProtected: Bool { sleepDisabled }

    let paths = Paths.default()
    private lazy var store = SessionStore(paths: paths)
    private let lidGuard = LidGuard()
    private let assertion = PowerAssertion()
    private var holdStartedAt: Date?
    /// True while Trinetra has asked the helper to keep lid sleep off.
    private var lidHeld = false
    private var lidRequestInFlight = false
    private var sleepCheckInFlight = false
    private var timer: Timer?
    private var tickCount = 0
    private var holds: [HoldRecord] = []
    private var sleptAt: Date?
    private var observers: [NSObjectProtocol] = []

    init() {
        try? paths.ensureDirectories()
        eye.$frameName.assign(to: &$eyeFrame)
        monitor.onReadoutChange = { [weak self] text in self?.readoutText = text }
        lidGuard.onDisconnect = { [weak self] in
            // The helper reverts on disconnect; the next tick re-asks if lid mode is still wanted.
            self?.lidHeld = false
        }
        if lidModeOn { prepareHelper(openSettingsIfNeeded: false) }
        holds = EnergyEstimate.load(from: paths)
        // A hold left open by a crash or quit is closed at the time of the last known save.
        if let i = holds.indices.last, holds[i].end == nil { holds[i].end = Date() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleptAt = Date() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recordWake() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    // MARK: Derived UI state

    var iconName: String {
        if decision.trip != nil || lastError != nil { return "MenuBarAlert" }
        guard decision.awake else { return "MenuBarIdle" }
        return sleepDisabled ? "MenuBarLid" : "MenuBarAwake"
    }

    /// Menu bar label: the animated eye, or the static alert icon on a safety stop or error.
    var menuBarIcon: String {
        if decision.trip != nil || lastError != nil { return "MenuBarAlert" }
        return eyeFrame
    }

    var headline: String {
        if let trip = decision.trip { return "Stopped: \(trip.message)" }
        guard decision.awake else { return "Idle — Mac can sleep" }
        return sleepDisabled ? "Holding awake · lid can close" : "Holding awake · keep the lid open"
    }

    // MARK: Loop

    func tick() {
        tickCount += 1
        let now = Date()
        var control = ControlState.load(from: paths)
        let settings = TrinetraCore.Settings.load(from: paths)
        batteryFloor = settings.batteryEndPercent
        graceMinutes = max(1, Int(settings.graceSeconds / 60))
        power = PowerMonitor.snapshot()
        let sessions = store.loadAll()

        let input = ReconcileInput(now: now, sessions: sessions, remotePIDs: [],
                                   control: control, power: power, settings: settings,
                                   holdStartedAt: holdStartedAt, isAlive: AppModel.isAlive)
        let next = Reconciler.decide(input)

        // A trip ends the hold for good: record a stop so it doesn't resume when the trip clears.
        if let trip = next.trip, decision.trip != trip {
            control.stop(now: now)
            try? control.save(to: paths)
        }

        if next.awake && holdStartedAt == nil {
            holdStartedAt = now
            holds.append(HoldRecord(start: now, batteryStart: power.batteryPercent, onBatteryStart: !power.onAC))
            saveHolds()
        }
        if !next.awake && holdStartedAt != nil {
            holdStartedAt = nil
            if let i = holds.indices.last, holds[i].end == nil {
                holds[i].end = now
                holds[i].batteryEnd = power.batteryPercent
                holds[i].onBatteryEnd = !power.onAC
                saveHolds()
            }
        }

        do {
            try assertion.set(active: next.awake, reason: "Trinetra: \(next.reasons.first ?? "agents working")")
            lastError = nil
        } catch {
            lastError = "Couldn't hold the Mac awake (\(error.localizedDescription))"
        }

        decision = next
        eye.setAwake(next.awake)
        modules = settings.modules
        menuBarReadout = settings.menuBarReadout
        timerEnd = control.timerEnd.flatMap { $0 > now ? $0 : nil }
        liveSessions = sessions
            .filter { $0.state != .ended && AppModel.isAlive($0.pid) }
            .sorted { lhs, rhs in
                if lhs.state.sortRank != rhs.state.sortRank { return lhs.state.sortRank < rhs.state.sortRank }
                return lhs.updatedAt > rhs.updatedAt
            }

        applyLidMode(wanted: lidModeOn && next.awake && next.lidMode)
        monitor.configure(settings: settings, sessions: liveSessions, thermal: power.thermal)

        if tickCount % 5 == 1 { refreshSummaries(sessions: sessions, now: now) }

        if tickCount % 20 == 1 { // about once a minute
            claudeHooksInstalled = AppModel.checkClaudeHooks()
            store.prune(now: now, isAlive: AppModel.isAlive)
        }
    }

    // MARK: Lid mode (helper)

    private func prepareHelper(openSettingsIfNeeded: Bool) {
        var status = lidGuard.status
        helperError = nil
        if status == .notRegistered || isUnavailable(status) {
            let (registered, error) = lidGuard.register()
            status = registered
            helperError = error
        }
        helperStatus = status
        switch status {
        case .ready:
            lidNote = nil
        case .needsApproval:
            lidNote = "Turn on “Trinetra” (it may be listed as “Animesh Basak”) under System Settings › General › Login Items & Extensions › Allow in the Background. One time only."
            if openSettingsIfNeeded { lidGuard.openLoginItems() }
        case .notRegistered:
            lidNote = "macOS didn't register the helper." + (lidGuard.runsFromBuildFolder
                ? " Trinetra is running from Xcode's build folder; copy it to /Applications and open it from there, then retry." : "")
        case .unavailable(let message):
            lidNote = message
        }
    }

    private func isUnavailable(_ status: LidGuard.HelperStatus) -> Bool {
        if case .unavailable = status { return true }
        return false
    }

    /// Menu button: try registering the helper again.
    func retryHelper() {
        prepareHelper(openSettingsIfNeeded: true)
        tick()
    }

    // MARK: Summaries and energy

    private func refreshSummaries(sessions: [SessionRecord], now: Date) {
        let log = SessionLog(paths: paths)
        var next: [String: SessionSummary] = [:]
        let liveKeys = Set(liveSessions.map(\.key))
        let recent = sessions
            .filter { !liveKeys.contains($0.key) && now.timeIntervalSince($0.updatedAt) < 86_400 }
            .sorted { $0.updatedAt > $1.updatedAt }
        for s in liveSessions + recent {
            next[s.key] = SessionSummary.build(log.load(key: s.key), now: now)
        }
        summaries = next
        recentSessions = Array(recent.filter { (next[$0.key]?.prompts ?? 0) > 0 || (next[$0.key]?.editCount ?? 0) > 0 }.prefix(5))
        today = EnergyEstimate.day(holds, now: now)
    }

    private func recordWake() {
        guard let start = sleptAt else { return }
        sleptAt = nil
        EnergyEstimate.creditSleep(&holds, sleptAt: start, wokeAt: Date())
        saveHolds()
        today = EnergyEstimate.day(holds, now: Date())
    }

    private func saveHolds() {
        try? EnergyEstimate.save(holds, to: paths)
    }

    func openLoginItems() { lidGuard.openLoginItems() }

    private func applyLidMode(wanted: Bool) {
        refreshSleepDisabled()
        if lidModeOn, tickCount % 5 == 0 || helperStatus != .ready {
            let status = lidGuard.status
            if status != helperStatus {
                helperStatus = status
                if status == .ready { lidNote = nil }
            }
        }
        if wanted, !lidHeld, !lidRequestInFlight, helperStatus == .ready {
            setLid(true)
        } else if !wanted, lidHeld, !lidRequestInFlight {
            setLid(false)
        }
        if lidHeld, tickCount % 10 == 0 { lidGuard.heartbeat() } // every ~30 s; dead-man is 120 s
    }

    private func setLid(_ disabled: Bool) {
        lidRequestInFlight = true
        lidGuard.setLidSleepDisabled(disabled) { [weak self] ok, message in
            guard let self else { return }
            self.lidRequestInFlight = false
            if ok {
                self.lidHeld = disabled
                self.sleepDisabled = disabled
                self.lidNote = nil
            } else {
                self.lidHeld = false
                self.lidNote = "Lid mode error: \(message ?? "unknown")"
            }
        }
    }

    /// Reads `pmset -g` off the main thread (running it on main triggers a hang-risk warning).
    private func refreshSleepDisabled() {
        guard !sleepCheckInFlight, !lidRequestInFlight else { return }
        sleepCheckInFlight = true
        Task.detached(priority: .utility) {
            let value = LidGuard.sleepDisabled()
            await MainActor.run {
                self.sleepCheckInFlight = false
                if !self.lidRequestInFlight { self.sleepDisabled = value }
            }
        }
    }

    // MARK: Actions

    func keepAwake(for seconds: TimeInterval) {
        var control = ControlState.load(from: paths)
        control.extend(by: seconds, now: Date())
        try? control.save(to: paths)
        tick()
        eye.blink()
    }

    /// Keep awake until stopped, capped by the max hold (12 h by default).
    func keepAwakeUntilStopped() {
        var control = ControlState.load(from: paths)
        control.start(for: TrinetraCore.Settings.load(from: paths).maxHoldSeconds, now: Date())
        try? control.save(to: paths)
        tick()
        eye.blink()
    }

    func stopNow() {
        var control = ControlState.load(from: paths)
        control.stop(now: Date())
        try? control.save(to: paths)
        tick()
    }

    // MARK: Modules

    func setModule(_ module: Module, on: Bool) {
        var settings = TrinetraCore.Settings.load(from: paths)
        settings.modules.set(module, on: on)
        try? settings.save(to: paths)
        tick()
    }

    func setReadout(_ readout: MenuBarReadout) {
        var settings = TrinetraCore.Settings.load(from: paths)
        settings.menuBarReadout = readout
        try? settings.save(to: paths)
        tick()
    }

    func releaseOnQuit() {
        try? assertion.set(active: false, reason: "")
        if let i = holds.indices.last, holds[i].end == nil {
            holds[i].end = Date()
            holds[i].batteryEnd = power.batteryPercent
            holds[i].onBatteryEnd = !power.onAC
            saveHolds()
        }
        lidGuard.disconnect() // the helper restores normal sleep as soon as it sees the disconnect
    }

    // MARK: Helpers

    nonisolated static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func checkClaudeHooks() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return ClaudeHookInstaller.isInstalled(in: json)
    }
}

extension AgentState {
    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .ended: return 3
        }
    }
}
