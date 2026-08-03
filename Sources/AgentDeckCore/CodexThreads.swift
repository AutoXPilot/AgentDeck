import Foundation

/// Codex keeps per-thread metadata in a SQLite DB, keyed by the same thread
/// id its hooks report: model, reasoning effort, cumulative tokens, git
/// branch, sandbox policy and approval mode. Read strictly read-only.
public struct CodexThread: Equatable, Sendable {
    public var id: String
    public var title: String?
    public var model: String?
    public var effort: String?
    public var tokensUsed: Int?
    public var gitBranch: String?
    public var approvalMode: String?
    public var sandboxPolicy: String?

    /// Codex auto-generates `title` from the first user message when the
    /// thread was never renamed, so it can be an entire prompt. Anything
    /// this long is content, not a label — don't display it.
    public static let maxSensibleTitleLength = 60

    public var displayTitle: String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= Self.maxSensibleTitleLength,
              !title.contains("\n")
        else { return nil }
        return title
    }

    /// Codex acting without asking: no sandbox and approvals off.
    public var isUnsupervised: Bool {
        let noSandbox = (sandboxPolicy ?? "").contains("\"disabled\"")
        return noSandbox || approvalMode == "never"
    }
}

public enum CodexThreads {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    }

    static let query = """
        select id, title, model, reasoning_effort, tokens_used, git_branch, \
        approval_mode, sandbox_policy from threads
        """

    /// Parses `sqlite3 -separator` output. One row per line, NULLs empty.
    public static func parse(_ output: String, separator: String = "\u{1}") -> [String: CodexThread] {
        var threads: [String: CodexThread] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.components(separatedBy: separator)
            guard cols.count >= 8, !cols[0].isEmpty else { continue }
            func value(_ i: Int) -> String? { cols[i].isEmpty ? nil : cols[i] }
            threads[cols[0]] = CodexThread(
                id: cols[0],
                title: value(1),
                model: value(2),
                effort: value(3),
                tokensUsed: value(4).flatMap { Int($0) },
                gitBranch: value(5),
                approvalMode: value(6),
                sandboxPolicy: value(7)
            )
        }
        return threads
    }

    /// Runs sqlite3 in read-only mode. The DB is in WAL mode and owned by a
    /// live Codex process, so failure is expected and always non-fatal —
    /// callers keep whatever they had.
    public static func load(from url: URL = CodexThreads.defaultURL) -> [String: CodexThread] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-separator", "\u{1}", url.path, query,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
