import Foundation

/// The popover's two filters: the text field and the provider chips. Both
/// narrow the list only; the badge, notifications and restore offers always
/// count every session, so hiding a provider can't hide a session that is
/// blocked on you.
public enum SessionFilter {
    /// Rows whose title or project path contains the query, in the order
    /// given (the caller's order is frozen while the popover is open).
    public static func textMatches(
        _ sessions: [SessionSnapshot], query: String,
        title: (SessionSnapshot) -> String
    ) -> [SessionSnapshot] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            title($0).lowercased().contains(query)
                || $0.projectPath.lowercased().contains(query)
        }
    }

    /// The rows left once hidden providers are dropped. App-hosted rows go
    /// with their provider: Claude Desktop is Claude, ChatGPT is Codex.
    public static func visible(
        _ matches: [SessionSnapshot], hidden: Set<Provider>
    ) -> [SessionSnapshot] {
        hidden.isEmpty ? matches : matches.filter { !hidden.contains($0.provider) }
    }

    /// Per-provider counts of the text matches, hidden or not, so a hidden
    /// chip still says how many rows it hides.
    public static func counts(_ matches: [SessionSnapshot]) -> [Provider: Int] {
        var counts = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, 0) })
        for row in matches { counts[row.provider, default: 0] += 1 }
        return counts
    }

    /// Hidden providers with a session the badge counts (waiting or error,
    /// unacknowledged). Over every session, not just the text matches: the
    /// dot answers "is something hidden blocked on me", whatever is typed.
    public static func hiddenNeedingYou(
        _ sessions: [SessionSnapshot], hidden: Set<Provider>, acks: [String: Date]
    ) -> Set<Provider> {
        Set(sessions.lazy.filter {
            hidden.contains($0.provider) && Attention.isBlocking($0)
                && Attention.needsAttention($0, ackedAt: acks[$0.key])
        }.map(\.provider))
    }

    /// Stored form of the hidden set, in a stable order.
    public static func encode(_ hidden: Set<Provider>) -> [String] {
        Provider.allCases.filter(hidden.contains).map(\.rawValue)
    }

    /// Unknown names (a provider since renamed or removed) are dropped, so
    /// they can't hide something with no chip to show it again. Anything
    /// but a list of strings is damage, and hides nothing.
    public static func decode(_ stored: Any?) -> Set<Provider> {
        guard let values = stored as? [String] else { return [] }
        return Set(values.compactMap(Provider.init(rawValue:)))
    }
}
