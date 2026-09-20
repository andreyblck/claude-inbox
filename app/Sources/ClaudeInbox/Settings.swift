import Foundation

/// The one Claude Code setting this app has a reason to touch.
///
/// A session running in `bypassPermissions` executes what it is told without
/// asking, so Claude Code holds messages arriving from outside it unless the
/// person has said otherwise. That hold is why a note sent from the panel lands
/// as *"1 held"* and has to be released by hand in the terminal — which is the
/// round trip this app exists to remove, so it is worth offering to lift.
///
/// It is not worth lifting quietly. The app explains the trade and the person
/// decides; nothing here runs on its own.
enum Settings {
    enum Inbound: String {
        /// Deliver peer messages straight into the session.
        case accept
        /// Park them for review. The default where the session bypasses prompts.
        case hold
    }

    private static func settingsPath(_ configDir: String) -> String {
        (configDir as NSString).appendingPathComponent("settings.json")
    }

    /// Unset reads as `hold` here, because unset *behaves* as hold for exactly
    /// the sessions this matters for.
    static func inbound(configDir: String? = nil) -> Inbound {
        let dir = configDir ?? Inbox.configDirs().first ?? NSHomeDirectory() + "/.claude"
        guard let data = FileManager.default.contents(atPath: settingsPath(dir)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["crossSessionInbound"] as? String,
              let value = Inbound(rawValue: raw)
        else { return .hold }
        return value
    }

    /// True when a note sent to this session will be parked rather than delivered.
    static func willHold(permissionMode: String?) -> Bool {
        // The parity check only bites when the receiving session bypasses
        // prompts; a session that still asks cannot be escalated by a message.
        let bypassing = permissionMode == "bypassPermissions" || permissionMode == "dontAsk"
        return bypassing && inbound() == .hold
    }

    /// Writes the setting, keeping a backup of what was there.
    ///
    /// Same rule as the installer: never touch a settings file we could not parse,
    /// and never overwrite one without leaving the previous version behind.
    @discardableResult
    static func setInbound(_ value: Inbound, configDir: String? = nil) -> Bool {
        let dir = configDir ?? Inbox.configDirs().first ?? NSHomeDirectory() + "/.claude"
        let path = settingsPath(dir)
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false  // unreadable: leave it alone rather than replace it
            }
            json = parsed
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            try? data.write(to: URL(fileURLWithPath: path + ".bak-" + stamp))
        }
        json["crossSessionInbound"] = value.rawValue
        guard let out = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return (try? out.write(to: URL(fileURLWithPath: path))) != nil
    }
}
