import Foundation

/// Turns raw model identifiers into something readable in a 360pt row:
/// `claude-opus-5-5` → "Opus 5.5", `gpt-6-astra` → "Astra 6".
///
/// Deliberately rule-based rather than a lookup table — providers ship new
/// models constantly and an unknown id must degrade to something sensible,
/// never to a blank or a crash.
public enum ModelName {
    /// Vendor prefixes that carry no information once the family is known.
    static let droppedTokens: Set<String> = ["claude", "gpt", "openai", "anthropic"]

    static func isVersionToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        // digits with at most one dot; long runs are dates (20251001), not versions
        let digitsOnly = token.replacingOccurrences(of: ".", with: "")
        guard digitsOnly.allSatisfy(\.isNumber), digitsOnly.count <= 3 else { return false }
        return token.filter { $0 == "." }.count <= 1
    }

    /// Pulls a bracketed qualifier off the end of an id —
    /// `claude-opus-5-5[1m]` is the 1M-context variant, and that suffix has
    /// to survive as its own word instead of being parsed as part of the
    /// version ("Opus 5[1m] 5").
    static func splitQualifier(_ id: String) -> (base: String, qualifier: String?) {
        guard let open = id.firstIndex(of: "["),
              let close = id.lastIndex(of: "]"), open < close else {
            return (id, nil)
        }
        let inner = String(id[id.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        let base = (String(id[id.startIndex..<open]) + String(id[id.index(after: close)...]))
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        guard !base.isEmpty else { return (id, nil) }
        return (base, inner.isEmpty ? nil : inner.uppercased())
    }

    public static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return raw }
        let (base, qualifier) = splitQualifier(trimmed)
        if let qualifier {
            return "\(display(base)) \(qualifier)"
        }
        let tokens = base.lowercased().split(separator: "-").map(String.init)
        guard !tokens.isEmpty else { return raw }

        var versions: [String] = []
        var words: [String] = []
        for token in tokens {
            if isVersionToken(token) {
                versions.append(token)
            } else if token.replacingOccurrences(of: ".", with: "").allSatisfy(\.isNumber) {
                continue  // long numeric run = a date stamp (20251001), not a name
            } else if !droppedTokens.contains(token) {
                words.append(token)
            }
        }
        // "5","5" → "5.5"; a token that already has a dot stands alone
        let version = versions.count > 1 && !versions.contains(where: { $0.contains(".") })
            ? versions.joined(separator: ".")
            : versions.first ?? ""

        if words.isEmpty {
            // no family name, e.g. "gpt-5.4"
            guard !version.isEmpty else { return raw }
            let vendor = tokens.first.map { droppedTokens.contains($0) ? $0 : "" } ?? ""
            return vendor.isEmpty ? version : "\(vendor.uppercased())-\(version)"
        }
        // capitalize only the family: "Codex mini", "Astra", "Opus"
        var name = words.enumerated()
            .map { $0.offset == 0 ? $0.element.capitalized : $0.element }
            .joined(separator: " ")
        if !version.isEmpty { name += " \(version)" }
        return name
    }
}
