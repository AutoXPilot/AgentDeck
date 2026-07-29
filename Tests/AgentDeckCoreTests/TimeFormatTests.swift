import Foundation
import Testing
@testable import AgentDeckCore

struct TimeFormatTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)

    func age(_ seconds: TimeInterval) -> String {
        TimeFormat.compactAge(of: now.addingTimeInterval(-seconds), now: now)
    }

    @Test func brackets() {
        #expect(age(0) == "now")
        #expect(age(59) == "now")
        #expect(age(60) == "1m")
        #expect(age(59 * 60) == "59m")
        #expect(age(3600) == "1h")
        #expect(age(23 * 3600 + 1800) == "23h")
        #expect(age(86400) == "1d")
        #expect(age(3 * 86400) == "3d")
    }

    @Test func futureDatesClampToNow() {
        #expect(TimeFormat.compactAge(of: now.addingTimeInterval(120), now: now) == "now")
    }
}
