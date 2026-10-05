import Foundation

/// Deciding which of two disagreeing sources names a session's model.
///
/// This lives in core rather than in the view model because every bug this
/// project has shipped to a user escaped through untested app-target code.
public enum ModelSource {
    /// Claude has two sources and each is wrong in a different way.
    ///
    /// Measured across 23 live sessions on one machine: the hook payload and
    /// the transcript's last assistant turn agreed 19 times. Of the four
    /// disagreements, one had the payload reporting `claude-fable-5-1` for a
    /// session whose transcript was 160 of 160 `claude-opus-5-5` — the
    /// payload named a model the session was not running, confirmed by the
    /// person running it. The other three were payloads carrying a
    /// `[1m]` long-context qualifier that the transcript never records.
    ///
    /// So the transcript names the model, and the payload contributes its
    /// qualifier when the two agree on which model it is. Neither is
    /// authoritative alone.
    ///
    /// Not inferred: why the payload disagrees. It is enough to know which
    /// source matched reality.
    public static func claude(payload: String?, transcript: String?) -> String? {
        guard let transcript = normalized(transcript) else { return normalized(payload) }
        guard let payload = normalized(payload) else { return transcript }
        return ModelName.sameBaseModel(payload, transcript) ? payload : transcript
    }

    /// Codex's sqlite store is a genuine second source, but it's a cache
    /// read when the popover opens. A hook event landing after that read is
    /// the newer observation — the helper overwrites `model` on every event
    /// that carries one — so the cache can't simply outrank the snapshot.
    public static func codex(
        payload: String?,
        cached: String?,
        cacheReadAt: Date?,
        snapshotUpdatedAt: Date
    ) -> String? {
        guard let cached = normalized(cached) else { return normalized(payload) }
        guard let payload = normalized(payload) else { return cached }
        return (cacheReadAt ?? .distantPast) >= snapshotUpdatedAt ? cached : payload
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
