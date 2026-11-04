import SwiftUI
import TrinetraCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    /// Observed too, so tiles and per-agent CPU update while the menu is open.
    @ObservedObject var monitor: SystemMonitor

    /// CPU per agent while the system monitor is on.
    private var agentCPU: [String: Double] { model.modules.isOn(.systemMonitor) ? monitor.agentCPU : [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            lidControl
            Divider()
            agents
            if model.modules.isOn(.systemMonitor) {
                Divider()
                SystemSection(monitor: monitor)
            }
            if !model.recentSessions.isEmpty || model.today.holds > 0 {
                Divider()
                earlier
            }
            Divider()
            keepAwake
            Divider()
            ModulesView(model: model, monitor: monitor)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { monitor.menuVisible = true }
        .onDisappear { monitor.menuVisible = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(model.iconName)
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline).font(.headline)
                if model.decision.awake && !model.lidProtected {
                    Text(model.lidModeOn ? "Closing the lid will sleep the Mac until lid mode is ready."
                                         : "Closing the lid will sleep the Mac. Turn on lid mode below.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.decision.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Text(powerLine).font(.caption).foregroundStyle(.secondary)
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var powerLine: String {
        let source = model.power.onAC ? "On power adapter" : "On battery"
        let pct = model.power.batteryPercent.map { " · \($0) %" } ?? ""
        let heat = model.power.thermal >= .serious ? " · running hot" : ""
        return source + pct + heat
    }

    // MARK: Lid mode

    private var lidControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $model.lidModeOn) {
                Text("Keep awake with the lid closed").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(lidCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = model.lidNote {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.helperError {
                Text(error).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.lidModeOn && model.helperStatus != .ready {
                HStack(spacing: 6) {
                    Button("Open Login Items") { model.openLoginItems() }
                    Button("Retry") { model.retryHelper() }
                }
                .controlSize(.small)
            }
        }
    }

    private var lidCaption: String {
        if model.lidProtected && model.decision.awake {
            return "On. Switches off when the work ends, at \(model.batteryFloor) % battery, or if Trinetra quits."
        }
        if model.lidModeOn {
            return model.helperStatus == .ready
                ? "Ready. Kicks in whenever Trinetra is holding the Mac awake."
                : "Needs a one-time approval of Trinetra's helper."
        }
        return "Off. Trinetra keeps the Mac awake with the lid open only."
    }

    // MARK: Agents

    @ViewBuilder private var agents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.liveSessions.isEmpty ? "Agents" : "Agents · \(model.liveSessions.count) open")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.liveSessions.isEmpty {
                Text(model.claudeHooksInstalled ? "No agent sessions open" : "Run `trinetra hooks install claude` so Trinetra can see Claude Code")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.liveSessions, id: \.key) { session in
                    AgentRow(session: session, summary: model.summaries[session.key], cpu: agentCPU[session.key])
                }
            }
        }
    }

    // MARK: Earlier today + battery

    @ViewBuilder private var earlier: some View {
        if !model.recentSessions.isEmpty || model.today.holds > 0 {
            VStack(alignment: .leading, spacing: 8) {
                if !model.recentSessions.isEmpty {
                    Text("Earlier today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.recentSessions, id: \.key) { session in
                        AgentRow(session: session, summary: model.summaries[session.key], finished: true)
                    }
                }
                if model.today.holds > 0 {
                    EnergyLine(day: model.today)
                }
            }
        }
    }

    // MARK: Keep awake

    private var keepAwake: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stays awake while agents work, plus \(model.graceMinutes) min after. Add time for anything else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let end = model.timerEnd {
                Text("Timer ends \(end, style: .relative)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach([("30m", 1_800.0), ("1h", 3_600.0), ("2h", 7_200.0), ("4h", 14_400.0)], id: \.0) { label, secs in
                    Button(label) { model.keepAwake(for: secs) }.controlSize(.small)
                }
                Button("Until I stop") { model.keepAwakeUntilStopped() }.controlSize(.small)
            }
            Button("Stop holding now") { model.stopNow() }
                .controlSize(.small)
                .disabled(!model.decision.awake)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Trinetra 0.1").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                model.releaseOnQuit()
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

/// One open agent session: state dot, agent + project, what it's doing, and for how long.
struct AgentRow: View {
    let session: SessionRecord
    var summary: SessionSummary?
    var finished = false
    /// CPU used by the agent and what it started (1.0 = one core), when the system monitor is on.
    var cpu: Double?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row
            if let summary, summary.headline != "No activity yet" {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        Text(summary.headline).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 15)
                if expanded {
                    ForEach(summary.detailLines, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 27)
                    }
                }
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(agentName).font(.callout.weight(.medium))
                    Text("· \(session.cwdName ?? "unknown folder")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !finished {
                    Text(session.activity ?? fallbackActivity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let cpu, !finished {
                    Text("\(Int((cpu * 100).rounded())) % CPU")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(cpu >= 2 ? Color.orange : Color.secondary)
                        .help("CPU used by this agent and the commands it started. 100 % is one core.")
                }
            }
        }
    }

    private var agentName: String {
        switch session.agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "cursor": return "Cursor"
        case "run": return "Command"
        default: return session.agent.capitalized
        }
    }

    private var color: Color {
        if finished { return .gray.opacity(0.5) }
        switch session.state {
        case .working: return .green
        case .waiting: return .orange
        case .idle, .ended: return .gray
        }
    }

    private var fallbackActivity: String {
        switch session.state {
        case .working: return "Working"
        case .waiting: return "Waiting for your approval"
        case .idle: return "Waiting for your next prompt"
        case .ended: return "Ended"
        }
    }

    private var elapsed: String {
        if finished { return "\(DurationFormat.short(Date().timeIntervalSince(session.updatedAt))) ago" }
        let since: Date
        let label: String
        switch session.state {
        case .working:
            since = session.turnStartedAt ?? session.updatedAt
            label = "working"
        case .waiting:
            since = session.updatedAt
            label = "waiting"
        case .idle, .ended:
            since = session.updatedAt
            label = "idle"
        }
        return "\(label) \(DurationFormat.short(Date().timeIntervalSince(since)))"
    }
}

/// "Today: held awake 3h 10m · used 12 % · ≈ 18 % battery saved by sleeping when work ended"
struct EnergyLine: View {
    let day: EnergyEstimate.Day

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(heldLine).font(.caption).foregroundStyle(.secondary)
            if day.sleptSeconds >= 60 {
                Text(savedLine).font(.caption).foregroundStyle(.green)
                    .help("Estimate: time the Mac slept right after work ended × this Mac's measured awake drain. Compared with keeping it awake.")
            }
        }
    }

    private var heldLine: String {
        var line = "Held awake \(DurationFormat.short(day.heldSeconds)) for agents"
        if day.batteryUsed > 0 { line += " · used \(day.batteryUsed) % battery" }
        return line
    }

    private var savedLine: String {
        var line = "Slept \(DurationFormat.short(day.sleptSeconds)) as soon as work ended"
        if day.batterySaved >= 1 { line += " · ≈ \(Int(day.batterySaved.rounded())) % battery saved" }
        return line
    }
}
