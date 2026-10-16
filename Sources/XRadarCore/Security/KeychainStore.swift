// KeychainStore.swift
import Foundation
import Security

public enum KeychainError: Error {
    case itemNotFound
    case duplicateItem
    case invalidStatus(OSStatus)
    case conversionFailed
}

/// Abstracts the small slice of keychain access `TelegramNotifier` needs, so it
/// can be unit-tested with an in-memory mock instead of the real login keychain.
public protocol KeychainStoreProtocol: Actor {
    func loadTelegramBotToken() async throws -> String
    func loadTelegramChatID() async throws -> String
    func saveTelegramBotToken(_ token: String) async throws
    func saveTelegramChatID(_ chatID: String) async throws
    func deleteTelegramCredentials() async throws
}

public actor KeychainStore: KeychainStoreProtocol {
    public static let shared = KeychainStore()

    private let service = "com.xradar.app"

    public func save(account: String, data: String) throws {
        guard let data = data.data(using: .utf8) else {
            throw KeychainError.conversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Update existing
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.invalidStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.invalidStatus(status)
        }
    }

    public func load(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.invalidStatus(status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.conversionFailed
        }

        return string
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.invalidStatus(status)
        }
    }

    // Convenience methods for Telegram (async to match protocol)
    public func saveTelegramBotToken(_ token: String) async throws {
        try save(account: "telegram_bot_token", data: token)
    }

    public func loadTelegramBotToken() async throws -> String {
        try load(account: "telegram_bot_token")
    }

    public func saveTelegramChatID(_ chatID: String) async throws {
        try save(account: "telegram_chat_id", data: chatID)
    }

    public func loadTelegramChatID() async throws -> String {
        try load(account: "telegram_chat_id")
    }

    public func deleteTelegramCredentials() async throws {
        try delete(account: "telegram_bot_token")
        try delete(account: "telegram_chat_id")
    }
}
