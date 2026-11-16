import Foundation

/// One run of iTerm: a window id means something only within it, since
/// ids restart when iTerm does and a pid can recur after a reboot.
public struct ITermRun: Equatable, Sendable {
    public var pid: Int32
    public var launched: Date?

    public init(pid: Int32, launched: Date?) {
        self.pid = pid
        self.launched = launched
    }

    /// The key a workspace entry records for its window: which boot, which
    /// iTerm run, which window. Only compared for equality, never used to
    /// address a window.
    public func windowKey(bootID: String, window: String) -> String {
        let launch = launched.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        return "\(bootID):\(pid):\(launch):\(window)"
    }

    /// GUID → the recorded place (window key and tab) for every pane listed.
    public func places(_ listing: [String: ITermFocus.Place],
                       bootID: String) -> [String: (window: String, tab: Int)] {
        listing.mapValues { (windowKey(bootID: bootID, window: $0.window), $0.tab) }
    }
}

/// When to list iTerm's panes again. At most one listing runs; a request
/// made while one runs leaves one follow-up, however many requests arrive.
/// A failed listing isn't retried by itself: the next request is the retry.
public struct ListingSchedule: Equatable, Sendable {
    public private(set) var inFlight = false
    public private(set) var pending = false
    private var knownLive: Set<String> = []

    public init() {}

    /// Returns whether to start a listing now.
    public mutating func request() -> Bool {
        if inFlight {
            pending = true
            return false
        }
        inFlight = true
        return true
    }

    /// A session that wasn't running before needs its pane's place: request
    /// a listing. The baseline moves first, so the reload a listing causes
    /// can't request another for the same sessions.
    public mutating func liveKeysChanged(_ live: Set<String>) -> Bool {
        let gained = !live.subtracting(knownLive).isEmpty
        knownLive = live
        return gained && request()
    }

    /// Returns whether to start the follow-up listing now.
    public mutating func finished() -> Bool {
        inFlight = false
        guard pending else { return false }
        pending = false
        inFlight = true
        return true
    }
}
