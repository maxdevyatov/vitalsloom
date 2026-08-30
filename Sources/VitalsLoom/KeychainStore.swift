import Foundation
import Security

enum KeychainStore {
    private static let service = "com.mdevyatov.vitalsloom.credentials"
    private static let legacyService = "com.owletmonitor.credentials"
    private static let account = "owlet"

    static func save(email: String, password: String) throws {
        let data = try JSONEncoder().encode(["email": email, "password": password])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func load() -> (email: String, password: String)? {
        if let credentials = load(service: service) {
            try? delete(service: legacyService)
            return credentials
        }
        guard let credentials = load(service: legacyService) else { return nil }
        do {
            try save(email: credentials.email, password: credentials.password)
            try delete(service: legacyService)
        } catch {
            return credentials
        }
        return credentials
    }

    static func removeAll() throws {
        try delete(service: service)
        try delete(service: legacyService)
    }

    private static func load(service: String) -> (email: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let credentials = try? JSONDecoder().decode([String: String].self, from: data),
              let email = credentials["email"], let password = credentials["password"] else { return nil }
        return (email, password)
    }

    private static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    enum KeychainError: Error { case status(OSStatus) }
}
