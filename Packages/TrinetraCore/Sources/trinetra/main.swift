import Foundation
import TrinetraCore

// trinetra — CLI for Trinetra. See architecture/LLD.md §3.

let usage = """
trinetra — keep your Mac awake while agents work

USAGE
  trinetra status [--json]               What's running and what Trinetra would do
  trinetra start <duration>              Keep awake for a duration (30m, 2h, 1h30m)
  trinetra extend <duration>             Add time to the timer
  trinetra stop                          Stop holding now (new activity resumes)
  trinetra run -- <command> [args…]      Keep awake while a command runs
  trinetra summary                       What each agent did (last 24 h) and battery saved today
  trinetra stats [--json]                CPU, GPU, memory, temperature, battery, power, network, disk
  trinetra modules [enable|disable <name>]   Toolkit modules (all off by default)
  trinetra hooks install <claude|codex|gemini|cursor> [--bin <path>]
  trinetra hooks uninstall <claude|codex|gemini|cursor>
  trinetra hook <agent> <working|waiting|idle|ended>   (called by agent hooks)
"""

let paths = Paths.default()
var arguments = Array(CommandLine.arguments.dropFirst())

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    printErr(message)
    exit(code)
}

// MARK: hook — must never block or fail the agent

func runHook(_ args: [String]) -> Never {
    guard args.count >= 2, let state = AgentState(rawValue: args[1]) else {
        printErr("trinetra hook: expected <agent> <working|waiting|idle|ended>")
        exit(0)
    }
    let agent = args[0]
    var payload: [String: Any] = [:]
    if isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    let pid = Proc.agentPID(agent: agent)
    let id = HookPayload.sessionID(payload) ?? "unknown-\(pid)"
    let cwd = HookPayload.cwd(payload)
    let now = Date()
    do {
        let activity = ActivitySummary.describe(state: state, payload: payload)
        let record = try SessionStore(paths: paths).upsert(agent: agent, id: id, state: state, pid: pid, cwd: cwd,
                                                            now: now, activity: activity)
        let (kind, detail) = ActivitySummary.classify(state: state, payload: payload)
        try SessionLog(paths: paths).append(SessionEvent(t: now, state: state, kind: kind, detail: detail), key: record.key)
    } catch {
        printErr("trinetra hook: \(error.localizedDescription)")
    }
    exit(0)
}

// MARK: run

func runWrapped(_ args: [String]) -> Never {
    var command = args
    if command.first == "--" { command.removeFirst() }
    guard !command.isEmpty else { fail("trinetra run: missing command\n\n\(usage)", code: 2) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    signal(SIGINT, SIG_IGN) // the child gets Ctrl-C from the terminal; we just wait for it

    // Not .main: the main thread is blocked in waitUntilExit below.
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    signal(SIGTERM, SIG_IGN)
    term.setEventHandler { process.terminate() }
    term.resume()

    do { try process.run() } catch { fail("trinetra run: \(error.localizedDescription)") }

    let store = SessionStore(paths: paths)
    let pid = process.processIdentifier
    let id = "run-\(pid)"
    // cwd is displayed by basename only, so store "<cwd>/<command>" to show the command name.
    let label = URL(fileURLWithPath: command[0]).lastPathComponent
    _ = try? store.upsert(agent: "run", id: id, state: .working, pid: pid,
                      cwd: FileManager.default.currentDirectoryPath + "/" + label, now: Date())
    process.waitUntilExit()
    _ = try? store.upsert(agent: "run", id: id, state: .ended, pid: pid, cwd: nil, now: Date())
    exit(process.terminationStatus)
}

// MARK: timer controls

func parseDuration(_ args: [String], command: String) -> TimeInterval {
    guard let text = args.first, let seconds = DurationParser.parse(text) else {
        fail("trinetra \(command): expected a duration like 30m, 2h or 1h30m", code: 2)
    }
    return seconds
}

func updateControl(_ change: (inout ControlState) -> Void) {
    var control = ControlState.load(from: paths)
    change(&control)
    do { try control.save(to: paths) } catch { fail("trinetra: \(error.localizedDescription)") }
}

// MARK: status

func runStatus(json: Bool) {
    let now = Date()
    let sessions = SessionStore(paths: paths).loadAll()
    let control = ControlState.load(from: paths)
    let settings = Settings.load(from: paths)
    let decision = Reconciler.decide(ReconcileInput(now: now, sessions: sessions, control: control,
                                                    settings: settings, isAlive: Proc.isAlive))
    if json {
        let out: [String: Any] = [
            "awake": decision.awake,
            "reasons": decision.reasons,
            "timerEnd": (control.timerEnd.map { ISO8601DateFormatter().string(from: $0) } as Any?) ?? NSNull(),
            "sessions": sessions.map { s -> [String: Any] in
                ["agent": s.agent, "id": s.id, "state": s.state.rawValue, "pid": s.pid,
                 "alive": Proc.isAlive(s.pid), "cwd": (s.cwdName as Any?) ?? NSNull(),
                 "updated": ISO8601DateFormatter().string(from: s.updatedAt)]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return
    }
    print(decision.awake ? "👁  Holding awake" : "💤 Not holding — Mac can sleep")
    for reason in decision.reasons { print("   • \(reason)") }
    print("   (power assumed on AC — the app reads real battery and heat)")
    let live = sessions.filter { $0.state != .ended && Proc.isAlive($0.pid) }
    if live.isEmpty {
        print("\nNo live agent sessions.")
    } else {
        print("\nSessions:")
        for s in live {
            let age = DurationFormat.short(now.timeIntervalSince(s.updatedAt))
            print("   \(s.agent.padding(toLength: 7, withPad: " ", startingAt: 0)) \(s.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(s.cwdName ?? "-")  (\(age) ago, pid \(s.pid))")
        }
    }
}

// MARK: hooks install / uninstall

func defaultBinary() -> String {
    let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/trinetra").path
    if FileManager.default.isExecutableFile(atPath: installed) { return installed }
    return Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? installed
}

func runHooks(_ args: [String]) {
    guard args.count >= 2, ["install", "uninstall"].contains(args[0]) else {
        fail("trinetra hooks: expected install|uninstall <agent>\n\n\(usage)", code: 2)
    }
    guard let agent = HookAgent(rawValue: args[1]) else {
        fail("trinetra hooks: supported agents are claude, codex, gemini and cursor", code: 2)
    }
    var bin = defaultBinary()
    if let i = args.firstIndex(of: "--bin"), i + 1 < args.count { bin = args[i + 1] }

    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(agent.configPath)
    let fm = FileManager.default
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: url), !data.isEmpty {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("trinetra hooks: \(url.path) is not valid JSON — fix it first, nothing was changed")
        }
        settings = parsed
        let backup = url.appendingPathExtension("trinetra.bak")
        if !fm.fileExists(atPath: backup.path) {
            do { try data.write(to: backup) } catch { fail("trinetra hooks: couldn't write backup: \(error.localizedDescription)") }
            print("Backed up original to \(backup.path)")
        }
    }

    let updated = args[0] == "install"
        ? AgentHookInstaller.install(into: settings, binary: bin, agent: agent)
        : AgentHookInstaller.uninstall(from: settings, agent: agent)
    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: updated,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    } catch {
        fail("trinetra hooks: \(error.localizedDescription)")
    }
    if args[0] == "install" {
        print("Installed \(agent.displayName) hooks in \(url.path) → \(bin)")
        print("Restart running \(agent.displayName) sessions to pick them up.")
        if agent == .codex {
            print("Codex asks you to review new hooks once: run `codex`, then `/hooks`, and trust Trinetra's entries.")
        }
    } else {
        print("Removed Trinetra's \(agent.displayName) hooks. Other hooks were left untouched.")
    }
}

// MARK: summary

func agentDisplayName(_ agent: String) -> String {
    HookAgent(rawValue: agent)?.displayName ?? (agent == "run" ? "Command" : agent)
}

func runSummary() {
    let now = Date()
    let log = SessionLog(paths: paths)
    let recent = SessionStore(paths: paths).loadAll()
        .filter { now.timeIntervalSince($0.updatedAt) < 86_400 }
        .sorted { $0.updatedAt > $1.updatedAt }
    if recent.isEmpty {
        print("No agent sessions in the last 24 hours.")
    }
    for s in recent {
        let summary = SessionSummary.build(log.load(key: s.key), now: now)
        let live = s.state != .ended && Proc.isAlive(s.pid)
        let when = live ? s.state.rawValue : "\(DurationFormat.short(now.timeIntervalSince(s.updatedAt))) ago"
        print("\(agentDisplayName(s.agent)) · \(s.cwdName ?? "-") · \(when)")
        print("   \(summary.headline)")
        for line in summary.detailLines { print("   \(line)") }
    }
    let day = EnergyEstimate.day(EnergyEstimate.load(from: paths), now: now)
    if day.holds > 0 {
        print("\nToday: held awake \(DurationFormat.short(day.heldSeconds)) over \(day.holds) hold\(day.holds == 1 ? "" : "s")"
              + (day.batteryUsed > 0 ? ", used \(day.batteryUsed) % battery" : ""))
        if day.sleptSeconds >= 60 {
            print("Slept \(DurationFormat.short(day.sleptSeconds)) as soon as work ended"
                  + (day.batterySaved >= 1 ? " ≈ \(Int(day.batterySaved.rounded())) % battery saved vs staying awake" : ""))
        }
    }
}

// MARK: stats

func runStats(json: Bool) {
    #if os(macOS)
    let sampler = SystemSampler()
    let thermal: ThermalLevel
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = .nominal
    case .fair: thermal = .fair
    case .serious: thermal = .serious
    case .critical: thermal = .critical
    @unknown default: thermal = .serious
    }
    _ = sampler.sample(thermal: thermal)        // CPU and network need two readings
    Thread.sleep(forTimeInterval: 1)
    let s = sampler.sample(thermal: thermal)
    if json {
        var out: [String: Any] = ["thermal": "\(thermal)", "memoryPressure": s.memoryPressure.label]
        if let v = s.cpu { out["cpu"] = v }
        if !s.cpuPerCore.isEmpty { out["cpuPerCore"] = s.cpuPerCore }
        if let v = s.gpu { out["gpu"] = v }
        if let m = s.memory {
            out["memory"] = ["total": m.total, "used": m.used, "cached": m.cached, "compressed": m.compressed,
                             "swapUsed": m.swapUsed]
        }
        if let v = s.hottest { out["hottestC"] = v }
        out["temperatures"] = s.temperatures.map { ["name": $0.name, "celsius": $0.celsius] }
        if let b = s.battery {
            var bat: [String: Any] = ["onAC": b.onAC, "charging": b.charging]
            if let v = b.percent { bat["percent"] = v }
            if let v = b.healthPercent { bat["healthPercent"] = v }
            if let v = b.cycleCount { bat["cycleCount"] = v }
            if let v = b.drawWatts { bat["drawWatts"] = v }
            if let v = b.temperature { bat["temperatureC"] = v }
            if let v = b.minutesRemaining { bat["minutesRemaining"] = v }
            out["battery"] = bat
        }
        if let d = s.downBytesPerSec, let u = s.upBytesPerSec { out["network"] = ["downBytesPerSec": d, "upBytesPerSec": u] }
        if let f = s.diskFree, let t = s.diskTotal { out["disk"] = ["free": f, "total": t] }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return
    }
    func row(_ label: String, _ value: String?) {
        guard let value else { return }
        print("\(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value)")
    }
    row("CPU", s.cpu.map { MetricFormat.percent($0) + " across \(s.cpuPerCore.count) cores" })
    row("GPU", s.gpu.map(MetricFormat.percent))
    row("Memory", s.memory.map { m in
        var line = "\(MetricFormat.bytes(m.used)) of \(MetricFormat.bytes(m.total)) · pressure \(s.memoryPressure.label)"
        if m.swapUsed > 0 { line += " · swap \(MetricFormat.bytes(m.swapUsed))" }
        return line
    })
    row("Temperature", s.hottest.map { MetricFormat.celsius($0) + " hottest sensor" })
    row("Thermal", thermal == .nominal ? nil : "\(thermal)")
    if let b = s.battery {
        var parts: [String] = []
        if let p = b.percent { parts.append("\(p) %" + (b.charging ? " charging" : b.onAC ? " on power" : "")) }
        if let h = b.healthPercent { parts.append("health \(h) %") }
        if let c = b.cycleCount { parts.append("\(c) cycles") }
        if let m = b.minutesRemaining { parts.append("\(DurationFormat.short(Double(m) * 60)) left") }
        row("Battery", parts.isEmpty ? nil : parts.joined(separator: " · "))
        row("Power", b.drawWatts.map { MetricFormat.watts($0) + (b.onAC ? " from the adapter" : " from the battery") })
    }
    if let d = s.downBytesPerSec, let u = s.upBytesPerSec { row("Network", "↓ \(MetricFormat.rate(d))  ↑ \(MetricFormat.rate(u))") }
    if let f = s.diskFree, let t = s.diskTotal { row("Disk", "\(MetricFormat.bytes(f)) free of \(MetricFormat.bytes(t))") }
    #else
    fail("trinetra stats: macOS only")
    #endif
}

// MARK: modules

func runModules(_ args: [String]) {
    var settings = Settings.load(from: paths)
    if args.count >= 2, ["enable", "disable"].contains(args[0]) {
        guard let module = Module(rawValue: args[1]) else {
            fail("trinetra modules: unknown module \(args[1]). Run `trinetra modules` for the list.", code: 2)
        }
        guard module.isAvailable else {
            fail("trinetra modules: \(module.title) arrives in phase \(module.phase); not built yet.", code: 2)
        }
        settings.modules.set(module, on: args[0] == "enable")
        do { try settings.save(to: paths) } catch { fail("trinetra modules: \(error.localizedDescription)") }
        print("\(module.title): \(args[0] == "enable" ? "on" : "off"). The app picks this up within a few seconds.")
        return
    }
    guard args.isEmpty || args == ["list"] else { fail("trinetra modules: expected enable|disable <name>", code: 2) }
    var group = ""
    for m in Module.allCases {
        if m.group != group {
            group = m.group
            print("\n\(group)")
        }
        let state = !m.isAvailable ? "phase \(m.phase)" : settings.modules.isOn(m) ? "on" : "off"
        print("  \(m.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(state.padding(toLength: 8, withPad: " ", startingAt: 0)) \(m.summary)")
    }
}

// MARK: dispatch

switch arguments.first {
case "hook":
    runHook(Array(arguments.dropFirst()))
case "run":
    runWrapped(Array(arguments.dropFirst()))
case "start":
    let seconds = parseDuration(Array(arguments.dropFirst()), command: "start")
    updateControl { $0.start(for: seconds, now: Date()) }
    print("👁  Holding awake for \(DurationFormat.short(seconds)).")
case "extend":
    let seconds = parseDuration(Array(arguments.dropFirst()), command: "extend")
    updateControl { $0.extend(by: seconds, now: Date()) }
    let end = ControlState.load(from: paths).timerEnd.map { DurationFormat.short($0.timeIntervalSinceNow) } ?? "?"
    print("👁  Timer extended — \(end) left.")
case "stop":
    updateControl { $0.stop(now: Date()) }
    print("💤 Stopped. Trinetra resumes on the next agent activity.")
case "status":
    runStatus(json: arguments.contains("--json"))
case "hooks":
    runHooks(Array(arguments.dropFirst()))
case "summary":
    runSummary()
case "stats":
    runStats(json: arguments.contains("--json"))
case "modules":
    runModules(Array(arguments.dropFirst()))
case nil, "-h", "--help", "help":
    print(usage)
default:
    fail(usage, code: 2)
}
