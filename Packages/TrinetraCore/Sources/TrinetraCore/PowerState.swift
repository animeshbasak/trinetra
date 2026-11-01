import Foundation

/// Mirrors `ProcessInfo.ThermalState` so the reconciler stays platform-neutral and testable.
public enum ThermalLevel: Int, Codable, Comparable, Sendable {
    case nominal = 0, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct PowerState: Equatable, Sendable {
    public var onAC: Bool
    /// nil on desktops / when unknown.
    public var batteryPercent: Int?
    public var thermal: ThermalLevel

    public init(onAC: Bool, batteryPercent: Int?, thermal: ThermalLevel = .nominal) {
        self.onAC = onAC
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }

    public static let unknownAC = PowerState(onAC: true, batteryPercent: nil, thermal: .nominal)
}
