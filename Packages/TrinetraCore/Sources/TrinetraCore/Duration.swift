import Foundation

/// Parses "90s", "30m", "2h", "1h30m", "1d". Bare numbers are minutes.
public enum DurationParser {
    public static func parse(_ text: String) -> TimeInterval? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if let minutes = Double(s), minutes > 0 { return minutes * 60 }

        var total: TimeInterval = 0
        var number = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch ch {
            case "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3_600
            case "d": total += value * 86_400
            default: return nil
            }
            number = ""
        }
        guard number.isEmpty, total > 0 else { return nil }
        return total
    }
}

public enum DurationFormat {
    /// 45 → "45s", 300 → "5m", 5400 → "1h 30m".
    public static func short(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        if t < 60 { return "\(t)s" }
        let h = t / 3_600, m = (t % 3_600) / 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
