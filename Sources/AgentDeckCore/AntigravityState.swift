import Darwin
import Foundation

/// What Antigravity's own state directory says about running
/// conversations, read as metadata only.
///
/// Read: the names of `presence/*.lock` and whether a process holds each
/// one; `cache/last_conversations.json` (workspace path → last
/// conversation id); whether `conversations/<id>.db` exists; the `title`
/// field of `annotations/<id>.pbtxt`, for display only.
/// Never read: `history.jsonl` (prompt text), the conversation databases,
/// `conversation_summaries.db`, `brain/`, logs.
public enum AntigravityState {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    // MARK: - Titles

    static let maxAnnotationBytes = 64 * 1024
    static let maxTitleLength = 200

    /// Conversation id → title, from `annotations/<id>.pbtxt`. That file
    /// holds what `/rename` set, or else a title agy generated from the
    /// conversation, and nothing marks which; the only record of renames is
    /// `history.jsonl`, which is never read. A generated title summarises
    /// prompts, so this is for the row on screen only: keep it out of
    /// snapshots, workspaces, logs and notifications.
    public static func conversationTitles(directory: URL = defaultDirectory) -> [String: String] {
        let folder = directory.appendingPathComponent("annotations", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var titles: [String: String] = [:]
        for name in names where name.hasSuffix(".pbtxt") {
            guard let uuid = UUID(uuidString: String(name.dropLast(".pbtxt".count))) else { continue }
            let url = folder.appendingPathComponent(name)
            // lstat: a link or an oversized file isn't agy's annotation
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size <= maxAnnotationBytes,
                  let data = try? Data(contentsOf: url),
                  let title = title(fromAnnotation: data)
            else { continue }
            titles[uuid.uuidString.lowercased()] = title
        }
        return titles
    }

    /// The top-level `title` of a protobuf text message; every other field
    /// is skipped. Anything malformed before it (an unmatched brace, an
    /// unterminated string) means no title rather than a guess: a nested
    /// or half-written one must not reach the row.
    static func title(fromAnnotation data: Data) -> String? {
        let bytes = [UInt8](data)
        let key = Array("title".utf8)
        func isName(_ c: UInt8) -> Bool {
            c == UInt8(ascii: "_") || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
        }
        var i = 0
        var depth = 0
        while i < bytes.count {
            let c = bytes[i]
            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                guard let string = quotedString(bytes, at: i) else { return nil }
                i = string.end
                continue
            case UInt8(ascii: "#"):
                i = skipTrivia(bytes, from: i)
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "<"): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: ">"):
                depth -= 1
                if depth < 0 { return nil }
            default: break
            }
            if depth == 0, c == key[0], i == 0 || !isName(bytes[i - 1]),
               i + key.count <= bytes.count, Array(bytes[i..<(i + key.count)]) == key {
                var j = skipTrivia(bytes, from: i + key.count)
                if j < bytes.count, bytes[j] == UInt8(ascii: ":") {
                    j = skipTrivia(bytes, from: j + 1)
                    if j < bytes.count, isQuote(bytes[j]) { return concatenatedString(bytes, at: j).flatMap(cleanTitle) }
                }
            }
            i += 1
        }
        return nil
    }

    private static func isQuote(_ c: UInt8) -> Bool { c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") }

    /// Past whitespace and `#` comments.
    private static func skipTrivia(_ bytes: [UInt8], from index: Int) -> Int {
        var i = index
        while i < bytes.count {
            if [32, 9, 10, 13].contains(bytes[i]) {
                i += 1
            } else if bytes[i] == UInt8(ascii: "#") {
                while i < bytes.count, bytes[i] != 10 { i += 1 }
            } else {
                break
            }
        }
        return i
    }

    /// Adjacent quoted fragments are one value in text format.
    private static func concatenatedString(_ bytes: [UInt8], at start: Int) -> [UInt8]? {
        var out: [UInt8] = []
        var i = start
        while i < bytes.count, isQuote(bytes[i]) {
            guard let part = quotedString(bytes, at: i) else { return nil }
            out += part.value
            i = skipTrivia(bytes, from: part.end)
        }
        return out
    }

    /// The string starting at the quote at `start`, unescaped, and the
    /// index after its closing quote. nil if it never closes. Non-ASCII may
    /// arrive as octal or hex bytes, or as `\u`/`\U` code points.
    private static func quotedString(_ bytes: [UInt8], at start: Int) -> (value: [UInt8], end: Int)? {
        let quote = bytes[start]
        var out: [UInt8] = []
        var i = start + 1
        func number(from first: Int, digits: Int, radix: Int) -> (value: UInt32, end: Int) {
            var value: UInt32 = 0
            var j = first
            while j < bytes.count, j < first + digits,
                  let digit = Character(UnicodeScalar(bytes[j])).hexDigitValue, digit < radix {
                value = value &* UInt32(radix) &+ UInt32(digit)
                j += 1
            }
            return (value, j)
        }
        func codePoint(digits: Int) {
            let parsed = number(from: i + 2, digits: digits, radix: 16)
            out += String(UnicodeScalar(parsed.value).map(Character.init) ?? "\u{FFFD}").utf8
            i = parsed.end
        }
        while i < bytes.count, bytes[i] != quote {
            guard bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }
            let next = bytes[i + 1]
            switch next {
            case UInt8(ascii: "a"): out.append(7); i += 2
            case UInt8(ascii: "b"): out.append(8); i += 2
            case UInt8(ascii: "f"): out.append(12); i += 2
            case UInt8(ascii: "n"): out.append(10); i += 2
            case UInt8(ascii: "r"): out.append(13); i += 2
            case UInt8(ascii: "t"): out.append(9); i += 2
            case UInt8(ascii: "v"): out.append(11); i += 2
            case UInt8(ascii: "x"), UInt8(ascii: "X"):
                let parsed = number(from: i + 2, digits: 2, radix: 16)
                out.append(UInt8(truncatingIfNeeded: parsed.value))
                i = parsed.end
            case UInt8(ascii: "u"): codePoint(digits: 4)
            case UInt8(ascii: "U"): codePoint(digits: 8)
            case 48...55:
                let parsed = number(from: i + 1, digits: 3, radix: 8)
                out.append(UInt8(truncatingIfNeeded: parsed.value))
                i = parsed.end
            default: out.append(next); i += 2
            }
        }
        guard i < bytes.count else { return nil }
        return (out, i + 1)
    }

    /// One line, and no direction overrides, which would reorder the row.
    private static func cleanTitle(_ bytes: [UInt8]) -> String? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let overrides: ClosedRange<UInt32> = 0x202A...0x202E
        let isolates: ClosedRange<UInt32> = 0x2066...0x2069
        let scalars = text.unicodeScalars.compactMap { scalar -> Character? in
            if overrides.contains(scalar.value) || isolates.contains(scalar.value) { return nil }
            return scalar.properties.generalCategory == .control ? " " : Character(scalar)
        }
        let title = String(scalars).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : String(title.prefix(maxTitleLength))
    }

    /// Whether some process holds `url`'s lock. A running agy holds its
    /// conversation's presence lock for as long as it runs (observed with
    /// agy 1.4.7); the file itself stays behind after exit and its mtime
    /// never changes, so only the lock state means anything.
    ///
    /// Opened read-only and never created, written or unlinked. The probe
    /// is a non-blocking shared lock released at once: it fails only while
    /// another process holds the lock.
    public static func isLockHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// A held presence lock: a running conversation, and when it was last
    /// active as far as file metadata says — its database's modification
    /// time, else the lock file's creation (the lock file is reused across
    /// runs, so its own date can be weeks old). Never the scan time.
    public struct Presence: Equatable, Sendable {
        public var conversationId: String
        public var since: Date?
    }

    /// Conversations whose presence lock is held right now. Ids are
    /// canonical lowercased UUIDs; anything else in the folder is ignored.
    public static func runningConversations(
        directory: URL = defaultDirectory,
        isHeld: (URL) -> Bool = isLockHeld
    ) -> [Presence] {
        let presence = directory.appendingPathComponent("presence", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: presence.path)
        else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".lock"),
                  let uuid = UUID(uuidString: String(name.dropLast(".lock".count)))
            else { return nil }
            let url = presence.appendingPathComponent(name)
            guard isHeld(url) else { return nil }
            let id = uuid.uuidString.lowercased()
            let fm = FileManager.default
            // stat only: the database is never opened
            let database = directory.appendingPathComponent("conversations/\(id).db")
            let active = (try? fm.attributesOfItem(atPath: database.path))?[
                .modificationDate] as? Date
            let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
            return Presence(conversationId: id, since: active ?? created)
        }
    }

    /// Conversation id → workspace path, only where exactly one workspace
    /// names that conversation. The cache keeps one conversation per
    /// workspace — the last one used there, not an index of running
    /// sessions — so it is a hint for the folder and nothing else.
    public static func unambiguousWorkspaces(directory: URL = defaultDirectory) -> [String: String] {
        let url = directory.appendingPathComponent("cache/last_conversations.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return unambiguousWorkspaces(fromCache: data)
    }

    static func unambiguousWorkspaces(fromCache data: Data) -> [String: String] {
        guard let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var paths: [String: [String]] = [:]
        for (path, value) in map {
            guard path.hasPrefix("/"), let raw = value as? String,
                  let uuid = UUID(uuidString: raw) else { continue }
            paths[uuid.uuidString.lowercased(), default: []].append(path)
        }
        return paths.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    /// Rows for running conversations no hook has reported. They carry
    /// what is verified — the conversation is running — and the folder
    /// only when the cache names it unambiguously. No pid and no pane: such
    /// a row can't be focused, and without a folder it is never captured
    /// for restore. `.done`/`.error` are hook-only facts and never guessed.
    public static func discoveredSnapshots(
        _ running: [Presence], workspaces: [String: String]
    ) -> [SessionSnapshot] {
        running.map { presence in
            SessionSnapshot(
                provider: .antigravity,
                sessionId: presence.conversationId,
                projectPath: workspaces[presence.conversationId] ?? "",
                state: .ready,
                event: discoveryEvent,
                // never the scan time: an advancing timestamp re-arms acks
                updatedAt: presence.since ?? .distantPast)
        }
    }

    public static let discoveryEvent = "PresenceDiscovery"

    /// Whether agy still has the conversation (its database file exists;
    /// never opened). nil when that can't be told.
    public static func conversationExists(
        id: String, directory: URL = defaultDirectory
    ) -> Bool? {
        guard let uuid = UUID(uuidString: id) else { return false }
        let conversations = directory.appendingPathComponent("conversations", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: conversations.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return FileManager.default.fileExists(
            atPath: conversations.appendingPathComponent(
                "\(uuid.uuidString.lowercased()).db").path)
    }
}
