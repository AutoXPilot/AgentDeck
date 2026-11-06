import Foundation

/// Executables for tests that need a real process with a chosen file name.
///
/// Each one is compiled, because macOS kills a copy of a system binary, and
/// kept for later runs rather than deleted. syspolicyd segfaulted scanning
/// executables these tests had already removed, and repeated crashes left it
/// down for up to 20 minutes at a time, which hung process launches across
/// the machine.
enum ProcessFixtures {
    /// A binary called `name` that sleeps for 30 seconds and ignores its
    /// arguments. Safe to call from tests running in parallel.
    static func sleeper(named name: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agentdeck-test-fixtures")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent(name)
        if fm.isExecutableFile(atPath: binary.path) { return binary }

        // Built under a unique name and moved into place, so a parallel test
        // never runs a half-written file. These two are never executed, so
        // removing them is safe.
        let unique = UUID().uuidString
        let source = dir.appendingPathComponent("\(unique).c")
        let built = dir.appendingPathComponent("\(unique).out")
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: built)
        }
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [source.path, "-o", built.path]
        try cc.run()
        cc.waitUntilExit()
        guard cc.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
        do {
            try fm.moveItem(at: built, to: binary)
        } catch where fm.isExecutableFile(atPath: binary.path) {
            // another test got there first
        }
        return binary
    }
}
