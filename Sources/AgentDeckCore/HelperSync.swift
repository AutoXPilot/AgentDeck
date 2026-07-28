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

    public static func needsSync(bundled: URL, stable: URL) -> Bool {
        guard let bundledHash = sha256(of: bundled) else { return false }
        guard let stableHash = sha256(of: stable) else { return true }
        return bundledHash != stableHash
    }

    /// Atomic replace, preserving executability. Safe while hooks run: each
    /// hook invocation execs the file fresh, and rename is atomic.
    @discardableResult
    public static func sync(bundled: URL, stable: URL) throws -> Bool {
        guard needsSync(bundled: bundled, stable: stable) else { return false }
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
