import Foundation

/// Turns raw model identifiers into something readable in a 360pt row:
/// `claude-opus-5-5` → "Opus 5.5", `gpt-6-astra` → "Astra 6".
///
/// Deliberately rule-based rather than a lookup table — providers ship new
/// models constantly and an unknown id must degrade to something sensible,
/// never to a blank or a crash. The governing rule when a shape isn't
/// recognized is to pass the id through untouched: a half-understood id
/// rendered confidently is worse than a raw one, which is how
/// `claude-opus-5-5[1m` first came out as "Opus 5[1m 5".
public enum ModelName {
    /// Vendor prefixes that carry no information once the family is known.
    static let droppedTokens: Set<String> = ["claude", "gpt", "openai", "anthropic"]

    /// Longest label the row can show before it starts eating the path.
    static let maxLength = 28

    /// A short run of digits, optionally dotted: "5", "5.4", "1.2.3".
    /// Four or more digits is a date or build stamp, not a version.
    static func isVersionToken(_ token: String) -> Bool {
        let digits = token.replacingOccurrences(of: ".", with: "")
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) && digits.count <= 3
    }

    static func isNumericToken(_ token: String) -> Bool {
        let digits = token.replacingOccurrences(of: ".", with: "")
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// OpenAI pins snapshots as `gpt-5-2025-08-07`. The year is long enough
    /// to be rejected as a version on its own, but the month and day are
    /// not — without this they were collected as one ("GPT-5.08.07").
    static func strippingDateSuffix(_ tokens: [String]) -> [String] {
        guard tokens.count >= 4 else { return tokens }  // keep something to name
        let tail = Array(tokens.suffix(3))
        guard tail[0].count == 4, let year = Int(tail[0]),
              (1900...2999).contains(year) else { return tokens }
        guard tail.dropFirst().allSatisfy({ $0.count <= 2 && Int($0) != nil })
        else { return tokens }
        return Array(tokens.dropLast(3))
    }

    enum Brackets: Equatable {
        case none
        /// A trailing `[…]` variant marker: `claude-opus-5-5[1m]`.
        case qualifier(base: String, qualifier: String?)
        /// Brackets in some other arrangement — not a shape we understand.
        case unrecognized
    }

    static func brackets(in id: String) -> Brackets {
        let opens = id.filter { $0 == "[" }.count
        let closes = id.filter { $0 == "]" }.count
        if opens == 0 && closes == 0 { return .none }
        guard opens == 1, closes == 1, id.hasSuffix("]"),
              let open = id.firstIndex(of: "[") else { return .unrecognized }
        let base = String(id[id.startIndex..<open])
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        guard !base.isEmpty else { return .unrecognized }
        let inner = String(id[id.index(after: open)..<id.index(before: id.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        return .qualifier(base: base, qualifier: inner.isEmpty ? nil : inner.uppercased())
    }

    /// Whether two ids name the same model, ignoring a trailing `[…]`
    /// variant qualifier — `claude-opus-5-5[1m]` and `claude-opus-5-5` are
    /// the same model, one with long context.
    public static func sameBaseModel(_ a: String, _ b: String) -> Bool {
        baseIdentifier(a) == baseIdentifier(b)
    }

    static func baseIdentifier(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if case .qualifier(let base, _) = brackets(in: trimmed) { return base }
        return trimmed
    }

    public static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        switch brackets(in: trimmed) {
        case .unrecognized:
            return truncated(trimmed)
        case .qualifier(let base, let qualifier):
            let name = formatted(base)
            return truncated(qualifier.map { "\(name) \($0)" } ?? name)
        case .none:
            return truncated(formatted(trimmed))
        }
    }

    private static func formatted(_ id: String) -> String {
        let tokens = strippingDateSuffix(
            id.lowercased().split(separator: "-").map(String.init)
        )
        guard !tokens.isEmpty else { return id }

        var versions: [String] = []
        var words: [String] = []
        for token in tokens {
            if isVersionToken(token) {
                versions.append(token)
            } else if isNumericToken(token) {
                continue  // a long digit run is a date or build stamp
            } else if !droppedTokens.contains(token) {
                words.append(token)
            }
        }
        // "5","5" → "5.5"; "5.1" alone stays "5.1". Joining everything keeps
        // components that a first-one-wins rule used to silently drop.
        let version = versions.joined(separator: ".")
        let vendor = tokens.first.flatMap {
            droppedTokens.contains($0) ? $0.uppercased() : nil
        }

        // Nothing that reads as a family name ("gpt-4o", "gpt-5.4") — keep the
        // vendor, since "4O" on its own identifies nothing.
        guard words.contains(where: { $0.first?.isLetter == true }) else {
            let rest = (words + (version.isEmpty ? [] : [version]))
                .joined(separator: "-")
            guard !rest.isEmpty else { return id }
            return vendor.map { "\($0)-\(rest)" } ?? rest
        }

        // capitalize only the family: "Codex mini", "Astra", "Opus"
        var name = words.enumerated()
            .map { $0.offset == 0 ? $0.element.capitalized : $0.element }
            .joined(separator: " ")
        if !version.isEmpty { name += " \(version)" }
        return name
    }

    private static func truncated(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        return String(name.prefix(maxLength - 1)) + "…"
    }
}
