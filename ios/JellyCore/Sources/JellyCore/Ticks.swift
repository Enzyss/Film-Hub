import Foundation

/// Jellyfin measures time in ticks: 10,000,000 per second.
public enum Ticks {
    public static let perSecond: Int64 = 10_000_000

    public static func fromSeconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * Double(perSecond)).rounded())
    }

    public static func toSeconds(_ ticks: Int64) -> Double {
        Double(ticks) / Double(perSecond)
    }

    /// "1:02:03" or "2:03".
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "1 h 42 min" or "42 min".
    public static func duration(_ ticks: Int64) -> String {
        let minutes = Int(toSeconds(ticks) / 60)
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(max(minutes, 1)) min"
    }
}
