import Foundation

/// Codex records session names (set by its `/rename`) in an append-only
/// JSONL index keyed by the same session id its hooks report. Codex never
/// pushes that name into the terminal title, so this file is the only way
/// to show a renamed Codex session by name.
public enum CodexSessionIndex {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    }

    /// session id → thread name. Append-only log: later entries win.
    public static func parse(_ contents: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any],
                  let id = dict["id"] as? String, !id.isEmpty,
                  let name = dict["thread_name"] as? String, !name.isEmpty
            else { continue }
            names[id] = name
        }
        return names
    }

    public static func load(from url: URL = CodexSessionIndex.defaultURL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(contents)
    }
}
