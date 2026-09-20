import Foundation

/// An account is a config directory.
///
/// Claude Code keeps the live credentials in one Keychain item and the account
/// on it in `~/.claude.json`, which is why swapping accounts for a plain
/// `claude` in a terminal means swapping both — what `claude-swap` does, and the
/// most delicate thing anyone could automate here: get it wrong and every
/// account is logged out at once.
///
/// `CLAUDE_CONFIG_DIR` needs none of that: each directory carries its own login,
/// they coexist, and a session picks one by environment variable — so sessions
/// this app starts can each be on a different account with nothing global
/// changing and no token ever handled.
///
/// Two things learned by trying it, both of which shape everything here:
///
/// - A directory named explicitly is not the same as the default one left alone.
///   `CLAUDE_CONFIG_DIR=~/.claude claude auth status` reports **logged out**
///   while a plain `claude` on that same directory is signed in, because the
///   variable sends it looking for `<dir>/.credentials.json` and the default
///   account's token is in the Keychain. So the default account is only usable
///   unnamed, and every code path here treats it as the exception it is.
/// - Every other account therefore needs its own `claude auth login`, once, into
///   its own directory. They are not discovered; they are set up.
///
/// What this deliberately does not do is change which account a *terminal*
/// `claude` uses. That is the credential swap — Keychain item plus the
/// `oauthAccount` in `~/.claude.json` — and it is the one thing here that can
/// log someone out of everything at once. It deserves its own pass, not a
/// footnote at the end of a long one.
enum Accounts {
    struct Account: Identifiable, Sendable, Equatable {
        /// The config directory. This *is* the account.
        var configDir: String
        var email: String?
        var organization: String?
        var subscription: String?
        var loggedIn: Bool

        var id: String { configDir }

        /// The short handle, never the whole address: a panel is not a contact list.
        var label: String {
            if let email, let at = email.firstIndex(of: "@") { return String(email[..<at]) }
            let base = (configDir as NSString).lastPathComponent
            return base == ".claude" ? "default" : base.replacingOccurrences(of: ".claude-", with: "")
        }

        /// The one the process inherits when nothing says otherwise.
        var isDefault: Bool {
            configDir == (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        }
    }

    private struct Status: Decodable {
        var loggedIn: Bool?
        var email: String?
        var orgName: String?
        var subscriptionType: String?
        var configDirectory: String?
    }

    /// `claude auth status` starts a CLI and may reach the network, so this is
    /// not something to do on every directory change.
    private static let ttl: TimeInterval = 300
    nonisolated(unsafe) private static var cached: (at: Date, accounts: [Account])?
    private static let lock = NSLock()

    static var executable: String? {
        for path in [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Directories the bridge was installed into, plus anything that looks like a
    /// config directory beside the default one.
    static func knownDirectories() -> [String] {
        var dirs = Set(Inbox.configDirs())
        let home = NSHomeDirectory()
        dirs.insert((home as NSString).appendingPathComponent(".claude"))
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for entry in entries where entry.hasPrefix(".claude-") {
                var isDirectory: ObjCBool = false
                let path = (home as NSString).appendingPathComponent(entry)
                // `.claude-swap-backup` and friends are not accounts; a config
                // directory is one that has been signed into.
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("projects"))
                else { continue }
                dirs.insert(path)
            }
        }
        return dirs.sorted()
    }

    static func status(of configDir: String) -> Account {
        guard let executable else {
            return Account(configDir: configDir, email: nil, organization: nil,
                           subscription: nil, loggedIn: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status", "--json"]
        var environment = ProcessInfo.processInfo.environment
        // Naming the default directory explicitly is not the same as leaving it
        // alone: with CLAUDE_CONFIG_DIR set, Claude Code reads credentials from
        // `<dir>/.credentials.json`, and the default account's live token is in
        // the Keychain instead. Pointing at ~/.claude by name reports it logged
        // out while a plain `claude` on the same directory is signed in.
        let isDefault = configDir == (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        if isDefault {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = configDir
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else {
            return Account(configDir: configDir, email: nil, organization: nil,
                           subscription: nil, loggedIn: false)
        }
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        let status = data.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
        return Account(
            configDir: configDir,
            email: status?.email,
            organization: status?.orgName,
            subscription: status?.subscriptionType,
            loggedIn: status?.loggedIn ?? false)
    }

    static func all(force: Bool = false) -> [Account] {
        lock.lock()
        if !force, let cached, Date().timeIntervalSince(cached.at) < ttl {
            let accounts = cached.accounts
            lock.unlock()
            return accounts
        }
        lock.unlock()

        let accounts = knownDirectories().map(status(of:))
        lock.lock()
        cached = (Date(), accounts)
        lock.unlock()
        return accounts
    }

    /// Which account a new session should use. Remembered here, not globally:
    /// changing it affects what this app starts next and nothing already running.
    static var preferred: String {
        get { UserDefaults.standard.string(forKey: "preferredConfigDir") ?? Inbox.configDirs().first ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "preferredConfigDir") }
    }

    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
