import Foundation

// Pure value types and arithmetic for the system monitor (LLD §15). The readers that fill them
// live in SystemSampler.swift; everything here is platform-neutral and unit tested.

/// Cumulative CPU ticks for one core, as `host_processor_info` reports them.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: UInt64 { user &+ system &+ nice }
    public var total: UInt64 { busy &+ idle }
}

public enum CPUMath {
    /// Busy share (0…1) between two readings of the same core. A counter that went backwards
    /// (a core that slept and reset) counts as no data and returns nil.
    public static func load(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.total >= a.total, b.busy >= a.busy else { return nil }
        let total = b.total - a.total
        guard total > 0 else { return nil }
        return min(1, Double(b.busy - a.busy) / Double(total))
    }

    /// Per-core loads and the average across cores. Cores whose reading is unusable are skipped.
    public static func loads(from a: [CPUTicks], to b: [CPUTicks]) -> (perCore: [Double], average: Double?) {
        let n = min(a.count, b.count)
        var per: [Double] = []
        per.reserveCapacity(n)
        var sumBusy: UInt64 = 0, sumTotal: UInt64 = 0
        for i in 0..<n {
            guard let l = load(from: a[i], to: b[i]) else { per.append(0); continue }
            per.append(l)
            sumBusy += b[i].busy - a[i].busy
            sumTotal += b[i].total - a[i].total
        }
        return (per, sumTotal > 0 ? min(1, Double(sumBusy) / Double(sumTotal)) : nil)
    }

    /// Share of one core a process used between two readings of its CPU time (seconds).
    /// 1.0 = one full core; can exceed 1 for multithreaded work, like Activity Monitor's %CPU.
    public static func processLoad(cpuSecondsBefore: Double, cpuSecondsAfter: Double, wallSeconds: Double) -> Double? {
        guard wallSeconds > 0, cpuSecondsAfter >= cpuSecondsBefore else { return nil }
        return (cpuSecondsAfter - cpuSecondsBefore) / wallSeconds
    }
}

/// Memory in bytes, from `host_statistics64(HOST_VM_INFO64)` plus `vm.swapusage`.
public struct MemorySnapshot: Equatable, Sendable {
    public var total: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64       // file-backed pages: cached files macOS can drop
    public var swapUsed: UInt64
    public var swapTotal: UInt64

    public init(total: UInt64, free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64,
                compressed: UInt64, purgeable: UInt64, external: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        self.total = total
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
    }

    /// "Memory used" as Activity Monitor counts it: app memory + wired + compressed.
    /// App memory = anonymous pages (active + inactive − purgeable − file-backed).
    public var used: UInt64 {
        let anonymous = (active &+ inactive).subtractingClamped(purgeable &+ external)
        return min(total, anonymous &+ wired &+ compressed)
    }

    /// Cached files: memory macOS hands back the moment an app asks.
    public var cached: UInt64 { min(total, purgeable &+ external) }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// Rough pressure in the spirit of Activity Monitor's graph: compressed memory and swap push it up,
    /// free and cached memory pull it down.
    public var pressure: MemoryPressure {
        guard total > 0 else { return .normal }
        let available = Double(free &+ cached) / Double(total)
        let compressedShare = Double(compressed) / Double(total)
        if available < 0.05 && (compressedShare > 0.25 || swapUsed > total / 4) { return .critical }
        if available < 0.12 && (compressedShare > 0.15 || swapUsed > 0) { return .warning }
        return .normal
    }
}

public enum MemoryPressure: Int, Codable, Comparable, Sendable {
    case normal = 0, warning, critical

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }

    /// macOS's own level from `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical).
    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2, 3: self = .warning
        default: self = .normal
        }
    }

    public var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "high"
        case .critical: return "critical"
        }
    }
}

/// Cumulative interface byte counters (all non-loopback interfaces added up).
public struct NetCounters: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64
    /// `if_data` counters are 32-bit; 64-bit sources set this false.
    public var wraps32: Bool

    public init(received: UInt64, sent: UInt64, wraps32: Bool = false) {
        self.received = received
        self.sent = sent
        self.wraps32 = wraps32
    }
}

public enum NetMath {
    /// Bytes moved between two readings of a counter, handling a 32-bit wrap. A drop on a
    /// 64-bit counter means the interface went away and came back: no data.
    public static func delta(_ before: UInt64, _ after: UInt64, wraps32: Bool) -> UInt64? {
        if after >= before { return after - before }
        guard wraps32, before <= UInt64(UInt32.max) else { return nil }
        return (UInt64(UInt32.max) - before) + after + 1
    }

    /// Bytes per second down and up.
    public static func rates(from a: NetCounters, to b: NetCounters, seconds: Double) -> (down: Double, up: Double)? {
        guard seconds > 0,
              let down = delta(a.received, b.received, wraps32: a.wraps32 && b.wraps32),
              let up = delta(a.sent, b.sent, wraps32: a.wraps32 && b.wraps32) else { return nil }
        return (Double(down) / seconds, Double(up) / seconds)
    }
}

/// Battery facts from the AppleSmartBattery registry entry.
public struct BatteryInfo: Equatable, Sendable {
    public var percent: Int?
    public var charging: Bool
    public var onAC: Bool
    public var cycleCount: Int?
    /// mAh
    public var designCapacity: Int?
    /// mAh, what a full charge holds today
    public var fullChargeCapacity: Int?
    /// mV
    public var voltage: Int?
    /// mA, negative while discharging
    public var amperage: Int?
    /// °C
    public var temperature: Double?
    /// minutes; nil while macOS is still estimating
    public var minutesRemaining: Int?
    /// W the whole Mac draws from the adapter (Apple silicon telemetry), when known
    public var systemPowerIn: Double?

    public init(percent: Int? = nil, charging: Bool = false, onAC: Bool = true, cycleCount: Int? = nil,
                designCapacity: Int? = nil, fullChargeCapacity: Int? = nil, voltage: Int? = nil,
                amperage: Int? = nil, temperature: Double? = nil, minutesRemaining: Int? = nil,
                systemPowerIn: Double? = nil) {
        self.percent = percent
        self.charging = charging
        self.onAC = onAC
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.voltage = voltage
        self.amperage = amperage
        self.temperature = temperature
        self.minutesRemaining = minutesRemaining
        self.systemPowerIn = systemPowerIn
    }

    /// Health as macOS shows it: today's full charge against the design capacity, capped at 100 %.
    public var healthPercent: Int? {
        guard let design = designCapacity, design > 0, let full = fullChargeCapacity, full > 0 else { return nil }
        return min(100, Int((Double(full) / Double(design) * 100).rounded()))
    }

    /// W flowing out of (positive) or into (negative) the battery.
    public var batteryWatts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return -Double(v) * Double(a) / 1_000_000
    }

    /// Best guess at what the Mac draws right now: adapter telemetry on power, battery drain on battery.
    public var drawWatts: Double? {
        if onAC, let input = systemPowerIn, input > 0 { return input }
        if !onAC, let w = batteryWatts, w > 0 { return w }
        return nil
    }
}

/// One temperature sensor reading.
public struct TemperatureReading: Equatable, Sendable {
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public enum Temperatures {
    /// Plausible die temperatures only: sensors report 0, negative or absurd values when idle or absent.
    public static func plausible(_ c: Double) -> Bool { c > 5 && c < 130 }

    /// Hottest CPU/GPU-die reading, the number people mean by "the Mac's temperature".
    /// Apple silicon names die sensors "PMU tdie…" / "PMU2 tdie…"; Intel Macs expose "CPU" names.
    public static func hottestDie(_ readings: [TemperatureReading]) -> Double? {
        let die = readings.filter { r in
            let n = r.name.lowercased()
            return plausible(r.celsius) && (n.contains("tdie") || n.contains("cpu") || n.contains("gpu") || n.contains("soc"))
        }
        let pool = die.isEmpty ? readings.filter { plausible($0.celsius) } : die
        return pool.map(\.celsius).max()
    }

    /// Readings grouped by name with duplicates averaged, hottest first, for the details list.
    public static func summarized(_ readings: [TemperatureReading], limit: Int = 8) -> [TemperatureReading] {
        var sums: [String: (Double, Int)] = [:]
        for r in readings where plausible(r.celsius) {
            let s = sums[r.name] ?? (0, 0)
            sums[r.name] = (s.0 + r.celsius, s.1 + 1)
        }
        return sums.map { TemperatureReading(name: $0.key, celsius: $0.value.0 / Double($0.value.1)) }
            .sorted { $0.celsius != $1.celsius ? $0.celsius > $1.celsius : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }
}

/// Everything one sample of the monitor knows. Optional fields are nil when this Mac can't tell.
public struct SystemSnapshot: Equatable, Sendable {
    public var at: Date
    public var cpu: Double?
    public var cpuPerCore: [Double]
    public var gpu: Double?
    public var memory: MemorySnapshot?
    public var memoryPressure: MemoryPressure
    public var hottest: Double?
    public var temperatures: [TemperatureReading]
    public var battery: BatteryInfo?
    public var thermal: ThermalLevel
    public var downBytesPerSec: Double?
    public var upBytesPerSec: Double?
    public var diskFree: UInt64?
    public var diskTotal: UInt64?

    public init(at: Date, cpu: Double? = nil, cpuPerCore: [Double] = [], gpu: Double? = nil,
                memory: MemorySnapshot? = nil, memoryPressure: MemoryPressure = .normal, hottest: Double? = nil,
                temperatures: [TemperatureReading] = [], battery: BatteryInfo? = nil, thermal: ThermalLevel = .nominal,
                downBytesPerSec: Double? = nil, upBytesPerSec: Double? = nil, diskFree: UInt64? = nil,
                diskTotal: UInt64? = nil) {
        self.at = at
        self.cpu = cpu
        self.cpuPerCore = cpuPerCore
        self.gpu = gpu
        self.memory = memory
        self.memoryPressure = memoryPressure
        self.hottest = hottest
        self.temperatures = temperatures
        self.battery = battery
        self.thermal = thermal
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
        self.diskFree = diskFree
        self.diskTotal = diskTotal
    }
}

/// Fixed-size history for the sparklines: newest last, oldest dropped.
public struct MetricHistory: Equatable, Sendable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var latest: Double? { values.last }
    public var peak: Double? { values.max() }

    /// Values scaled to 0…1 against `ceiling` (or the peak when nil), for drawing.
    public func normalized(ceiling: Double? = nil) -> [Double] {
        let top = ceiling ?? max(values.max() ?? 0, .leastNonzeroMagnitude)
        guard top > 0 else { return values.map { _ in 0 } }
        return values.map { min(1, max(0, $0 / top)) }
    }
}

public enum MetricFormat {
    /// 0.427 → "43 %"
    public static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction) * 100).rounded())) %"
    }

    /// 1536 → "1.5 KB", binary units like Finder's memory sizes.
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(value) B" }
        return v >= 100 ? "\(Int(v.rounded())) \(units[i])" : String(format: "%.1f", v) + " " + units[i]
    }

    /// Network rate in bytes per second → "820 KB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond).rounded())) + "/s"
    }

    /// 12.34 → "12.3 W"
    public static func watts(_ w: Double) -> String {
        w >= 100 ? "\(Int(w.rounded())) W" : String(format: "%.1f W", w)
    }

    /// 61.6 → "62 °C"
    public static func celsius(_ c: Double) -> String { "\(Int(c.rounded())) °C" }
}

extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
