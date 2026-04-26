import Foundation
import Security

/// App-Group-shared Keychain wrapper for the Paperless API token.
///
/// One item per host, identified by `kSecAttrAccount` = the host string
/// (e.g., "paperless.czei.org"). Accessibility class is
/// `kSecAttrAccessibleAfterFirstUnlock` so the Background URLSession
/// completion handler can read the token while the device is locked
/// (post-boot first-unlock barrier still protects the secret at rest).
public struct KeychainStore {
    private static let service = "org.czei.PaperlessClipper.apiToken"
    private static let accessGroup = AppGroup.identifier

    public init() {}

    public func save(token: String, host: String) throws {
        let data = Data(token.utf8)

        // Try update first; fall back to add if no item exists yet.
        let query = baseQuery(host: host)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.updateFailed(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.addFailed(status: addStatus)
        }
    }

    public func read(host: String) throws -> String {
        var query = baseQuery(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.readFailed(status: status)
        }

        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.readFailed(status: errSecDecode)
        }
        return token
    }

    public func delete(host: String) throws {
        let status = SecItemDelete(baseQuery(host: host) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Delete every Paperless Clipper token (used by Sign Out when the user
    /// might have multiple per-host items from past configurations).
    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    private func baseQuery(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
    }
}

public enum KeychainError: Error, Equatable {
    case itemNotFound
    case addFailed(status: OSStatus)
    case updateFailed(status: OSStatus)
    case readFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
}
