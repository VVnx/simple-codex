import Foundation
import Security

public enum CredentialStoreError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case corruptCredentials

    public var errorDescription: String? {
        switch self {
        case .keychain: "无法访问系统钥匙串中的微信登录信息"
        case .corruptCredentials: "系统钥匙串中的微信登录信息已损坏"
        }
    }
}

public final class KeychainCredentialStore: @unchecked Sendable {
    public static let service = "com.vvnx.simple-codex"
    private static let account = "single-owner"

    public init() {}

    public func load() throws -> WeChatCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.keychain(status)
        }
        guard
            data.count <= 65_536,
            let credentials = try? JSONDecoder().decode(WeChatCredentials.self, from: data),
            Self.isValid(credentials)
        else { throw CredentialStoreError.corruptCredentials }
        return credentials
    }

    public func save(_ credentials: WeChatCredentials) throws {
        guard Self.isValid(credentials) else {
            throw CredentialStoreError.corruptCredentials
        }
        let data = try JSONEncoder().encode(credentials)
        guard data.count <= 65_536 else {
            throw CredentialStoreError.corruptCredentials
        }
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
        ]
        let values: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            var item = key
            values.forEach { item[$0.key] = $0.value }
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw CredentialStoreError.keychain(add) }
        } else if update != errSecSuccess {
            throw CredentialStoreError.keychain(update)
        }
    }

    public func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private static func isValid(_ value: WeChatCredentials) -> Bool {
        !value.accountID.isEmpty
            && value.accountID.utf8.count <= 4_096
            && value.ownerUserID.utf8.count <= 4_096
            && !value.botToken.isEmpty
            && value.botToken.utf8.count <= 65_536
            && (try? WeChatClient.validateAPIBaseURL(value.baseURL)) != nil
    }
}
