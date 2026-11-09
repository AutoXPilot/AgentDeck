import Foundation

/// The session name used in a notification, which leaves this process and
/// stays in Notification Center. Only names the user chose, or that come from
/// the folder, qualify. A tab title or a generated name can repeat the
/// conversation, so neither is an input here.
public enum NotificationLabel {
    public static func text(
        desktopTitle: String?, claudeEntry: ClaudeSessionRegistry.Entry?,
        codexName: String?, folder: String, sessionId: String
    ) -> String {
        if let desktopTitle { return desktopTitle }
        // a missing source means an older build, which generated names too
        if let entry = claudeEntry, entry.nameSource == "user",
           let name = entry.name, !name.isEmpty {
            return name
        }
        if let codexName, !codexName.isEmpty { return codexName }
        if !folder.isEmpty { return folder }
        return "session " + sessionId.prefix(8)
    }
}
