import Foundation

/// Session id → the agent process started with that id in its arguments
/// (`agy --conversation <id>`, `claude --resume <id>`): how a session that
/// no hook has reported yet, such as one just restored, is tied to a
/// process and so to its pane.
///
/// Scanning every process is the costly part, so it runs only for ids not
/// yet tried. An id the scan didn't find isn't scanned again while it stays
/// wanted: a session started without its id on the command line never
/// will be found that way.
public struct ArgumentPids: Sendable, Equatable {
    public private(set) var pids: [String: pid_t] = [:]
    private var misses: Set<String> = []

    public init() {}

    /// `stillValid` re-checks a cached pid (pids are reused); `scan` finds
    /// pids for the ids given.
    public mutating func update(
        wanted: Set<String>,
        stillValid: (String, pid_t) -> Bool,
        scan: (Set<String>) -> [String: pid_t]
    ) {
        pids = pids.filter { wanted.contains($0.key) && stillValid($0.key, $0.value) }
        misses.formIntersection(wanted)
        let missing = wanted.subtracting(pids.keys).subtracting(misses)
        guard !missing.isEmpty else { return }
        let found = scan(missing).filter { missing.contains($0.key) }
        pids.merge(found) { _, new in new }
        misses.formUnion(missing.subtracting(found.keys))
    }
}
