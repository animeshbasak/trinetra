import Foundation
import TrinetraCore
import UserNotifications

/// The system monitor and health alerts modules (LLD §15). Off unless the user turns the module on.
/// Samples on a background queue: every 2 s while the menu is open or a menu bar readout is shown,
/// every 10 s otherwise (enough for alerts), and not at all when the module is off.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var cpu = MetricHistory(capacity: SystemMonitor.historyLength)
    @Published private(set) var gpu = MetricHistory(capacity: SystemMonitor.historyLength)
    @Published private(set) var memory = MetricHistory(capacity: SystemMonitor.historyLength)
    @Published private(set) var temperature = MetricHistory(capacity: SystemMonitor.historyLength)
    @Published private(set) var power = MetricHistory(capacity: SystemMonitor.historyLength)
    @Published private(set) var down = MetricHistory(capacity: SystemMonitor.historyLength)
    @Published private(set) var up = MetricHistory(capacity: SystemMonitor.historyLength)
    /// CPU per open agent session (1.0 = one core), keyed by session key.
    @Published private(set) var agentCPU: [String: Double] = [:]
    @Published private(set) var isOn = false
    @Published private(set) var alertsOn = false
    @Published private(set) var notificationsDenied = false

    /// Menu bar text, pushed to the owner only when it changes (so the menu bar doesn't redraw every sample).
    var onReadoutChange: ((String?) -> Void)?

    static let historyLength = 90

    private let worker = SamplerBox()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var readout: MenuBarReadout = .none
    private var thresholds = AlertThresholds()
    private var alertState = HealthAlertState()
    private var agents: [(key: String, pid: Int32)] = []
    private var sampling = false
    private var lastReadout: String?
    var menuVisible = false {
        didSet { if menuVisible != oldValue { reschedule(); if menuVisible { sampleNow() } } }
    }

    /// Called from the app's 3 s tick with the current settings and open sessions.
    func configure(settings: TrinetraCore.Settings, sessions: [SessionRecord], thermal: ThermalLevel) {
        let on = settings.modules.isOn(.systemMonitor)
        let wantsAlerts = settings.modules.isOn(.healthAlerts)
        if wantsAlerts && !alertsOn { requestNotificationPermission() }
        if !wantsAlerts { alertState = HealthAlertState() }
        alertsOn = wantsAlerts
        thresholds = settings.alerts
        readout = settings.menuBarReadout
        agents = sessions.map { ($0.key, $0.pid) }
        self.thermal = thermal
        if on != isOn {
            isOn = on
            if !on { reset() }
        }
        reschedule()
    }

    private var thermal: ThermalLevel = .nominal

    private func reschedule() {
        let wanted: TimeInterval = !isOn ? 0 : (menuVisible || readout != .none) ? 2 : 10
        guard wanted != interval else { return }
        interval = wanted
        timer?.invalidate()
        timer = nil
        guard wanted > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        timer?.tolerance = wanted / 4
        sampleNow()
    }

    private func sampleNow() {
        guard isOn, !sampling else { return }
        sampling = true
        let thermal = self.thermal
        let roots = agents.map(\.pid)
        let worker = self.worker
        Task.detached(priority: .utility) {
            let result = worker.run(thermal: thermal, roots: roots)
            await MainActor.run { [weak self] in self?.apply(result.snapshot, loads: result.loads) }
        }
    }

    private func apply(_ s: SystemSnapshot, loads: [Int32: Double]) {
        sampling = false
        guard isOn else { return }
        snapshot = s
        if let v = s.cpu { cpu.append(v) }
        if let v = s.gpu { gpu.append(v) }
        if let m = s.memory { memory.append(m.usedFraction) }
        if let v = s.hottest { temperature.append(v) }
        if let w = s.battery?.drawWatts { power.append(w) }
        if let d = s.downBytesPerSec, let u = s.upBytesPerSec {
            down.append(d)
            up.append(u)
        }
        var byKey: [String: Double] = [:]
        for a in agents { if let l = loads[a.pid] { byKey[a.key] = l } }
        agentCPU = byKey

        let text = readout.text(for: s)
        if text != lastReadout {
            lastReadout = text
            onReadoutChange?(text)
        }

        if alertsOn {
            let (alerts, next) = HealthAlerts.evaluate(s, thresholds: thresholds, state: alertState)
            alertState = next
            for alert in alerts { post(alert) }
        }
    }

    private func reset() {
        snapshot = nil
        let empty = MetricHistory(capacity: SystemMonitor.historyLength)
        cpu = empty
        gpu = empty
        memory = empty
        temperature = empty
        power = empty
        down = empty
        up = empty
        agentCPU = [:]
        alertState = HealthAlertState()
        worker.reset()
        if lastReadout != nil {
            lastReadout = nil
            onReadoutChange?(nil)
        }
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in self?.notificationsDenied = !granted }
        }
    }

    private func post(_ alert: HealthAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = "trinetra.health"
        let request = UNNotificationRequest(identifier: "trinetra.health.\(alert.kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Owns the sampler; only ever used from one detached task at a time (guarded by `sampling`).
private final class SamplerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sampler = SystemSampler()

    func run(thermal: ThermalLevel, roots: [Int32]) -> (snapshot: SystemSnapshot, loads: [Int32: Double]) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return (sampler.sample(now: now, thermal: thermal), sampler.agentLoads(roots: roots, now: now))
    }

    func reset() {
        lock.lock()
        sampler = SystemSampler()
        lock.unlock()
    }
}
