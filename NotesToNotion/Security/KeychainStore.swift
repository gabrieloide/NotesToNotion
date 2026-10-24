import Foundation
import Security

enum KeychainStore {
    enum Key: String {
        case geminiAPIKey = "gemini_api_key"
        case notionToken = "notion_token"
        case notionDatabaseID = "notion_database_id"
        case githubToken = "github_token"
    }

    private static let service = "com.gabrieloide.NotesToNotion"
    private static var cache: [Key: String] = [:]
    private static let lock = NSLock()

    private static func defaultsKey(for key: Key) -> String {
        "cred_\(key.rawValue)"
    }

    static func read(_ key: Key) -> String? {
        lock.lock()
        if let cached = cache[key], !cached.isEmpty {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let defKey = defaultsKey(for: key)
        if let stored = UserDefaults.standard.string(forKey: defKey), !stored.isEmpty {
            lock.lock()
            cache[key] = stored
            lock.unlock()
            return stored
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }

        UserDefaults.standard.set(value, forKey: defKey)
        lock.lock()
        cache[key] = value
        lock.unlock()
        return value
    }

    @discardableResult
    static func save(_ key: Key, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return true
        }

        let defKey = defaultsKey(for: key)
        lock.lock()
        cache[key] = trimmed
        lock.unlock()
        UserDefaults.standard.set(trimmed, forKey: defKey)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: Key) {
        let defKey = defaultsKey(for: key)
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: defKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
