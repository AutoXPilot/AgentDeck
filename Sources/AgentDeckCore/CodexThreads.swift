import Foundation

/// Codex keeps per-thread metadata in a SQLite DB, keyed by the same thread
/// id its hooks report: model, reasoning effort, cumulative tokens, git
/// branch, sandbox policy and approval mode. Read strictly read-only.
/// The `threads.title` column is deliberately **not** read.
///
/// Codex fills it with the first user message whenever a thread was never
/// renamed, and nothing in the schema distinguishes the two cases. This
/// code used to read it and show anything under 60 characters, on the
/// theory that short text is a label — but length is not provenance, and
/// "Help me research this problem" is a prompt at 29 characters. It was
/// reaching row titles and notification bodies, against a README promising
/// metadata only.
///
/// A renamed thread's name comes from `CodexSessionIndex` instead, where
/// `thread_name` exists only because someone typed `/rename`. Not reading
/// the column makes "conversation content is never retained" true by
/// construction rather than by a filter someone has to keep correct.
public struct CodexThread: Equatable, Sendable {
    public var id: String
    public var model: String?
    public var effort: String?
    public var tokensUsed: Int?
    public var gitBranch: String?
    public var approvalMode: String?
    public var sandboxPolicy: String?

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

    /// `title` is not selected — see the note on `CodexThread`. Keeping it
    /// out of the query means prompt text never enters this process.
    static let query = """
        select id, model, reasoning_effort, tokens_used, git_branch, \
        approval_mode, sandbox_policy from threads
        """

    /// Parses `sqlite3 -separator` output. One row per line, NULLs empty.
    public static func parse(_ output: String, separator: String = "\u{1}") -> [String: CodexThread] {
        var threads: [String: CodexThread] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.components(separatedBy: separator)
            // Exactly the shape `query` asks for. A looser `>=` let a row
            // with an extra column shift its contents one place left,
            // which is how a thread title could land in `model` — drop the
            // row instead of trusting a misaligned one.
            guard cols.count == 7, !cols[0].isEmpty else { continue }
            func value(_ i: Int) -> String? { cols[i].isEmpty ? nil : cols[i] }
            threads[cols[0]] = CodexThread(
                id: cols[0],
                model: value(1),
                effort: value(2),
                tokensUsed: value(3).flatMap { Int($0) },
                gitBranch: value(4),
                approvalMode: value(5),
                sandboxPolicy: value(6)
            )
        }
        return threads
    }

    /// Runs sqlite3 in read-only mode. The DB is in WAL mode and owned by a
    /// live Codex process, so failure is expected and always non-fatal —
    /// callers keep whatever they had.
    public static func load(from url: URL = CodexThreads.defaultURL) -> [String: CodexThread] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        // Bounded + concurrently drained: a big threads table used to be able
        // to fill the pipe and deadlock the drain-after-wait code.
        let result = BoundedSubprocess.run(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", "-separator", "\u{1}", url.path, query],
            timeout: 5
        )
        guard result.status == 0, !result.timedOut else { return [:] }
        return parse(String(decoding: result.output, as: UTF8.self))
    }
}
