import SwiftUI
import TrinetraCore

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            lidControl
            Divider()
            agents
            Divider()
            keepAwake
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
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
            if model.lidModeOn && model.helperStatus == .needsApproval {
                Button("Open Login Items") { model.openLoginItems() }
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
                    AgentRow(session: session)
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

    var body: some View {
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
                Text(session.activity ?? fallbackActivity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(elapsed)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var agentName: String {
        switch session.agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "run": return "Command"
        default: return session.agent.capitalized
        }
    }

    private var color: Color {
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
