//
//  LicenseStorage.swift
//  Mimi
//

import Foundation
import Security

/// Where the licence key is kept between launches.
nonisolated protocol LicenseStorage: Sendable {
    func load() -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// The login keychain: the key is not readable by other apps without the
/// user's permission, and it survives reinstalling the app.
nonisolated struct KeychainLicenseStorage: LicenseStorage {
    var service = "io.github.nkwabyte.mimi.license"
    var account = "licence-key"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

nonisolated struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "The keychain refused to store the licence: \(detail)."
    }
}

/// For previews and tests.
nonisolated final class MemoryLicenseStorage: LicenseStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func save(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        value = key
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}
