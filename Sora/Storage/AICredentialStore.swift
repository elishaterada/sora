import Foundation
import Security

protocol AICredentialStore {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

struct KeychainAICredentialStore: AICredentialStore {
    let service: String
    let account: String

    init(service: String = "dev.sora.app.ai", account: String = "openai") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AIError.missingKey }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain access failed (\(status)). Unlock your login keychain and try again." }
    }
}
