import Foundation

/// Text for the usage lines under the popover header. Pure, so the
/// wording can be tested without SwiftUI.
public enum UsageFormat {
    /// Short command-style names, matching the footer's health dots.
    public static func name(_ provider: Provider) -> String {
        provider == .antigravity ? "agy" : provider.spec.displayName
    }

    /// "72%", "reset" once the window has rolled over, "–" when unknown.
    public static func percent(_ window: UsageWindow?, now: Date) -> String {
        guard let window else { return "–" }
        if window.resetPassed(now: now) { return "reset" }
        return "\(Int(window.usedPercent.rounded()))%"
    }

    public static let highThreshold = 90.0

    public static func isHigh(_ window: UsageWindow?, now: Date) -> Bool {
        guard let window, !window.resetPassed(now: now) else { return false }
        return window.usedPercent >= highThreshold
    }

    public static func isFull(_ window: UsageWindow?, now: Date) -> Bool {
        guard let window, !window.resetPassed(now: now) else { return false }
        return window.usedPercent >= 100
    }

    /// "2/1": 5-hour then weekly, for the narrow fallback layout.
    public static func compact(_ group: UsageGroup, now: Date) -> String {
        func bare(_ w: UsageWindow?) -> String {
            percent(w, now: now).replacingOccurrences(of: "%", with: "")
        }
        return "\(bare(group.session))/\(bare(group.weekly))"
    }

    /// Groups drawn on the line; tooltip-only groups and empty ones are left out.
    public static func lineGroups(_ usage: ProviderUsage) -> [UsageGroup] {
        usage.groups.filter { $0.inLine && !$0.isEmpty }
    }

    /// "Claude: 5-hour 100 percent used, weekly 17 percent used"
    public static func accessibilityLabel(_ usage: ProviderUsage, now: Date) -> String {
        let parts = lineGroups(usage).map { group -> String in
            let label = group.label.map { "\($0) " } ?? ""
            return "\(label)5-hour \(spoken(group.session, now: now)), weekly \(spoken(group.weekly, now: now))"
        }
        return "\(name(usage.provider)): " + parts.joined(separator: "; ")
    }

    private static func spoken(_ window: UsageWindow?, now: Date) -> String {
        guard let window else { return "unknown" }
        if window.resetPassed(now: now) { return "reset" }
        return "\(Int(window.usedPercent.rounded())) percent used"
    }

    /// Multi-line hover text: every group (including tooltip-only ones)
    /// with reset times, then where the figures came from.
    public static func tooltip(_ usage: ProviderUsage, now: Date,
                               calendar: Calendar = .current,
                               locale: Locale = .current) -> String {
        var lines: [String] = []
        for group in usage.groups where !group.isEmpty {
            let prefix = group.label.map { "\($0) " } ?? ""
            for (title, window) in [("5-hour", group.session), ("Weekly", group.weekly)] {
                guard let window else { continue }
                var line = "\(prefix)\(title): "
                if window.resetPassed(now: now) {
                    line += "reset passed, waiting for an update"
                } else {
                    line += "\(Int(window.usedPercent.rounded()))% used"
                    if let resets = window.resetsAt {
                        line += ", resets \(time(resets, now: now, calendar: calendar, locale: locale))"
                    }
                }
                lines.append(line)
            }
        }
        if let plan = usage.plan, !plan.isEmpty { lines.append("Plan: \(plan.capitalized)") }
        let seen = time(usage.observedAt, now: now, calendar: calendar, locale: locale)
        switch usage.provider {
        case .codex:
            lines.append("Latest recorded Codex usage, as of \(seen). Account not verified.")
        case .claude, .antigravity:
            lines.append("Last seen in a \(name(usage.provider)) session at \(seen).")
            if usage.changedAt < usage.observedAt {
                let changed = time(usage.changedAt, now: now, calendar: calendar, locale: locale)
                lines.append("Unchanged since \(changed).")
            }
        }
        if usage.isStale(now: now) { lines.append("Over 6 hours old.") }
        return lines.joined(separator: "\n")
    }

    /// "11:30 PM" today, otherwise "Nov 7, 11:30 PM".
    static func time(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMdjmm")
        return formatter.string(from: date)
    }
}
