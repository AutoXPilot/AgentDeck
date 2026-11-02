import Foundation

/// Codex shows some prompts that fire no hook: an MCP server's elicitation
/// (the browser tool's "Allow Browser use to access …?") leaves the turn
/// waiting on you while hooks still say it's working. The rollout then
/// ends in a tool call with no output and nothing written after it. A
/// normal tool call finishes in seconds, so one stuck that way for
/// `threshold` reads as "may need you".
///
/// Shell commands are excluded: a long build looks the same, and Codex's
/// own approval prompts for them fire the PermissionRequest hook anyway.
/// Only record types, call ids, tool names and timestamps are read; the
/// lines are parsed in memory and nothing is kept.
public enum CodexStall {
    public static let threshold: TimeInterval = 120
    /// Bookkeeping Codex writes right after a call (token usage) doesn't
    /// count as the session moving on.
    static let settleWindow: TimeInterval = 10

    /// Tools that legitimately run long: shell commands, and waiting on
    /// sub-agents or a timer (`wait`, `sleep`).
    static let shellTools: Set<String> = [
        "exec", "shell", "local_shell", "exec_command", "write_stdin", "apply_patch",
        "wait", "sleep",
    ]

    struct Tail {
        /// The newest tool call without an output, if it's still the
        /// newest meaningful record.
        var pendingSince: Date?
        var lastRecordAt: Date?
    }

    static func scan(_ data: Data, isWholeFile: Bool) -> Tail {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        if data.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        var tail = Tail()
        var pending: (id: String, at: Date)?
        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any],
                  let stamp = (record["timestamp"] as? String).flatMap({
                      SnapshotStore.isoFractional.date(from: $0) ?? SnapshotStore.isoPlain.date(from: $0)
                  })
            else { continue }
            tail.lastRecordAt = stamp
            let payload = record["payload"] as? [String: Any]
            let kind = payload?["type"] as? String
            switch (record["type"] as? String, kind) {
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let name = payload?["name"] as? String ?? ""
                if let id = payload?["call_id"] as? String, !shellTools.contains(name) {
                    pending = (id, stamp)
                } else {
                    pending = nil
                }
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                if payload?["call_id"] as? String == pending?.id { pending = nil }
            case ("response_item", _), ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                // the model said something or the turn ended: not stuck
                pending = nil
            default:
                break
            }
        }
        tail.pendingSince = pending?.at
        return tail
    }

    /// When the thread started waiting on something no hook reports, or nil.
    public static func stalledSince(in data: Data, isWholeFile: Bool, now: Date,
                                    threshold: TimeInterval = CodexStall.threshold) -> Date? {
        let tail = scan(data, isWholeFile: isWholeFile)
        guard let since = tail.pendingSince, let last = tail.lastRecordAt,
              last.timeIntervalSince(since) <= settleWindow,
              now.timeIntervalSince(last) >= threshold
        else { return nil }
        return since
    }

    public static func stalledSince(file url: URL, now: Date,
                                    threshold: TimeInterval = CodexStall.threshold) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > 256 * 1024 ? size - 256 * 1024 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start))
        else { return nil }
        return stalledSince(in: data, isWholeFile: start == 0, now: now, threshold: threshold)
    }

    /// The rollout for each wanted thread id: rollout file names end in
    /// the thread id.
    public static func rollouts(for threadIds: Set<String>,
                                in directory: URL = CodexUsage.defaultSessionsDirectory) -> [String: URL] {
        guard !threadIds.isEmpty else { return [:] }
        let wanted = Set(threadIds.map { $0.lowercased() })
        var found: [String: URL] = [:]
        for file in CodexUsage.rollouts(in: directory) {
            let name = (file.path as NSString).lastPathComponent.lowercased()
            guard name.hasSuffix(".jsonl") else { continue }
            let stem = String(name.dropLast(6))
            if let id = wanted.first(where: { stem.hasSuffix($0) }), found[id] == nil {
                found[id] = URL(fileURLWithPath: file.path)
            }
        }
        return found
    }
}
