import Foundation

public enum RowMeta {
    /// Model / effort / tokens for the row tooltip. The Codex thread
    /// database is consulted only for a Codex row: a Claude session whose
    /// id happened to match a Codex thread would otherwise show that
    /// thread's effort and token count.
    public static func summary(
        provider: Provider, model: String?, effort: String?, codexThread: CodexThread?
    ) -> String? {
        let thread = provider == .codex ? codexThread : nil
        var parts: [String] = []
        if let model { parts.append(model) }
        if let effort { parts.append("effort \(effort)") }
        else if let e = thread?.effort { parts.append("effort \(e)") }
        if let tokens = thread?.tokensUsed {
            parts.append("\(tokens / 1000)k tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
