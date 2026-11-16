import Foundation
import Testing
@testable import AgentDeckCore

private func uuid(_ n: Int) -> String { String(format: "%08d-0000-4000-8000-000000000000", n) }

private func placed(_ n: Int, window: String? = nil, tab: Int? = nil,
                    seen: Date = .distantPast) -> WorkspaceEntry {
    WorkspaceEntry(provider: .claude, sessionId: uuid(n), cwd: "/tmp", lastSeen: seen,
                   window: window, tab: tab)
}

struct ITermRunTests {
    @Test func aWindowKeyNamesTheBootAndTheITermRun() throws {
        let launched = Date(timeIntervalSince1970: 1_790_000_000)
        let run = ITermRun(pid: 812, launched: launched)
        #expect(run.windowKey(bootID: "B", window: "109") == "B:812:1790000000:109")
        // the same window id in another run, or another boot, is another window
        #expect(run.windowKey(bootID: "B", window: "109")
                != ITermRun(pid: 812, launched: launched + 60).windowKey(bootID: "B", window: "109"))
        #expect(run.windowKey(bootID: "B", window: "109") != run.windowKey(bootID: "C", window: "109"))
        let place = try #require(ITermFocus.Place(window: "109", tab: 3))
        let places = run.places(["G": place], bootID: "B")
        #expect(places["G"]?.window == "B:812:1790000000:109")
        #expect(places["G"]?.tab == 3)
    }
}

struct ListingScheduleTests {
    // the schedule is mutated by each call, so record the answers, then check
    @Test func requestsDuringAListingBecomeOneFollowUp() {
        var s = ListingSchedule()
        var answers: [Bool] = []
        answers.append(s.request())
        answers.append(s.request())
        answers.append(s.request())
        answers.append(s.finished())   // one follow-up for both
        answers.append(s.finished())   // and no more
        answers.append(s.request())    // idle again
        #expect(answers == [true, false, false, true, false, true])
    }

    @Test func aFinishedListingWithNothingQueuedLeavesNothingPending() {
        var s = ListingSchedule()
        let started = s.request()
        let followUp = s.finished()
        #expect(started && !followUp)
        #expect(!s.inFlight && !s.pending)
    }

    @Test func onlyAGainedSessionAsksForAListing() {
        var s = ListingSchedule()
        var answers: [Bool] = []
        answers.append(s.liveKeysChanged(["a"]))
        _ = s.finished()
        answers.append(s.liveKeysChanged(["a"]))       // the reload a listing causes
        answers.append(s.liveKeysChanged([]))          // a session ending
        answers.append(s.liveKeysChanged(["b"]))
        answers.append(s.liveKeysChanged(["b", "c"]))  // while one runs, a gain only queues
        #expect(answers == [true, false, false, true, false])
        #expect(s.pending)
    }
}

struct PlaceCodingTests {
    private func decode(_ json: String) throws -> WorkspaceEntry {
        try JSONDecoder().decode(WorkspaceEntry.self, from: Data(json.utf8))
    }
    private let base = #""provider":"claude","sessionId":"00000001-0000-4000-8000-000000000000","cwd":"/tmp","lastSeen":0"#

    @Test func aPlaceRoundTripsAndAnOldEntryLoadsWithout() throws {
        let entry = placed(1, window: "B:1:2:109", tab: 4)
        let back = try JSONDecoder().decode(WorkspaceEntry.self, from: JSONEncoder().encode(entry))
        #expect(back == entry)
        let old = try decode("{\(base)}")
        #expect(old.window == nil && old.tab == nil)
        #expect(try decode("{\(base),\"futureField\":true}").sessionId == uuid(1))
    }

    @Test func aDamagedPlaceCostsThePlaceNotTheEntry() throws {
        for bad in [#""window":109,"tab":2"#, #""window":"w","tab":"2""#,
                    #""window":"","tab":2"#, #""window":"w","tab":0"#,
                    #""window":"w""#, #""tab":2"#] {
            let entry = try decode("{\(base),\(bad)}")
            #expect(entry.window == nil && entry.tab == nil, "\(bad)")
            #expect(WorkspaceRestore.commandLine(for: entry) != nil, "still restorable: \(bad)")
        }
        // the rest stays as strict as before
        #expect(throws: (any Error).self) { try decode(#"{"provider":"claude","cwd":"/tmp","lastSeen":0}"#) }
    }

    @Test func placesSurviveTheRealStores() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try store.record(live: [placed(1, window: "W", tab: 2)], bootID: "B", now: t0)
        #expect(WorkspaceStore(directory: dir).loadGeneration(bootID: "B")?.entries.first?.tab == 2)
        let name = try store.save(NamedWorkspace(name: "two", savedAt: t0,
                                                 entries: [placed(1, window: "W", tab: 2)]))
        let named = try #require(WorkspaceStore(directory: dir).named().first { $0.name == name })
        #expect(named.entries.first?.window == "W")
        // a relocation rewrites the folder only
        let updated = try store.updateNamed(id: named.id) { workspace in
            workspace.entries[0].cwd = "/var"
        }
        #expect(updated)
        let moved = try #require(store.named().first { $0.id == named.id })
        #expect(moved.entries.first?.cwd == "/var" && moved.entries.first?.tab == 2)
        // an edit that replaces the entry without a place keeps the stored one
        _ = try store.updateNamed(id: named.id) { workspace in
            workspace.entries[0] = placed(1, seen: t0 + 9)
        }
        #expect(try #require(store.named().first { $0.id == named.id }).entries.first?.window == "W")
        // and one that sets a place sets it
        _ = try store.updateNamed(id: named.id) { workspace in
            workspace.entries[0] = placed(1, window: "X", tab: 7)
        }
        let replaced = try #require(store.named().first { $0.id == named.id }).entries.first
        #expect(replaced?.window == "X" && replaced?.tab == 7)
    }
}

struct PlaceMergeTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aSightingWithoutAPlaceKeepsTheKnownOne() {
        let old = placed(1, window: "W", tab: 3, seen: t0)
        #expect(placed(1, seen: t0 + 1).keepingPlace(of: old).tab == 3)
        #expect(placed(1, window: "X", tab: 1, seen: t0 + 1).keepingPlace(of: old).window == "X",
                "a new place replaces it, window and tab together")
        #expect(placed(1, window: "X", tab: 1).keepingPlace(of: old).tab == 1)
    }

    @Test func mergingTwoCopiesKeepsAPlaceWhicheverIsNewer() {
        func generation(_ e: WorkspaceEntry) -> WorkspaceGeneration {
            WorkspaceGeneration(bootID: "B", updatedAt: t0, entries: [e])
        }
        let withPlace = placed(1, window: "W", tab: 2, seen: t0)
        let newerBare = placed(1, seen: t0 + 5)
        for (a, b) in [(withPlace, newerBare), (newerBare, withPlace)] {
            let m = generation(a).merged(with: generation(b)).entries[0]
            #expect(m.lastSeen == t0 + 5 && m.window == "W" && m.tab == 2)
        }
        // a tie keeps this copy, place and all
        let mine = placed(1, window: "A", tab: 1, seen: t0)
        let theirs = placed(1, window: "B", tab: 9, seen: t0)
        let tie = generation(mine).merged(with: generation(theirs)).entries[0]
        #expect(tie.window == "A" && tie.tab == 1)
    }

    @Test func recordingWithoutAPlaceNeitherErasesItNorRewritesTheFile() throws {
        let store = WorkspaceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true))
        try store.record(live: [placed(1, window: "W", tab: 2)], bootID: "B", now: t0)
        #expect(try store.record(live: [placed(1)], bootID: "B", now: t0 + 1) == false,
                "nothing changed but the listing's freshness")
        #expect(store.loadGeneration(bootID: "B")?.entries.first?.tab == 2)
        #expect(try store.record(live: [placed(1, window: "W", tab: 5)], bootID: "B", now: t0 + 2))
        #expect(store.loadGeneration(bootID: "B")?.entries.first?.tab == 5, "a moved tab is rewritten")
    }
}

struct WindowGroupingTests {
    let facts = WorkspaceRestore.Facts(live: [], inFlight: [], directoryExists: { _ in true },
                                       conversationExists: { _ in true })

    private func order(_ entries: [WorkspaceEntry]) -> [String] {
        WorkspaceRestore.plan(entries, facts: facts).launches.map { String($0.entry.sessionId.prefix(8)) }
    }

    @Test func withNoPlacesTheOrderIsUnchanged() {
        #expect(order([placed(3), placed(1), placed(2)]) == ["00000003", "00000001", "00000002"])
    }

    @Test func windowsAreGroupedInTabOrderWithTheUnplacedLast() {
        let entries = [
            placed(1, window: "A", tab: 2), placed(2), placed(3, window: "B", tab: 1),
            placed(4, window: "A", tab: 1), placed(5, window: "B", tab: 2), placed(6),
        ]
        #expect(order(entries) == ["00000004", "00000001", "00000003", "00000005", "00000002", "00000006"])
    }

    @Test func aWindowWithoutATabIsNoPlaceAndTiesKeepTheirOrder() {
        let entries = [placed(1, window: "A", tab: 2), placed(2, window: "A"),
                       placed(3, window: "A", tab: 1)]
        // a window without a tab isn't a place at all (`setPlace`), so it goes
        // with the unplaced rather than to the end of window A
        #expect(order(entries) == ["00000003", "00000001", "00000002"])
        #expect(order([placed(1, window: "A", tab: 2), placed(2, window: "A", tab: 2),
                       placed(3, window: "A", tab: 1)]) == ["00000003", "00000001", "00000002"],
                "a tie keeps the given order")
    }

    @Test func groupingDoesNotChangeWhichDuplicateIsKept() {
        let upper = WorkspaceEntry(provider: .claude, sessionId: uuid(1).uppercased(), cwd: "/tmp",
                                   lastSeen: .distantPast, window: "B", tab: 1)
        let plan = WorkspaceRestore.plan([placed(1, window: "A", tab: 9), upper], facts: facts)
        #expect(plan.launches.count == 1)
        #expect(plan.launches.first?.entry.window == "A", "the first one, as before")
    }

    @Test func aContinuedConversationKeepsItsPlace() {
        let next = uuid(9)
        var withLink = facts
        withLink.successor = { $0.sessionId == uuid(1) ? next : nil }
        let launch = WorkspaceRestore.plan([placed(1, window: "A", tab: 4)], facts: withLink).launches
        #expect(launch.first?.entry.sessionId == next && launch.first?.entry.tab == 4)
    }
}

struct WindowExecutionTests {
    final class Log: @unchecked Sendable {
        var windows: [String] = []
        var events: [String] = []
        var nextWindow = 100
    }

    private func run(_ entries: [WorkspaceEntry], wanted: @escaping (WorkspaceEntry) -> Bool = { _ in true },
                     reply: @escaping @Sendable (String) -> ITermFocus.ScriptOutcome = { _ in .success("typed 7") },
                     batchSize: Int = 5) -> Log {
        let log = Log()
        let facts = WorkspaceRestore.Facts(live: [], inFlight: [], directoryExists: { _ in true },
                                           conversationExists: { _ in true })
        _ = WorkspaceRestore.execute(
            WorkspaceRestore.plan(entries, facts: facts).launches,
            stillWanted: wanted, batchSize: batchSize, stagger: 0,
            run: { script, args, _ in
                if script == WorkspaceRestore.readyScript { return .success("1") }
                log.windows.append(args[0])
                log.events.append("L")
                if case .success("typed 7") = reply(args[1]) {
                    // a new window gets a new id; a tab reports its window's
                    if args[0].isEmpty { log.nextWindow += 1 }
                    return .success("typed \(args[0].isEmpty ? String(log.nextWindow) : args[0])")
                }
                return reply(args[1])
            },
            awaitBatch: { log.events.append("wait\($0.count)") })
        return log
    }

    @Test func eachWindowGetsANewWindow() {
        let log = run([placed(1, window: "A", tab: 1), placed(2, window: "A", tab: 2),
                       placed(3, window: "B", tab: 1), placed(4, window: "B", tab: 2), placed(5)])
        #expect(log.windows == ["", "101", "", "102", ""])
    }

    @Test func aGroupWhoseFirstLaunchIsSkippedOrUncertainNeverUsesThePreviousWindow() {
        let skipped = run([placed(1, window: "A", tab: 1), placed(2, window: "B", tab: 1),
                           placed(3, window: "B", tab: 2)],
                          wanted: { $0.sessionId != uuid(2) })
        #expect(skipped.windows == ["", ""])
        let uncertain = run([placed(1, window: "A", tab: 1), placed(2, window: "B", tab: 1),
                             placed(3, window: "B", tab: 2)],
                            reply: { $0.contains(uuid(2)) ? .failure("timed out after 15s") : .success("typed 7") })
        #expect(uncertain.windows == ["", "", ""],
                "B's second launch opens the window its first may not have")
    }

    @Test func batchesAreCountedAcrossGroupsAsBefore() {
        let entries = (1...7).map { placed($0, window: $0 <= 3 ? "A" : "B", tab: $0) }
        let log = run(entries, batchSize: 5)
        #expect(log.events.joined(separator: " ") == "L L L L L wait5 L L")
        #expect(log.windows == ["", "101", "101", "", "102", "102", "102"],
                "a boundary inside a batch, and a group spanning two batches")
    }
}
