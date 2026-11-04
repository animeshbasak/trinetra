import Foundation

/// Which processes belong to an agent: the agent itself and everything it started.
public enum ProcessTree {
    /// `parents` maps pid → parent pid for every running process.
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in parents where pid != ppid { children[ppid, default: []].append(pid) }
        var seen: Set<Int32> = [root]
        var stack = [root]
        while let p = stack.popLast() {
            for c in children[p] ?? [] where seen.insert(c).inserted { stack.append(c) }
        }
        return seen
    }
}

#if os(macOS)
import Darwin
import IOKit
import IOKit.ps

/// Reads the live numbers behind `SystemSnapshot` (LLD §15). No privileges, no network, no
/// private frameworks linked: the temperature sensors use IOKit's HID event system through
/// `dlsym`, and anything this Mac doesn't expose comes back nil. Not thread-safe; use one
/// sampler from one queue.
public final class SystemSampler {
    private var lastTicks: [CPUTicks] = []
    private var lastNet: (NetCounters, Date)?
    private var lastProcessCPU: [Int32: (seconds: Double, at: Date)] = [:]
    private let thermometer = HIDThermometer()

    public init() {}

    /// One full sample. The first call returns nil CPU and network (they need two readings).
    public func sample(now: Date = Date(), thermal: ThermalLevel) -> SystemSnapshot {
        var snap = SystemSnapshot(at: now, thermal: thermal)

        let ticks = SystemSampler.cpuTicks()
        if !lastTicks.isEmpty {
            let l = CPUMath.loads(from: lastTicks, to: ticks)
            snap.cpu = l.average
            snap.cpuPerCore = l.perCore
        }
        lastTicks = ticks

        snap.gpu = SystemSampler.gpuUtilization()
        snap.memory = SystemSampler.memory()
        snap.memoryPressure = SystemSampler.kernelPressure()
            ?? snap.memory?.pressure ?? .normal

        let temps = thermometer.read()
        snap.temperatures = Temperatures.summarized(temps)
        snap.hottest = Temperatures.hottestDie(temps)

        snap.battery = SystemSampler.battery()

        let net = SystemSampler.netCounters()
        if let last = lastNet, let r = NetMath.rates(from: last.0, to: net, seconds: now.timeIntervalSince(last.1)) {
            snap.downBytesPerSec = r.down
            snap.upBytesPerSec = r.up
        }
        lastNet = (net, now)

        if let disk = SystemSampler.disk() {
            snap.diskFree = disk.free
            snap.diskTotal = disk.total
        }
        return snap
    }

    /// CPU (1.0 = one core) used by each agent and the processes it started, since the last call.
    public func agentLoads(roots: [Int32], now: Date = Date()) -> [Int32: Double] {
        guard !roots.isEmpty else {
            lastProcessCPU = [:]
            return [:]
        }
        let parents = SystemSampler.parentMap()
        var result: [Int32: Double] = [:]
        var seen: [Int32: (seconds: Double, at: Date)] = [:]
        for root in roots {
            var hasPrevious = false
            var loadSum = 0.0
            for pid in ProcessTree.descendants(of: root, parents: parents) {
                guard let secs = SystemSampler.cpuSeconds(pid) else { continue }
                seen[pid] = (secs, now)
                if let prev = lastProcessCPU[pid],
                   let l = CPUMath.processLoad(cpuSecondsBefore: prev.seconds, cpuSecondsAfter: secs,
                                               wallSeconds: now.timeIntervalSince(prev.at)) {
                    hasPrevious = true
                    loadSum += l
                }
            }
            if hasPrevious { result[root] = loadSum }
        }
        lastProcessCPU = seen
        return result
    }

    // MARK: CPU

    static func cpuTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return [] }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stride = Int(CPU_STATE_MAX)
        var out: [CPUTicks] = []
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            out.append(CPUTicks(user: user, system: system, idle: idle, nice: nice))
        }
        return out
    }

    // MARK: Memory

    static func memory() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(sysctlInt("hw.pagesize") ?? 16_384)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        return MemorySnapshot(
            total: ProcessInfo.processInfo.physicalMemory,
            free: UInt64(stats.free_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            purgeable: UInt64(stats.purgeable_count) * page,
            external: UInt64(stats.external_page_count) * page,
            swapUsed: hasSwap ? swap.xsu_used : 0,
            swapTotal: hasSwap ? swap.xsu_total : 0)
    }

    static func kernelPressure() -> MemoryPressure? {
        sysctlInt("kern.memorystatus_vm_pressure_level").map { MemoryPressure(kernelLevel: $0) }
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // 32-bit values land in the low bytes on little-endian Macs.
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    // MARK: GPU

    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                let value = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber)
                if let v = value?.doubleValue { best = max(best ?? 0, min(100, max(0, v)) / 100) }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    // MARK: Battery

    static func battery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }

        var info = BatteryInfo()
        info.onAC = bool("ExternalConnected")
        info.charging = bool("IsCharging")
        info.cycleCount = int("CycleCount")
        info.designCapacity = int("DesignCapacity")
        // Apple silicon reports MaxCapacity as a percentage; the mAh figure is AppleRawMaxCapacity.
        info.fullChargeCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("MaxCapacity")
        info.voltage = int("Voltage")
        info.amperage = int("InstantAmperage") ?? int("Amperage")
        info.temperature = int("Temperature").map { Double($0) / 100 }
        if let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 {
            info.percent = max == 100 ? current : Int((Double(current) / Double(max) * 100).rounded())
        }
        if let minutes = int("TimeRemaining") ?? int("AvgTimeToEmpty"), minutes > 0, minutes < 65_535, !info.onAC {
            info.minutesRemaining = minutes
        }
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue, milliwatts > 0 {
            info.systemPowerIn = milliwatts / 1000
        }
        return info
    }

    // MARK: Network

    static func netCounters() -> NetCounters {
        var received: UInt64 = 0, sent: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return NetCounters(received: 0, sent: 0) }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0,
                  let raw = ifa.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }
        // A sum of 32-bit counters doesn't wrap as one value, so a drop counts as "no data".
        return NetCounters(received: received, sent: sent)
    }

    // MARK: Disk

    static func disk() -> (free: UInt64, total: UInt64)? {
        let root = URL(fileURLWithPath: "/")
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity,
              free >= 0, total > 0 else { return nil }
        return (UInt64(free), UInt64(total))
    }

    // MARK: Processes

    static func parentMap() -> [Int32: Int32] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [:] }
        var pids = [Int32](repeating: 0, count: capacity)
        let bytes = Int32(capacity * MemoryLayout<Int32>.stride)
        let n = Int(proc_listallpids(&pids, bytes))
        guard n > 0 else { return [:] }
        var map: [Int32: Int32] = [:]
        map.reserveCapacity(n)
        for pid in pids.prefix(n) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                map[pid] = Int32(info.pbi_ppid)
            }
        }
        return map
    }

    private static let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(max(1, tb.denom)))
    }()

    /// Total CPU time a process has used, in seconds.
    static func cpuSeconds(_ pid: Int32) -> Double? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // ri_*_time are mach absolute time units (ticks on Apple silicon, ns on Intel).
        let ticks = Double(usage.ri_user_time) + Double(usage.ri_system_time)
        return ticks * timebase.numer / timebase.denom / 1_000_000_000
    }
}

/// Temperature sensors through IOKit's HID event system (the same source as `powermetrics`'
/// SMC-free readings). Resolved with `dlsym` so a macOS that drops these symbols only loses
/// temperatures instead of failing to launch.
final class HIDThermometer {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEvent: Int64 = 15                 // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)           // IOHIDEventFieldBase(type)

    private let client: CFTypeRef?
    private let copyServices: CopyServices?
    private let copyProperty: CopyProperty?
    private let copyEvent: CopyEvent?
    private let getFloat: GetFloat?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        let create = sym("IOHIDEventSystemClientCreate", ClientCreate.self)
        let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloat.self)

        guard let create, let setMatching, let c = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            client = nil
            return
        }
        // Apple vendor page 0xff00, usage 5: temperature sensors.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(c, matching)
        client = c
    }

    func read() -> [TemperatureReading] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var out: [TemperatureReading] = []
        out.reserveCapacity(services.count)
        for service in services {
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            guard let event = copyEvent(service, HIDThermometer.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let c = getFloat(event, HIDThermometer.temperatureField)
            if Temperatures.plausible(c) { out.append(TemperatureReading(name: name, celsius: c)) }
        }
        return out
    }
}
#endif
