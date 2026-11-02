import Foundation

/// Pulls the subscription figures out of a status line payload. Claude and
/// agy both pipe a JSON object to the status line command on every
/// refresh; it also carries the working directory, transcript path,
/// conversation title and (agy) the account email, none of which is kept.
public enum StatusLineCapture {
    /// Larger payloads are forwarded to the chained command untouched but
    /// not parsed.
    public static let maxInput = 1 << 20

    public static func extract(provider: Provider, data: Data, now: Date) -> ProviderUsage? {
        guard data.count <= maxInput,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return nil }
        switch provider {
        case .claude: return claude(payload, now: now)
        case .antigravity: return antigravity(payload, now: now)
        case .codex: return nil
        }
    }

    /// Claude Code 2.1.316: `rate_limits.five_hour` / `seven_day`, each
    /// `{used_percentage, resets_at}` with `resets_at` in epoch seconds.
    /// The whole object is absent for API-key and cloud-provider sessions.
    static func claude(_ payload: [String: Any], now: Date) -> ProviderUsage? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String, minutes: Int) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any],
                  let used = number(w["used_percentage"])
            else { return nil }
            return UsageWindow(usedPercent: used,
                               resetsAt: number(w["resets_at"]).map(Date.init(timeIntervalSince1970:)),
                               windowMinutes: minutes)
        }
        let group = UsageGroup(session: window("five_hour", minutes: 300),
                               weekly: window("seven_day", minutes: 10_080))
        guard !group.isEmpty else { return nil }
        return ProviderUsage(provider: .claude, groups: [group], observedAt: now)
    }

    /// agy 1.4.9: `quota` maps bucket ids (`gemini-5h`, `gemini-weekly`,
    /// `3p-5h`, `3p-weekly`, model-specific ones) to
    /// `{remaining_fraction, reset_time, reset_in_seconds}`. The ids are the
    /// only grouping the payload gives, so groups come from the id prefix.
    static func antigravity(_ payload: [String: Any], now: Date) -> ProviderUsage? {
        guard let quota = payload["quota"] as? [String: Any] else { return nil }
        var groups: [String: UsageGroup] = [:]
        for (id, value) in quota {
            guard let bucket = value as? [String: Any],
                  let remaining = number(bucket["remaining_fraction"])
            else { continue }
            let (prefix, isSession): (String, Bool)
            if id.hasSuffix("-5h") {
                (prefix, isSession) = (String(id.dropLast(3)), true)
            } else if id.hasSuffix("-weekly") {
                (prefix, isSession) = (String(id.dropLast(7)), false)
            } else {
                continue
            }
            var resets = (bucket["reset_time"] as? String).flatMap {
                SnapshotStore.isoFractional.date(from: $0) ?? SnapshotStore.isoPlain.date(from: $0)
            }
            if resets == nil, let seconds = number(bucket["reset_in_seconds"]) {
                resets = now.addingTimeInterval(seconds)
            }
            let used = max(0, min(100, (1 - remaining) * 100))
            let window = UsageWindow(usedPercent: used, resetsAt: resets,
                                     windowMinutes: isSession ? 300 : 10_080)
            var group = groups[prefix] ?? UsageGroup(
                label: antigravityLabel(prefix), inLine: antigravityInLine.contains(prefix))
            if isSession { group.session = window } else { group.weekly = window }
            groups[prefix] = group
        }
        guard !groups.isEmpty else { return nil }
        let ordered = groups.sorted { a, b in
            let ia = antigravityOrder.firstIndex(of: a.key) ?? .max
            let ib = antigravityOrder.firstIndex(of: b.key) ?? .max
            return ia != ib ? ia < ib : a.key < b.key
        }.map(\.value)
        return ProviderUsage(provider: .antigravity, groups: ordered, observedAt: now)
    }

    /// The two plan-wide groups go on the line; model-specific ones
    /// ("gemini-argon-wtu") are tooltip-only.
    static let antigravityInLine: Set<String> = ["gemini", "3p"]
    static let antigravityOrder = ["gemini", "3p"]

    static func antigravityLabel(_ prefix: String) -> String {
        switch prefix {
        case "gemini": return "Gemini"
        case "3p": return "Claude/GPT"
        default: return prefix
        }
    }

    private static func number(_ value: Any?) -> Double? {
        // `is Bool` also matches NSNumber 0 and 1; only a real JSON
        // true/false is a CFBoolean
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
