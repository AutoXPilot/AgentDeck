import Testing
@testable import AgentDeckCore

struct AgyTabNamesTests {
    private func t(_ title: String, _ pid: Int32 = 7) -> AgyTabNames.Given { .init(title: title, pid: pid) }

    @Test func aTabIsNamedOnceAndAgainOnlyWhenTheTitleChanges() {
        var names = AgyTabNames()
        #expect(names.due(["P": t("plan the trip")]) == ["P": "plan the trip"])
        names.confirm(pane: "P", as: t("plan the trip"))
        // the tab may since have been renamed by hand: that isn't a reason
        #expect(names.due(["P": t("plan the trip")]).isEmpty)
        #expect(names.due(["P": t("book the hotel")]) == ["P": "book the hotel"])
    }

    @Test func aNewAgyProcessInTheSamePaneIsNamedAgain() {
        // relaunching agy let the shell retitle the tab ("agy")
        var names = AgyTabNames()
        names.confirm(pane: "P", as: t("plan the trip", 7))
        #expect(names.due(["P": t("plan the trip", 8)]) == ["P": "plan the trip"])
    }

    @Test func anUnconfirmedRenameIsTriedAgain() {
        let names = AgyTabNames()
        #expect(names.due(["P": t("x")]) == ["P": "x"])
        #expect(names.due(["P": t("x")]) == ["P": "x"], "nothing was confirmed")
    }

    @Test func renamesAreForgottenWhenTheProcessEndsNotWhenAListingIsPartial() {
        var names = AgyTabNames()
        names.confirm(pane: "P", as: t("x", 7))
        names.confirm(pane: "Q", as: t("y", 8))
        names.keepOnly(pids: [8])
        #expect(names.given == ["Q": t("y", 8)])
        // the pane listing doesn't enter into it at all
        names.keepOnly(pids: [8])
        #expect(names.due(["Q": t("y", 8)]).isEmpty)
    }

    @Test func anEmptyTitleNamesNothing() {
        #expect(AgyTabNames().due(["P": t("")]).isEmpty)
    }

    @Test func theTitleIsAnArgumentNeverPartOfTheScript() {
        // a title is free text: spliced into the source it could run code
        #expect(ITermFocus.renameScript.contains("set newName to item 2 of argv"))
    }

    @Test func theRenameClearsTheNameFirst() {
        // iTerm ignores a rename to the name it already holds, even after
        // the shell has retitled the tab (observed, iTerm 3.7.0)
        let script = ITermFocus.renameScript
        let clear = try? #require(script.range(of: "set name of s to \"\""))
        let set = try? #require(script.range(of: "set name of s to newName"))
        #expect(clear != nil && set != nil && clear!.lowerBound < set!.lowerBound)
    }
}
