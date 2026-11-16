import Foundation
import Testing
@testable import AgentDeckCore

struct SessionFilterTests {
    func snap(
        _ provider: Provider, _ id: String, _ state: SessionState = .working,
        updated: Date = Date(timeIntervalSince1970: 1000), host: String? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            provider: provider, sessionId: id, projectPath: "/p/\(id)",
            state: state, event: "x", updatedAt: updated, hostKind: host
        )
    }

    let titles = ["c1": "webapp fix", "x1": "webapp api", "a1": "docs", "c2": "infra"]
    func title(_ s: SessionSnapshot) -> String { titles[s.sessionId] ?? s.sessionId }

    var rows: [SessionSnapshot] {
        [snap(.claude, "c1"), snap(.codex, "x1"), snap(.antigravity, "a1"), snap(.claude, "c2")]
    }

    @Test func hidingProvidersDropsTheirRowsInOrder() {
        #expect(SessionFilter.visible(rows, hidden: [.codex]).map(\.sessionId) == ["c1", "a1", "c2"])
        #expect(SessionFilter.visible(rows, hidden: [.codex, .claude]).map(\.sessionId) == ["a1"])
        #expect(SessionFilter.visible(rows, hidden: []).map(\.sessionId) == ["c1", "x1", "a1", "c2"])
        #expect(SessionFilter.visible(rows, hidden: Set(Provider.allCases)).isEmpty)
    }

    @Test func appHostedRowsGoWithTheirProvider() {
        let hosted = [snap(.claude, "desk", host: "app"), snap(.codex, "gpt", host: "app")]
        #expect(SessionFilter.visible(hosted, hidden: [.claude]).map(\.sessionId) == ["gpt"])
        #expect(SessionFilter.visible(hosted, hidden: [.codex]).map(\.sessionId) == ["desk"])
    }

    @Test func textAndProviderFiltersCombine() {
        let matches = SessionFilter.textMatches(rows, query: "  WebApp ", title: title)
        #expect(matches.map(\.sessionId) == ["c1", "x1"])
        #expect(SessionFilter.visible(matches, hidden: [.codex]).map(\.sessionId) == ["c1"])
        // the path matches too
        #expect(SessionFilter.textMatches(rows, query: "/p/a1", title: title).map(\.sessionId) == ["a1"])
        #expect(SessionFilter.textMatches(rows, query: " ", title: title).count == 4)
    }

    @Test func countsFollowTheQuery() {
        let all = SessionFilter.counts(rows)
        #expect(all == [.claude: 2, .codex: 1, .antigravity: 1])
        let matches = SessionFilter.textMatches(rows, query: "webapp", title: title)
        #expect(SessionFilter.counts(matches) == [.claude: 1, .codex: 1, .antigravity: 0])
    }

    @Test func dotFollowsTheBadgeRuleForHiddenProvidersOnly() {
        let event = Date(timeIntervalSince1970: 1000)
        let waiting = snap(.codex, "w", .waiting, updated: event)
        #expect(SessionFilter.hiddenNeedingYou([waiting], hidden: [.codex], acks: [:]) == [.codex])
        #expect(SessionFilter.hiddenNeedingYou([waiting], hidden: [.claude], acks: [:]).isEmpty,
                "a shown provider never gets the dot")
        #expect(SessionFilter.hiddenNeedingYou(
            [waiting], hidden: [.codex], acks: [waiting.key: event.addingTimeInterval(1)]).isEmpty,
            "acknowledged")
        #expect(SessionFilter.hiddenNeedingYou(
            [waiting], hidden: [.codex], acks: [waiting.key: event.addingTimeInterval(-1)]) == [.codex],
            "a wait newer than its acknowledgement")
        #expect(SessionFilter.hiddenNeedingYou(
            [snap(.antigravity, "e", .error)], hidden: [.antigravity], acks: [:]) == [.antigravity])
        #expect(SessionFilter.hiddenNeedingYou(
            [snap(.codex, "d", .done), snap(.codex, "r", .working)], hidden: [.codex], acks: [:]).isEmpty,
            "done isn't in the badge, so no dot")
    }

    @Test func storedFormRoundTripsAndDropsUnknowns() {
        #expect(SessionFilter.encode([.antigravity, .claude]) == ["claude", "antigravity"])
        for set in [Set<Provider>(), [.codex], Set(Provider.allCases)] {
            #expect(SessionFilter.decode(SessionFilter.encode(set)) == set)
        }
        #expect(SessionFilter.decode(nil).isEmpty)
        #expect(SessionFilter.decode("codex").isEmpty)
        #expect(SessionFilter.decode(["codex", "gemini", "codex"]) == [.codex])
        #expect(SessionFilter.decode(["codex", 3] as [Any]).isEmpty, "a damaged list hides nothing")
    }
}
