import Foundation

/// Switching which account a plain `claude` uses.
///
/// This is the one thing in the app that can log someone out of everything at
/// once, so the rules it follows are worth stating rather than inferring:
///
/// 1. **Copy, never move.** A token is written into our own store before anything
///    live is touched, and the live item is never deleted — only overwritten.
/// 2. **Snapshot before writing.** Whatever is live goes into a rollback slot
///    first, so a half-finished switch has somewhere to come back to.
/// 3. **Verify, then keep.** After the write, `claude auth status` has to agree
///    that the expected account is now signed in. If it does not, the snapshot
///    goes back and the switch is reported as failed.
/// 4. **Back up the file.** `~/.claude.json` carries far more than the account;
///    it is copied aside before a single key of it is replaced.
///
/// The account metadata here is email, organisation and tier. The token itself
/// only ever lives in the Keychain and is never written to disk by this app.
enum AccountStore {
    struct Stored: Codable, Identifiable, Sendable, Equatable {
        var id: String
        var email: String
        var organization: String?
        var subscription: String?
        var capturedAt: Date
        /// The account name Claude Code's own Keychain item is filed under.
        /// Preserved because that is how it looks the item up.
        var keychainAccount: String
        /// The `oauthAccount` object from `~/.claude.json`, verbatim.
        var profile: [String: JSONValue]

        /// The same thing as plain values, for writing back into a file that
        /// belongs to someone else.
        var profileValues: [String: Any] {
            guard let data = try? JSONEncoder().encode(profile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }

        var label: String {
            guard let at = email.firstIndex(of: "@") else { return email }
            return String(email[..<at])
        }
    }

    enum Failure: Error, LocalizedError {
        case noLiveCredentials
        case noProfile
        case unreadableConfig
        case writeFailed(String)
        case verificationFailed(expected: String, got: String?)

        var errorDescription: String? {
            switch self {
            case .noLiveCredentials:
                "Could not read Claude Code's credentials. macOS may have declined the Keychain prompt."
            case .noProfile:
                "~/.claude.json has no account on it — sign in once with `claude auth login` first."
            case .unreadableConfig:
                "~/.claude.json could not be parsed, so nothing was changed."
            case .writeFailed(let what):
                "Could not write \(what). Nothing was changed."
            case .verificationFailed(let expected, let got):
                "Switched to \(expected) but Claude Code reports \(got ?? "nobody"). Put the previous account back."
            }
        }
    }

    // MARK: - Where things live

    private static var listPath: String {
        (Inbox.directory as NSString).appendingPathComponent("accounts.json")
    }

    private static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    private static let rollbackID = "rollback"

    // MARK: - The metadata list

    static func list() -> [Stored] {
        let decoder = JSONDecoder()
        // Must match the encoder below. It did not, and the list read back empty
        // straight after a capture that had plainly worked — the quietest kind of
        // wrong, because nothing failed anywhere.
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: listPath),
              let stored = try? decoder.decode([Stored].self, from: data)
        else { return [] }
        return stored.sorted { $0.email < $1.email }
    }

    private static func save(_ accounts: [Stored]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(accounts) else {
            throw Failure.writeFailed("the account list")
        }
        try? FileManager.default.createDirectory(
            atPath: Inbox.directory, withIntermediateDirectories: true)
        guard (try? data.write(to: URL(fileURLWithPath: listPath))) != nil else {
            throw Failure.writeFailed("the account list")
        }
    }

    // MARK: - Reading what is live

    /// Read with `JSONSerialization`, not a typed model.
    ///
    /// A hand-rolled JSON enum turns every number into a Double, and writing the
    /// file back through one shrank it from 180,823 bytes to 141,121 — a file
    /// that holds project history, caches and flags, quietly rewritten. This
    /// preserves what it does not understand, which for someone else's file is
    /// the only acceptable behaviour.
    private static func liveProfile() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            throw Failure.unreadableConfig
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadableConfig
        }
        guard let profile = root["oauthAccount"] as? [String: Any], !profile.isEmpty else {
            throw Failure.noProfile
        }
        return profile
    }

    /// The account signed in right now, as this app can see it.
    static func liveEmail() -> String? {
        guard let profile = try? liveProfile() else { return nil }
        return profile["emailAddress"] as? String
    }

    // MARK: - Capture

    /// Remembers whoever is signed in now, so they can be returned to later.
    @discardableResult
    static func captureCurrent() throws -> Stored {
        guard let live = Keychain.read(service: Keychain.claudeService) else {
            throw Failure.noLiveCredentials
        }
        let profile = try liveProfile()
        guard let email = profile["emailAddress"] as? String else { throw Failure.noProfile }
        guard let encoded = try? JSONSerialization.data(withJSONObject: profile),
              let profileJSON = try? JSONDecoder().decode([String: JSONValue].self, from: encoded)
        else { throw Failure.noProfile }

        var accounts = list()
        // Re-capturing an account refreshes it rather than making a second one:
        // a token is rotated, and two entries for one email is a trap.
        let id = accounts.first { $0.email == email }?.id ?? UUID().uuidString
        guard Keychain.write(service: Keychain.ownService, account: id, data: live.data) else {
            throw Failure.writeFailed("the saved token")
        }

        let stored = Stored(
            id: id,
            email: email,
            organization: profile["organizationName"] as? String,
            subscription: (profile["seatTier"] as? String) ?? (profile["billingType"] as? String),
            capturedAt: Date(),
            keychainAccount: live.account,
            profile: profileJSON)
        accounts.removeAll { $0.id == id }
        accounts.append(stored)
        try save(accounts)
        return stored
    }

    // MARK: - Switch

    @discardableResult
    static func switchTo(_ account: Stored) throws -> String {
        guard let token = Keychain.read(service: Keychain.ownService, account: account.id) else {
            throw Failure.writeFailed("— no saved token for \(account.label)")
        }
        // Rule 2: whatever is live goes somewhere recoverable before anything is
        // overwritten, including the case where it was never captured.
        let previousToken = Keychain.read(service: Keychain.claudeService)
        let previousProfile = try? liveProfile()
        if let previousToken {
            Keychain.write(service: Keychain.ownService, account: rollbackID, data: previousToken.data)
        }

        let keychainAccount = previousToken?.account ?? account.keychainAccount
        // Shared access, always. An ordinary write files the item under an access
        // list holding only this app, and Claude Code then cannot read its own
        // credentials — the failure looks exactly like being logged out, and the
        // rollback, written the same way, could not undo it either.
        guard Keychain.writeShared(
            service: Keychain.claudeService, account: keychainAccount, data: token.data)
        else { throw Failure.writeFailed("Claude Code's credentials") }

        do {
            try writeProfile(account.profileValues)
        } catch {
            restore(token: previousToken, profile: previousProfile, keychainAccount: keychainAccount)
            throw error
        }

        // Rule 3: ask Claude Code who it thinks is signed in, and believe it
        // rather than the fact that the writes returned success.
        let seen = Accounts.status(of: (NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
        guard seen.loggedIn, seen.email == account.email else {
            restore(token: previousToken, profile: previousProfile, keychainAccount: keychainAccount)
            Accounts.invalidate()
            throw Failure.verificationFailed(expected: account.email, got: seen.email)
        }
        Accounts.invalidate()
        return account.email
    }

    private static func writeProfile(_ profile: [String: Any]) throws {
        guard let data = FileManager.default.contents(atPath: configPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.unreadableConfig }

        // Rule 4: this file holds far more than the account.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? data.write(to: URL(fileURLWithPath: configPath + ".bak-" + stamp))

        root["oauthAccount"] = profile
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]),
              (try? out.write(to: URL(fileURLWithPath: configPath))) != nil
        else { throw Failure.writeFailed("~/.claude.json") }
    }

    private static func restore(token: Keychain.Item?, profile: [String: Any]?, keychainAccount: String) {
        if let token {
            Keychain.writeShared(
                service: Keychain.claudeService, account: keychainAccount, data: token.data)
        }
        if let profile { try? writeProfile(profile) }
    }
}
