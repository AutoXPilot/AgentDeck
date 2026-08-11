import Foundation

/// Pure row-arrangement logic for the popover's frozen-order behavior,
/// extracted from the app target so it's testable — it runs on every
/// reload while the popover is open.
public enum RowOrdering {
    /// First occurrence of each key wins. SwiftUI's ForEach renders a
    /// duplicate key as a repeated row rather than failing, so this is
    /// cheaper than diagnosing it later.
    public static func deduplicated(_ snapshots: [SessionSnapshot]) -> [SessionSnapshot] {
        var seen = Set<String>()
        return snapshots.filter { seen.insert($0.key).inserted }
    }

    /// Arranges `sorted` to follow `frozenOrder` where keys overlap; rows
    /// whose keys vanished are dropped, new rows append in sorted position.
    /// Returns the rows plus the updated frozen order (new rows joined).
    /// Tolerates duplicate keys in `sorted` (duplicate snapshot files must
    /// never crash the app — first one wins).
    public static func arrange(
        sorted: [SessionSnapshot], frozenOrder: [String]?
    ) -> (rows: [SessionSnapshot], frozenOrder: [String]) {
        var byKey: [String: SessionSnapshot] = [:]
        for snapshot in sorted where byKey[snapshot.key] == nil {
            byKey[snapshot.key] = snapshot
        }
        var rows: [SessionSnapshot] = []
        for key in frozenOrder ?? [] {
            if let snapshot = byKey.removeValue(forKey: key) {
                rows.append(snapshot)
            }
        }
        for snapshot in sorted {
            if byKey.removeValue(forKey: snapshot.key) != nil {
                rows.append(snapshot)
            }
        }
        return (rows, rows.map(\.key))
    }
}
