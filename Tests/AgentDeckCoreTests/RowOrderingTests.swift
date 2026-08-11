import Foundation
import Testing
@testable import AgentDeckCore

struct RowOrderingTests {
    func snap(_ id: String, _ state: SessionState = .working) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: id, projectPath: "/p/\(id)",
            state: state, event: "x"
        )
    }

    @Test func nilFrozenOrderYieldsSortedAndFreezesIt() {
        let sorted = [snap("a"), snap("b"), snap("c")]
        let result = RowOrdering.arrange(sorted: sorted, frozenOrder: nil)
        #expect(result.rows.map(\.sessionId) == ["a", "b", "c"])
        #expect(result.frozenOrder == ["claude-a", "claude-b", "claude-c"])
    }

    @Test func frozenOrderWinsOverNewSortPosition() {
        // b's state changed so a fresh sort would move it — order must hold
        let sorted = [snap("b", .waiting), snap("a", .done), snap("c", .ready)]
        let result = RowOrdering.arrange(
            sorted: sorted, frozenOrder: ["claude-a", "claude-b", "claude-c"]
        )
        #expect(result.rows.map(\.sessionId) == ["a", "b", "c"])
    }

    @Test func vanishedKeysDropAndNewRowsAppendAndJoinFreeze() {
        let sorted = [snap("new", .waiting), snap("b")]
        let result = RowOrdering.arrange(
            sorted: sorted, frozenOrder: ["claude-a", "claude-b"]  // a is gone
        )
        #expect(result.rows.map(\.sessionId) == ["b", "new"])
        #expect(result.frozenOrder == ["claude-b", "claude-new"])
    }

    @Test func duplicateKeysNeverCrashFirstWins() {
        // regression: duplicate snapshot files (e.g. Finder "Duplicate")
        // decode to the same key; Dictionary(uniqueKeysWithValues:) here
        // used to trap and kill the app on every popover reload
        let a1 = snap("a", .waiting)
        let a2 = snap("a", .done)
        let result = RowOrdering.arrange(
            sorted: [a1, a2, snap("b")], frozenOrder: ["claude-a", "claude-b"]
        )
        #expect(result.rows.map(\.key) == ["claude-a", "claude-b"])
        #expect(result.rows[0].state == .waiting, "first occurrence wins")
    }

    @Test func deduplicatedKeepsFirstOccurrenceAndOrder() {
        let rows = [snap("a", .waiting), snap("b"), snap("a", .done), snap("c")]
        let unique = RowOrdering.deduplicated(rows)
        #expect(unique.map(\.sessionId) == ["a", "b", "c"])
        #expect(unique[0].state == .waiting)
        #expect(RowOrdering.deduplicated([]).isEmpty)
    }

    @Test func emptyInputs() {
        let empty = RowOrdering.arrange(sorted: [], frozenOrder: ["claude-x"])
        #expect(empty.rows.isEmpty)
        #expect(empty.frozenOrder.isEmpty)
    }
}
