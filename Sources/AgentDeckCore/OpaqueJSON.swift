import Foundation

/// Any JSON value, decoded and re-encoded without interpretation. Used to
/// carry data this build can't understand — a workspace entry written by a
/// newer build for a provider this one has no case for — back to disk
/// unchanged, instead of dropping it on the next write.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// A workspace entry this build couldn't decode — most likely a provider
/// added in a later version — kept verbatim so it is written back exactly
/// as found. Its key and last sighting are read only to merge two copies.
public struct OpaqueWorkspaceEntry: Equatable, Sendable {
    public var value: JSONValue

    public init(_ value: JSONValue) { self.value = value }

    /// Same form as `WorkspaceEntry.key`, when the entry has the fields.
    public var key: String? {
        guard let provider = value["provider"]?.stringValue,
              let id = value["sessionId"]?.stringValue else { return nil }
        return "\(provider)-\(id)"
    }

    public var lastSeen: Date? {
        guard let s = value["lastSeen"]?.stringValue else { return nil }
        return SnapshotStore.isoFractional.date(from: s) ?? SnapshotStore.isoPlain.date(from: s)
    }
}

/// One element of a workspace file's `entries`: an entry this build knows,
/// or one it keeps without understanding. Decoding never fails for a
/// well-formed JSON value, which is the point — a single unknown entry
/// used to fail the whole file, and the next write replaced it.
enum WorkspaceEntrySlot: Decodable {
    case known(WorkspaceEntry)
    case opaque(OpaqueWorkspaceEntry)

    init(from decoder: any Decoder) throws {
        if let entry = try? WorkspaceEntry(from: decoder) {
            self = .known(entry)
        } else {
            self = .opaque(OpaqueWorkspaceEntry(try JSONValue(from: decoder)))
        }
    }

    static func split(_ slots: [WorkspaceEntrySlot]) -> ([WorkspaceEntry], [OpaqueWorkspaceEntry]) {
        var known: [WorkspaceEntry] = [], opaque: [OpaqueWorkspaceEntry] = []
        for slot in slots {
            switch slot {
            case .known(let e): known.append(e)
            case .opaque(let o): opaque.append(o)
            }
        }
        return (known, opaque)
    }
}

/// Encodes known entries followed by the opaque ones, as one array.
struct WorkspaceEntriesForEncoding: Encodable {
    var known: [WorkspaceEntry]
    var opaque: [OpaqueWorkspaceEntry]

    func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        for e in known { try c.encode(e) }
        for o in opaque { try c.encode(o.value) }
    }
}
