import Foundation
import Security

/// API tokens live in the macOS Keychain, never in SQLite.
///
/// Items are keyed by `service` + account ("jira-<rowid>"). The service is
/// injectable so tests can use a private namespace and never touch the
/// user's real keychain items.
///
/// Note on ACLs: items are owned by the creating process's signing identity.
/// With ad-hoc signing the identity changes every rebuild, which makes
/// `SecItemDelete` fail with `errSecInvalidOwnerEdit` for items created by a
/// previous build. Value updates stay permitted, so `deleteToken` falls back
/// to overwriting the secret with an empty value ("soft delete") and
/// `token` treats an empty secret as absent.
enum KeychainStore {
    static let defaultService = "todo.jira"

    private static func baseQuery(service: String, forAccountID id: Int64) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "jira-\(id)",
        ]
    }

    static func saveToken(_ token: String, service: String = defaultService, forAccountID id: Int64) throws {
        let data = Data(token.utf8)
        var query = baseQuery(service: service, forAccountID: id)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
            return
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    static func token(service: String = defaultService, forAccountID id: Int64) throws -> String? {
        var query = baseQuery(service: service, forAccountID: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else { return nil }
        // Whitespace-only values are "soft deleted" tokens (see deleteToken).
        let value = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func deleteToken(service: String = defaultService, forAccountID id: Int64) throws {
        let status = SecItemDelete(baseQuery(service: service, forAccountID: id) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        // ACL-denied hard delete (e.g. item owned by an earlier build under
        // ad-hoc signing): fall back to clearing the secret. `token` reports
        // cleared items as absent. Note: an empty Data value is silently
        // ignored by SecItemUpdate, so use a single space and trim on read.
        let update: [String: Any] = [
            kSecValueData as String: Data(" ".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery(service: service, forAccountID: id) as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}