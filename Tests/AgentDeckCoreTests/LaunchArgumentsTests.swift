import Testing
@testable import AgentDeckCore

struct LaunchArgumentsTests {
    @Test func noArgumentsRunsTheApp() {
        #expect(LaunchArguments.parse([]) == .runApp)
    }

    @Test func versionAndHelpAreHandled() {
        // --version was documented in the README and never implemented; it
        // fell through and launched the menu-bar app instead of printing.
        #expect(LaunchArguments.parse(["--version"]) == .printVersion)
        #expect(LaunchArguments.parse(["-v"]) == .printVersion)
        #expect(LaunchArguments.parse(["--help"]) == .printHelp)
        #expect(LaunchArguments.parse(["-h"]) == .printHelp)
        #expect(LaunchArguments.helpText(version: "9.9.9").contains("9.9.9"))
    }

    @Test func anUnknownLongOptionIsAnErrorNotASecondInstance() {
        // The real hazard: a typo used to start a SECOND menu-bar instance
        // racing the live one over the same state files.
        guard case .usageError(let message) = LaunchArguments.parse(["--versoin"])
        else { return #expect(Bool(false), "expected a usage error") }
        #expect(message.contains("--versoin"))
        #expect(LaunchArguments.parse(["--render-popovr", "x.png"]) != .runApp)
    }

    @Test func systemSuppliedArgumentsStillLaunchTheApp() {
        // LaunchServices and Xcode pass their own; rejecting these would
        // break launching from Finder.
        #expect(LaunchArguments.parse(["-psn_0_1234567"]) == .runApp)
        #expect(LaunchArguments.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == .runApp)
    }

    @Test func renderPopoverNeedsAnOutputPath() {
        #expect(LaunchArguments.parse(["--render-popover", "/tmp/out.png"])
                == .renderPopover(path: "/tmp/out.png"))
        guard case .usageError = LaunchArguments.parse(["--render-popover"])
        else { return #expect(Bool(false), "a missing path must not render") }
        guard case .usageError = LaunchArguments.parse(["--render-popover", ""])
        else { return #expect(Bool(false), "an empty path must not render") }
    }
}
