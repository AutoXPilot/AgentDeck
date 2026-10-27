import CryptoKit
import Foundation

/// Keeps the stable helper (the binary hooks actually invoke, under
/// Application Support) in lockstep with the helper shipped next to the app.
/// Without this, upgrading the app leaves hooks running an old helper
/// indefinitely — and health that only checks executability can't see it.
public enum HelperSync {
    public static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public enum Decision: Equatable, Sendable {
        /// Same bytes; nothing to do.
        case current
        case replace
        /// The stable helper is from a newer AgentDeck. Every copy of the
        /// app shares it, so an older app launched beside a newer one must
        /// not swap in its own helper: hooks would then run code that
        /// doesn't know the newer build's providers or fields.
        case keepNewer
    }

    /// "0.5.1" → [0, 5, 1]. Anything else (a suffix, an empty part) is nil,
    /// and an unparseable version never blocks a replace.
    public static func parseVersion(_ s: String) -> [Int]? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// Strictly newer, comparing component by component (missing = 0).
    public static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The version a helper binary reports for `--version`, which prints
    /// it bare. nil when it can't be run or says something else.
    public static func reportedVersion(of url: URL) -> String? {
        let result = BoundedSubprocess.run(url.path, arguments: ["--version"], timeout: 3)
        guard !result.timedOut, result.status == 0 else { return nil }
        let first = String(decoding: result.output, as: UTF8.self)
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return first.flatMap { parseVersion($0) != nil ? $0 : nil }
    }

    public static func decide(
        bundledHash: String?, stableHash: String?,
        bundledVersion: String, stableVersion: () -> String?
    ) -> Decision {
        guard let bundledHash else { return .current }  // nothing to install
        guard let stableHash else { return .replace }
        if bundledHash == stableHash { return .current }
        // equal or older-than-bundled replaces, as before: a rebuilt helper
        // of the same version is how development builds update
        if let mine = parseVersion(bundledVersion),
           let theirs = stableVersion().flatMap(parseVersion),
           isNewer(theirs, than: mine) {
            return .keepNewer
        }
        return .replace
    }

    public static func decision(
        bundled: URL, bundledVersion: String, stable: URL,
        stableVersion: (URL) -> String? = reportedVersion(of:)
    ) -> Decision {
        decide(bundledHash: sha256(of: bundled), stableHash: sha256(of: stable),
               bundledVersion: bundledVersion, stableVersion: { stableVersion(stable) })
    }

    public static func needsSync(
        bundled: URL, bundledVersion: String = AgentDeckVersion.current, stable: URL,
        stableVersion: (URL) -> String? = reportedVersion(of:)
    ) -> Bool {
        decision(bundled: bundled, bundledVersion: bundledVersion, stable: stable,
                 stableVersion: stableVersion) == .replace
    }

    /// Atomic replace, preserving executability. Safe while hooks run: each
    /// hook invocation execs the file fresh, and rename is atomic.
    /// Returns whether it replaced the stable helper.
    @discardableResult
    public static func sync(
        bundled: URL, bundledVersion: String = AgentDeckVersion.current, stable: URL,
        stableVersion: (URL) -> String? = reportedVersion(of:)
    ) throws -> Bool {
        guard needsSync(bundled: bundled, bundledVersion: bundledVersion, stable: stable,
                        stableVersion: stableVersion) else { return false }
        let fm = FileManager.default
        try fm.createDirectory(
            at: stable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let tmp = stable.deletingLastPathComponent()
            .appendingPathComponent(".helper-\(UUID().uuidString).tmp")
        try fm.copyItem(at: bundled, to: tmp)
        // chmod BEFORE the rename so there is no window where a firing hook
        // execs a non-executable file…
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        do {
            _ = try fm.replaceItemAt(stable, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)  // don't strand tmp debris in bin/
            throw error
        }
        // …and again after: replaceItemAt can merge the OLD item's metadata
        // onto the replacement, which would drop the executable bit
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stable.path)
        return true
    }
}
