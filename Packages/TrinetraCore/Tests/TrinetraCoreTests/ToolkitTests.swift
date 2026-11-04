import XCTest
@testable import TrinetraCore

final class ModuleTests: XCTestCase {
    func testEverythingOffByDefault() {
        let set = TrinetraCore.Settings().modules
        for m in Module.allCases { XCTAssertFalse(set.isOn(m), m.rawValue) }
    }

    func testAlertsTurnOnTheMonitorAndOffWithIt() {
        var set = ModuleSet()
        set.set(.healthAlerts, on: true)
        XCTAssertTrue(set.isOn(.systemMonitor))
        XCTAssertTrue(set.isOn(.healthAlerts))
        set.set(.systemMonitor, on: false)
        XCTAssertFalse(set.isOn(.healthAlerts))
    }

    func testLaterPhasesAreListedButNotUsable() {
        var set = ModuleSet()
        set.set(.fanControl, on: true)
        XCTAssertFalse(set.isOn(.fanControl))
        XCTAssertFalse(Module.fanControl.isAvailable)
        XCTAssertTrue(Module.systemMonitor.isAvailable)
    }

    func testEveryModuleHasCopyAndAPhase() {
        for m in Module.allCases {
            XCTAssertFalse(m.title.isEmpty)
            XCTAssertFalse(m.summary.isEmpty)
            XCTAssertTrue((1...8).contains(m.phase))
        }
    }

    func testUnknownModuleNamesSurviveARoundTrip() throws {
        let data = Data(#"["system-monitor","from-the-future"]"#.utf8)
        let set = try JSONDecoder().decode(ModuleSet.self, from: data)
        XCTAssertTrue(set.isOn(.systemMonitor))
        let again = try JSONDecoder().decode(ModuleSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(again.names, ["system-monitor", "from-the-future"])
    }

    func testOldSettingsFileKeepsToolkitDefaults() throws {
        let old = Data(#"{"graceSeconds": 60}"#.utf8)
        let s = try JSONDecoder().decode(TrinetraCore.Settings.self, from: old)
        XCTAssertEqual(s.graceSeconds, 60)
        XCTAssertEqual(s.modules, ModuleSet())
        XCTAssertEqual(s.alerts, AlertThresholds())
        XCTAssertEqual(s.menuBarReadout, .none)
    }

    func testPartialAlertThresholds() throws {
        let s = try JSONDecoder().decode(TrinetraCore.Settings.self,
                                         from: Data(#"{"alerts": {"temperatureC": 88}, "menuBarReadout": "bogus"}"#.utf8))
        XCTAssertEqual(s.alerts.temperatureC, 88)
        XCTAssertEqual(s.alerts.cpuPercent, 90)
        XCTAssertEqual(s.menuBarReadout, .none)
    }
}

final class MetricsTests: XCTestCase {
    func testCPULoad() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 200, system: 100, idle: 1_700, nice: 0)
        XCTAssertEqual(CPUMath.load(from: a, to: b) ?? -1, 0.15, accuracy: 1e-9)
        XCTAssertNil(CPUMath.load(from: b, to: a), "a counter going backwards is no data")
        XCTAssertNil(CPUMath.load(from: a, to: a))
    }

    func testAverageIsWeightedByTicks() {
        let a = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let b = [CPUTicks(user: 100, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let l = CPUMath.loads(from: a, to: b)
        XCTAssertEqual(l.perCore, [1, 0])
        XCTAssertEqual(l.average ?? -1, 0.5, accuracy: 1e-9)
    }

    func testProcessLoad() {
        XCTAssertEqual(CPUMath.processLoad(cpuSecondsBefore: 10, cpuSecondsAfter: 14, wallSeconds: 2) ?? -1, 2, accuracy: 1e-9)
        XCTAssertNil(CPUMath.processLoad(cpuSecondsBefore: 10, cpuSecondsAfter: 9, wallSeconds: 2))
        XCTAssertNil(CPUMath.processLoad(cpuSecondsBefore: 1, cpuSecondsAfter: 2, wallSeconds: 0))
    }

    func testMemoryUsedLikeActivityMonitor() {
        let gb: UInt64 = 1 << 30
        let m = MemorySnapshot(total: 16 * gb, free: 2 * gb, active: 6 * gb, inactive: 4 * gb, wired: 2 * gb,
                               compressed: 1 * gb, purgeable: 1 * gb, external: 3 * gb, swapUsed: 0, swapTotal: 0)
        XCTAssertEqual(m.used, 9 * gb)          // (6 + 4 − 1 − 3) + 2 + 1
        XCTAssertEqual(m.cached, 4 * gb)
        XCTAssertEqual(m.usedFraction, 9.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(m.pressure, .normal)
    }

    func testMemoryPressureRises() {
        let gb: UInt64 = 1 << 30
        let tight = MemorySnapshot(total: 8 * gb, free: gb / 4, active: 3 * gb, inactive: gb, wired: 2 * gb,
                                   compressed: 2 * gb + gb / 2, purgeable: 0, external: gb / 8, swapUsed: 3 * gb, swapTotal: 4 * gb)
        XCTAssertEqual(tight.pressure, .critical)
        XCTAssertEqual(MemoryPressure(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
    }

    func testNetworkRatesAndWrap() {
        let r = NetMath.rates(from: NetCounters(received: 1_000, sent: 500), to: NetCounters(received: 5_000, sent: 1_500), seconds: 2)
        XCTAssertEqual(r?.down, 2_000)
        XCTAssertEqual(r?.up, 500)
        XCTAssertEqual(NetMath.delta(UInt64(UInt32.max) - 9, 10, wraps32: true), 20)
        XCTAssertNil(NetMath.delta(100, 10, wraps32: false))
        XCTAssertNil(NetMath.rates(from: NetCounters(received: 9, sent: 9), to: NetCounters(received: 1, sent: 1), seconds: 2))
    }

    func testBatteryHealthAndPower() {
        var b = BatteryInfo(percent: 80, onAC: false, cycleCount: 212, designCapacity: 6_075, fullChargeCapacity: 5_468,
                            voltage: 12_500, amperage: -1_200)
        XCTAssertEqual(b.healthPercent, 90)
        XCTAssertEqual(b.batteryWatts ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(b.drawWatts ?? 0, 15, accuracy: 1e-9)
        b.onAC = true
        b.systemPowerIn = 31.5
        XCTAssertEqual(b.drawWatts, 31.5)
        b.fullChargeCapacity = 6_500
        XCTAssertEqual(b.healthPercent, 100, "capped like macOS")
    }

    func testTemperatures() {
        let r = [TemperatureReading(name: "PMU tdie1", celsius: 61), TemperatureReading(name: "PMU tdie2", celsius: 67),
                 TemperatureReading(name: "NAND CH0 temp", celsius: 40), TemperatureReading(name: "gas gauge battery", celsius: 31),
                 TemperatureReading(name: "PMU tdie3", celsius: -40)]
        XCTAssertEqual(Temperatures.hottestDie(r), 67)
        XCTAssertEqual(Temperatures.hottestDie([TemperatureReading(name: "NAND", celsius: 44)]), 44)
        XCTAssertNil(Temperatures.hottestDie([]))
        let s = Temperatures.summarized(r + [TemperatureReading(name: "PMU tdie1", celsius: 63)], limit: 2)
        XCTAssertEqual(s.map(\.name), ["PMU tdie2", "PMU tdie1"])
        XCTAssertEqual(s[1].celsius, 62)
    }

    func testHistory() {
        var h = MetricHistory(capacity: 3)
        for v in [1.0, 2, 3, 4] { h.append(v) }
        XCTAssertEqual(h.values, [2, 3, 4])
        XCTAssertEqual(h.normalized(), [0.5, 0.75, 1])
        XCTAssertEqual(h.normalized(ceiling: 8), [0.25, 0.375, 0.5])
        XCTAssertEqual(MetricHistory(capacity: 4).normalized(), [])
    }

    func testFormats() {
        XCTAssertEqual(MetricFormat.percent(0.427), "43 %")
        XCTAssertEqual(MetricFormat.bytes(512), "512 B")
        XCTAssertEqual(MetricFormat.bytes(1_536), "1.5 KB")
        XCTAssertEqual(MetricFormat.bytes(250 << 20), "250 MB")
        XCTAssertEqual(MetricFormat.rate(2_048), "2.0 KB/s")
        XCTAssertEqual(MetricFormat.watts(12.34), "12.3 W")
        XCTAssertEqual(MetricFormat.celsius(61.6), "62 °C")
    }

    func testReadout() {
        let s = SystemSnapshot(at: Date(), cpu: 0.31, hottest: 58.2, downBytesPerSec: 1_024, upBytesPerSec: 0)
        XCTAssertEqual(MenuBarReadout.cpu.text(for: s), "31 %")
        XCTAssertEqual(MenuBarReadout.temperature.text(for: s), "58 °C")
        XCTAssertNil(MenuBarReadout.power.text(for: s))
        XCTAssertNil(MenuBarReadout.none.text(for: s))
        XCTAssertEqual(MenuBarReadout.network.text(for: s), "↓1.0 KB/s ↑0 B/s")
    }

    func testProcessTree() {
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11, 13: 10, 20: 1, 21: 20]
        XCTAssertEqual(ProcessTree.descendants(of: 10, parents: parents), [10, 11, 12, 13])
        XCTAssertEqual(ProcessTree.descendants(of: 99, parents: parents), [99])
    }
}

final class HealthAlertTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snap(_ seconds: TimeInterval, cpu: Double? = nil, hot: Double? = nil, thermal: ThermalLevel = .nominal,
              pressure: MemoryPressure = .normal, diskGB: Double? = nil, battery: BatteryInfo? = nil) -> SystemSnapshot {
        SystemSnapshot(at: t0.addingTimeInterval(seconds), cpu: cpu, memoryPressure: pressure, hottest: hot,
                       battery: battery, thermal: thermal, diskFree: diskGB.map { UInt64($0 * 1_073_741_824) })
    }

    func run(_ snaps: [SystemSnapshot], _ t: AlertThresholds = AlertThresholds()) -> [[HealthAlertKind]] {
        var state = HealthAlertState()
        return snaps.map { s in
            let r = HealthAlerts.evaluate(s, thresholds: t, state: state)
            state = r.state
            return r.alerts.map(\.kind)
        }
    }

    func testCPUWarnsOnlyWhenSustained() {
        let out = run([snap(0, cpu: 0.95), snap(60, cpu: 0.97), snap(120, cpu: 0.93), snap(180, cpu: 0.99)])
        XCTAssertEqual(out, [[], [], [.cpu], []])
    }

    func testShortCPUSpikeIsIgnored() {
        XCTAssertEqual(run([snap(0, cpu: 0.95), snap(60, cpu: 0.50), snap(130, cpu: 0.95)]).flatMap { $0 }, [])
    }

    func testCPUDipWithinMarginKeepsTheStretch() {
        // 80 % is under 90 but within the 15-point margin: still "high".
        XCTAssertEqual(run([snap(0, cpu: 0.95), snap(60, cpu: 0.80), snap(120, cpu: 0.95)]), [[], [], [.cpu]])
    }

    func testTemperatureHysteresisAndCooldown() {
        let out = run([snap(0, hot: 96), snap(10, hot: 94), snap(20, hot: 96),   // still raised: no repeat
                       snap(30, hot: 80),                                          // cleared
                       snap(40, hot: 97),                                          // inside cooldown: quiet
                       snap(30 + 901, hot: 97)])                                   // after cooldown: warns again
        XCTAssertEqual(out, [[.temperature], [], [], [], [], [.temperature]])
    }

    func testThermalMemoryDisk() {
        let out = run([snap(0, thermal: .serious, pressure: .warning, diskGB: 5)])
        XCTAssertEqual(Set(out[0]), [.thermal, .memory, .disk])
        var strict = AlertThresholds()
        strict.memoryPressure = .critical
        XCTAssertEqual(run([snap(0, pressure: .warning)], strict), [[]])
    }

    func testBatteryOnlyWhileDraining() {
        let draining = BatteryInfo(percent: 18, onAC: false, minutesRemaining: 50)
        let plugged = BatteryInfo(percent: 18, onAC: true)
        XCTAssertEqual(run([snap(0, battery: plugged), snap(10, battery: draining)]), [[], [.battery]])
        let alert = HealthAlerts.evaluate(snap(0, battery: draining), thresholds: AlertThresholds(), state: HealthAlertState()).alerts.first
        XCTAssertEqual(alert?.title, "Battery at 18 %")
        XCTAssertEqual(alert?.body, "On battery, about 50m left. Plug in to keep agents running.")
    }

    func testMissingDataNeverAlerts() {
        XCTAssertEqual(run([snap(0), snap(500)]), [[], []])
    }
}
