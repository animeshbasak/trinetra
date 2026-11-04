import AppKit
import SwiftUI
import TrinetraCore

/// The System block in the menu: six live tiles with sparklines, and details on demand.
struct SystemSection: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var expanded = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("System").font(.caption.weight(.semibold))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    Spacer()
                    if let s = monitor.snapshot, s.memoryPressure > .normal || s.thermal >= .serious {
                        Text(s.thermal >= .serious ? "running hot" : "memory \(s.memoryPressure.label)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let s = monitor.snapshot {
                LazyVGrid(columns: columns, spacing: 8) {
                    MetricTile(label: "CPU", value: s.cpu.map(MetricFormat.percent), history: monitor.cpu, ceiling: 1, tint: .green)
                    MetricTile(label: "GPU", value: s.gpu.map(MetricFormat.percent), history: monitor.gpu, ceiling: 1, tint: .purple)
                    MetricTile(label: "Memory", value: s.memory.map { MetricFormat.bytes($0.used) },
                               history: monitor.memory, ceiling: 1, tint: pressureTint(s.memoryPressure))
                    MetricTile(label: "Temperature", value: s.hottest.map(MetricFormat.celsius),
                               history: monitor.temperature, ceiling: 110, tint: .orange)
                    MetricTile(label: s.battery?.onAC == false ? "Power · battery" : "Power",
                               value: s.battery?.drawWatts.map(MetricFormat.watts), history: monitor.power, ceiling: nil, tint: .yellow)
                    MetricTile(label: "Network",
                               value: s.downBytesPerSec.map { "↓ " + MetricFormat.rate($0) },
                               detail: s.upBytesPerSec.map { "↑ " + MetricFormat.rate($0) },
                               history: monitor.down, ceiling: nil, tint: .blue)
                }
                if expanded { details(s) }
            } else {
                Text("Reading the Mac's sensors…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pressureTint(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return .teal
        case .warning: return .orange
        case .critical: return .red
        }
    }

    @ViewBuilder private func details(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !s.cpuPerCore.isEmpty {
                CoreBars(loads: s.cpuPerCore)
                    .frame(height: 18)
                    .help("Each bar is one CPU core")
            }
            if let m = s.memory {
                detail("Memory", "\(MetricFormat.bytes(m.used)) used · \(MetricFormat.bytes(m.cached)) cached · \(MetricFormat.bytes(m.compressed)) compressed")
                if m.swapUsed > 0 { detail("Swap", "\(MetricFormat.bytes(m.swapUsed)) of \(MetricFormat.bytes(m.swapTotal))") }
                detail("Pressure", s.memoryPressure.label.capitalized)
            }
            if let b = s.battery, let line = batteryLine(b) {
                detail("Battery", line)
            }
            if let f = s.diskFree, let t = s.diskTotal {
                detail("Disk", "\(MetricFormat.bytes(f)) free of \(MetricFormat.bytes(t))")
            }
            if !s.temperatures.isEmpty {
                detail("Sensors", s.temperatures.prefix(4).map { "\(shortSensor($0.name)) \(MetricFormat.celsius($0.celsius))" }.joined(separator: " · "))
            }
            Button("Open Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func batteryLine(_ b: BatteryInfo) -> String? {
        var parts: [String] = []
        if let h = b.healthPercent { parts.append("health \(h) %") }
        if let c = b.cycleCount { parts.append("\(c) cycles") }
        if let t = b.temperature { parts.append(MetricFormat.celsius(t)) }
        if let m = b.minutesRemaining { parts.append("\(DurationFormat.short(Double(m) * 60)) left") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "PMU tdie3" → "die 3", "NAND CH0 temp" → "SSD", for a short sensor line.
    private func shortSensor(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("tdie") { return "die " + name.filter(\.isNumber) }
        if lower.contains("nand") { return "SSD" }
        if lower.contains("battery") || lower.contains("gas gauge") { return "battery" }
        return name.count > 12 ? String(name.prefix(12)) : name
    }
}

/// One tile: label, big value, and a sparkline of the last three minutes.
struct MetricTile: View {
    let label: String
    let value: String?
    var detail: String?
    let history: MetricHistory
    let ceiling: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "–").font(.callout.weight(.semibold).monospacedDigit())
                if let detail { Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Sparkline(values: history.normalized(ceiling: ceiling), tint: tint)
                .frame(height: 18)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

/// A filled line chart of values in 0…1.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Newest value at the right edge; a short history fills from the right.
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(SystemMonitor.historyLength - 1)
        let startX = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: startX + step * CGFloat(i), y: size.height - CGFloat(v) * (size.height - 1.5) - 0.75)
        }
    }
}

/// Per-core load as a row of thin bars.
struct CoreBars: View {
    let loads: [Double]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(max(0, loads.count - 1))) / CGFloat(max(1, loads.count)))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(loads.enumerated()), id: \.offset) { _, l in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.green.opacity(0.8))
                            .frame(height: max(1, geo.size.height * CGFloat(l)))
                    }
                    .frame(width: w)
                }
            }
        }
    }
}
