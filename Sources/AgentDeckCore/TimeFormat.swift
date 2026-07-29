import Foundation

public enum TimeFormat {
    /// Compact age string: "now", "4m", "16h", "2d". Coarse on purpose —
    /// rows re-render on every hook event and each 15s sweep, and SwiftUI's
    /// per-second `.relative` Text style burned ~8% CPU while the popover
    /// was open.
    public static func compactAge(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}
