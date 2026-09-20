import Foundation
import Security

/// The Keychain, narrowed to the four things this app needs from it.
///
/// Claude Code keeps the live OAuth token in a generic password item — service
/// `Claude Code-credentials`, account the macOS user name — and that single item
/// is what "which account am I signed in as" means for a plain `claude`. Copying
/// it out and putting a different one back is the whole of switching accounts.
///
/// Reading another application's item asks the person for permission the first
/// time. That prompt is the system working correctly and there is no way around
/// it worth taking; the app explains what it is about to ask for instead.
enum Keychain {
    /// Where Claude Code keeps the credentials a plain `claude` uses.
    static let claudeService = "Claude Code-credentials"
    /// Where this app keeps its copies. Never the same item, so a bug here can
    /// overwrite our own store and never Claude Code's only live token.
    static let ownService = "com.blckgh.claude-inbox.accounts"

    struct Item {
        var account: String
        var data: Data
    }

    /// The first item under a service, with the account name it was filed under —
    /// which has to be preserved, because Claude Code looks it up by that name.
    static func read(service: String, account: String? = nil) -> Item? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data
        else { return nil }
        let name = found[kSecAttrAccount as String] as? String ?? account ?? ""
        return Item(account: name, data: data)
    }

    static func accounts(service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Adds or replaces. Never deletes on the way, so a failure mid-write leaves
    /// what was there rather than nothing.
    @discardableResult
    static func write(service: String, account: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Writes an item every application may read.
    ///
    /// This is the difference between switching accounts and locking someone out
    /// of their own: `SecItemAdd` files an item under an access list containing
    /// only the app that created it, so Claude Code's own credentials, once
    /// rewritten by anything else, become unreadable to Claude Code. The item is
    /// still there and still correct — and `claude auth status` says "logged out".
    ///
    /// The legacy `SecAccess` API is the one that can say "anybody": an ACL whose
    /// trusted-application list is NULL means no application is singled out.
    @discardableResult
    static func writeShared(service: String, account: String, data: Data) -> Bool {
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, nil, &access) == errSecSuccess,
              let access
        else { return false }

        var acls: CFArray?
        SecAccessCopyACLList(access, &acls)
        for acl in (acls as? [SecACL]) ?? [] {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            SecACLCopyContents(acl, &applications, &description, &prompt)
            // NULL application list: readable without singling anyone out.
            SecACLSetContents(acl, nil, (description ?? "" as CFString), prompt)
        }

        // The old item carries the old, narrow access list, so it goes first.
        delete(service: service, account: account)

        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccess as String: access,
        ]
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
