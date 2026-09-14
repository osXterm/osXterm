import Foundation
import Security

public enum KeychainSecretStoreError: Error, LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidSecretEncoding

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status): "Keychain operation failed with status \(status)."
        case .invalidSecretEncoding: "The Keychain secret is not valid UTF-8 text."
        }
    }
}

public struct KeychainSecretStore: Sendable {
    public let service: String

    public init(service: String = "app.osxterm.credentials") {
        self.service = service
    }

    public func save(_ value: String, for reference: SecretReference) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainSecretStoreError.invalidSecretEncoding
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            for (key, value) in attributes { addQuery[key] = value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainSecretStoreError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    public func read(_ reference: SecretReference) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecretStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainSecretStoreError.invalidSecretEncoding
        }
        return value
    }

    public func delete(_ reference: SecretReference) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
    }
}
