import Testing
@testable import AgentDeckCore

struct AgyTabNamesTests {
    @Test func aTabIsNamedOnceAndAgainOnlyWhenTheTitleChanges() {
        var names = AgyTabNames()
        #expect(names.due(titleByPane: ["P": "plan the trip"]) == ["P": "plan the trip"])
        names.confirm(pane: "P", title: "plan the trip")
        // the tab may since have been renamed by hand: that isn't a reason
        #expect(names.due(titleByPane: ["P": "plan the trip"]).isEmpty)
        #expect(names.due(titleByPane: ["P": "book the hotel"]) == ["P": "book the hotel"])
    }

    @Test func anUnconfirmedRenameIsTriedAgain() {
        let names = AgyTabNames()
        #expect(names.due(titleByPane: ["P": "t"]) == ["P": "t"])
        #expect(names.due(titleByPane: ["P": "t"]) == ["P": "t"], "nothing was confirmed")
    }

    @Test func aClosedPaneIsForgottenSoItsReuseIsNamedAfresh() {
        var names = AgyTabNames()
        names.confirm(pane: "P", title: "t")
        names.confirm(pane: "Q", title: "u")
        names.keepOnly(["Q"])
        #expect(names.given == ["Q": "u"])
        #expect(names.due(titleByPane: ["P": "t"]) == ["P": "t"])
    }

    @Test func anEmptyTitleNamesNothing() {
        #expect(AgyTabNames().due(titleByPane: ["P": ""]).isEmpty)
    }

    @Test func theTitleIsAnArgumentNeverPartOfTheScript() {
        // a title is free text: spliced into the source it could run code
        #expect(ITermFocus.renameScript.contains("set newName to item 2 of argv"))
    }
}
