import Foundation
import Security

/// Keychain helper for provider API keys.
///
/// Keys are stored as generic-password items under the service
/// `com.pagemind.app.keys`. No key value is ever logged.
/// Key IDs: "openrouter", "openai", "anthropic", "gemini", "groq", "brave".
enum KeychainStore {
    static let service = "com.pagemind.app.keys"

    /// Known key IDs. Callers should use these constants, not raw strings.
    static let openRouter = "openrouter"
    static let openAI = "openai"
    static let anthropic = "anthropic"
    static let gemini = "gemini"
    static let groq = "groq"
    static let brave = "brave"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Remove any existing item first so SecItemAdd does not hit errSecDuplicateItem.
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func hasKey(_ key: String) -> Bool {
        load(key: key) != nil
    }
}
