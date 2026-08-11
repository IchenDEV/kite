import Foundation
import Security

struct CredentialSecret: Codable, Equatable, Sendable {
    var password = ""
    var cookie = ""
}

enum KeychainServiceError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

enum KeychainService {
    private static let credentialService = "com.chenli.superdd.credentials"
    private static let applicationService = "com.chenli.superdd.application"

    static func saveCredential(_ secret: CredentialSecret, id: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        try save(data, service: credentialService, account: id.uuidString)
    }

    static func credential(id: UUID) throws -> CredentialSecret? {
        guard let data = try read(service: credentialService, account: id.uuidString) else { return nil }
        return try JSONDecoder().decode(CredentialSecret.self, from: data)
    }

    static func removeCredential(id: UUID) throws {
        try remove(service: credentialService, account: id.uuidString)
    }

    static func saveProxyPassword(_ value: String) throws {
        if value.isEmpty {
            try remove(service: applicationService, account: "proxy-password")
        } else {
            try save(Data(value.utf8), service: applicationService, account: "proxy-password")
        }
    }

    static func proxyPassword() throws -> String {
        guard let data = try read(service: applicationService, account: "proxy-password") else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainServiceError.unexpectedStatus(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainServiceError.unexpectedStatus(addStatus) }
    }

    private static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainServiceError.unexpectedStatus(status) }
        return result as? Data
    }

    private static func remove(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }
}
