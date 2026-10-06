import Foundation

/// Claude stamps the model on every assistant message in a session's
/// transcript. That record turns out to be a better answer to "what is this
/// session running" than the hook payload — see `ModelSource.claude` for the
/// evidence and the trade-off.
public enum ClaudeTranscript {
    public static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Claude derives the directory name from the working directory, but the
    /// rule isn't documented (observed: `/` and `.` both become `-`), so the
    /// derived name is only a fast path — if it misses, every project
    /// directory is checked for the file, which is a handful of stats.
    public static func url(
        sessionId: String,
        projectPath: String,
        projectsDirectory: URL = defaultProjectsDirectory,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !sessionId.isEmpty, !sessionId.contains("/") else { return nil }
        let file = "\(sessionId).jsonl"
        if !projectPath.isEmpty {
            let direct = projectsDirectory
                .appendingPathComponent(slug(for: projectPath))
                .appendingPathComponent(file)
            if fileManager.fileExists(atPath: direct.path) { return direct }
        }
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        ) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func slug(for projectPath: String) -> String {
        String(projectPath.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// mtime+size, so an unchanged (often multi-megabyte) transcript is
    /// never re-read.
    public static func fingerprint(
        of url: URL, fileManager: FileManager = .default
    ) -> String? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return "\(mtime)-\(size)"
    }

    public struct Reading: Sendable, Equatable {
        public let model: String
        /// Claude's own word for how the session was launched. "bg" is a
        /// daemonized background session started from a slash command: it
        /// has no terminal and no window, so there is nothing to focus.
        /// Absent on ordinary interactive sessions.
        public let sessionKind: String?

        public init(model: String, sessionKind: String?) {
            self.model = model
            self.sessionKind = sessionKind
        }
    }

    public static func latestModel(at url: URL, tailBytes: Int = 512 * 1024) -> String? {
        latest(at: url, tailBytes: tailBytes)?.model
    }

    /// The most recent main-thread assistant message's model, and the kind
    /// of session that produced it — both read off the same entry, so this
    /// costs one backward scan rather than two.
    ///
    /// Transcripts reach megabytes, so only the tail is read and scanned
    /// backwards; a session whose last assistant turn predates that window
    /// reports nothing rather than dragging the whole file through JSON.
    public static func latest(at url: URL, tailBytes: Int = 512 * 1024) -> Reading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(
            separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true
        )
        // starting mid-file leaves a truncated first line
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        let needle = Data("\"model\"".utf8)
        for line in lines.reversed() {
            // most lines are user turns and tool results — reject without
            // parsing, and never substring-match the value itself: a
            // transcript that *discusses* model ids would match
            guard line.range(of: needle) != nil else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any] else { continue }
            // a subagent's model isn't the session's model
            if object["isSidechain"] as? Bool == true { continue }
            guard let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String else { continue }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            // "<synthetic>" marks a locally generated turn, not an inference
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }
            let kind = (object["sessionKind"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return Reading(model: trimmed, sessionKind: kind)
        }
        return nil
    }
}
