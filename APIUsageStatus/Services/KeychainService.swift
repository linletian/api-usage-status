import Foundation
import Security

// MARK: - KeychainError

enum KeychainError: Error, Equatable {
    case unableToStore
    case unableToRetrieve
    case unableToDelete
    case unexpectedStatus(OSStatus)

    var localizedDescription: String {
        switch self {
        case .unableToStore:
            return "Unable to store item in Keychain"
        case .unableToRetrieve:
            return "Unable to retrieve item from Keychain"
        case .unableToDelete:
            return "Unable to delete item from Keychain"
        case .unexpectedStatus(let status):
            return "Unexpected Keychain status: \(status)"
        }
    }
}

// MARK: - KeychainService

actor KeychainService {
    private static let service = "APIUsageStatus"
    private let logger = Logger(subsystem: "com.example.APIUsageStatus", category: "keychain")

    // MARK: - Store

    func store(key: String, for apiKeyRef: String) throws {
        let keyData = Data(key.utf8)

        // First check if the item already exists
        let existingQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: Self.service,
            kSecAttrAccount as String: apiKeyRef
        ]

        let existingStatus = SecItemCopyMatching(existingQuery as CFDictionary, nil)

        if existingStatus == errSecSuccess {
            // Item exists, update it
            var updateQuery: [String: Any] = [
                kSecValueData as String: keyData
            ]

            let updateStatus = SecItemUpdate(existingQuery as CFDictionary, updateQuery as CFDictionary)
            if updateStatus != errSecSuccess {
                logger.error("Failed to update Keychain item: \(updateStatus)")
                throw KeychainError.unableToStore
            }
            logger.debug("Updated Keychain item for ref: \(apiKeyRef, privacy: .private)")
        } else if existingStatus == errSecItemNotFound {
            // Item does not exist, add new one
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: Self.service,
                kSecAttrAccount as String: apiKeyRef,
                kSecValueData as String: keyData
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Failed to add Keychain item: \(addStatus)")
                throw KeychainError.unableToStore
            }
            logger.debug("Stored new Keychain item for ref: \(apiKeyRef, privacy: .private)")
        } else {
            logger.error("Unexpected status when checking Keychain: \(existingStatus)")
            throw KeychainError.unexpectedStatus(existingStatus)
        }
    }

    // MARK: - Retrieve

    func retrieve(for apiKeyRef: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: Self.service,
            kSecAttrAccount as String: apiKeyRef,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                logger.error("Failed to decode Keychain data for ref: \(apiKeyRef)")
                return nil
            }
            logger.debug("Retrieved Keychain item for ref: \(apiKeyRef, privacy: .private)")
            return key
        } else if status == errSecItemNotFound {
            logger.debug("No Keychain item found for ref: \(apiKeyRef)")
            return nil
        } else {
            logger.error("Failed to retrieve Keychain item: \(status)")
            return nil
        }
    }

    // MARK: - Delete

    func delete(for apiKeyRef: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: Self.service,
            kSecAttrAccount as String: apiKeyRef
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            // Success or already deleted — both are acceptable
            logger.debug("Deleted Keychain item for ref: \(apiKeyRef)")
        } else {
            logger.error("Failed to delete Keychain item: \(status)")
            throw KeychainError.unableToDelete
        }
    }

    // MARK: - Delete All

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: Self.service
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            logger.info("Deleted all Keychain items for service: \(Self.service)")
        } else {
            logger.error("Failed to delete all Keychain items: \(status)")
            throw KeychainError.unableToDelete
        }
    }
}