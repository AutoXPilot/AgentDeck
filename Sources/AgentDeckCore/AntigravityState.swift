import Foundation

/// What Antigravity's own state directory says, read as metadata only.
///
/// Read: whether `conversations/<id>.db` exists.
/// Never read: `history.jsonl` (prompt text), the conversation databases,
/// `conversation_summaries.db`, `brain/`, logs.
public enum AntigravityState {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

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
