import SwiftUI
import TrinetraCore

/// Toolkit modules: switch on what you want; the rest of the roadmap is listed, greyed out.
struct ModulesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: SystemMonitor
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Modules").font(.caption.weight(.semibold))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    Spacer()
                    Text(onCount == 0 ? "all off" : "\(onCount) on").font(.caption2).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                                ForEach(Module.allCases.filter { $0.group == group }, id: \.self) { module in
                                    row(module)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 280)

                if model.modules.isOn(.systemMonitor) {
                    Picker("Menu bar shows", selection: Binding(get: { model.menuBarReadout },
                                                                set: { model.setReadout($0) })) {
                        ForEach(MenuBarReadout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .font(.caption)
                }
                if model.modules.isOn(.healthAlerts) && monitor.notificationsDenied {
                    Text("Notifications are off for Trinetra. Turn them on in System Settings › Notifications to get health alerts.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for m in Module.allCases where !seen.contains(m.group) { seen.append(m.group) }
        return seen
    }

    private var onCount: Int { Module.allCases.filter { model.modules.isOn($0) }.count }

    @ViewBuilder private func row(_ module: Module) -> some View {
        if module.isAvailable {
            Toggle(isOn: Binding(get: { model.modules.isOn(module) }, set: { model.setModule(module, on: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title).font(.callout)
                    Text(module.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title).font(.callout)
                    Text(module.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text("Phase \(module.phase)").font(.caption2).padding(.top, 2)
            }
            .foregroundStyle(.tertiary)
        }
    }
}
