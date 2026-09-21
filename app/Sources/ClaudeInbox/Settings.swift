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

/// What the app is allowed to ask a model, and what that has cost.
///
/// Every name and every reading is a small Haiku call on the person's own
/// account. Small, but it comes out of the same window their work does — and the
/// first time that window ran red, there was no way to turn this off and no way
/// to see what it had spent. Both now exist.
enum Spend {
    private static let enabledKey = "modelCallsEnabled"
    private static let countKey = "modelCallsCount"
    private static let dayKey = "modelCallsDay"

    /// On unless someone turned it off. A row that says `skyaccess-d5` instead of
    /// "GSC" is worse, so the default earns its keep — but it is a default, not a
    /// condition of using the app.
    static var enabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static var today: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }

    /// Counted rather than estimated: a number you can check beats a promise that
    /// it is cheap.
    static func record() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: dayKey) != today {
            defaults.set(today, forKey: dayKey)
            defaults.set(0, forKey: countKey)
        }
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
    }

    static var todayCount: Int {
        UserDefaults.standard.integer(forKey: dayKey) == today
            ? UserDefaults.standard.integer(forKey: countKey) : 0
    }
}
