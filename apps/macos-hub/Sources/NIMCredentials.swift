import Foundation
import Security
import NIMKit

/// No key in defaults, prompts, model outputs, process arguments or the journal.
enum NIMCredentials {
    private static let service = "org.platewatch.hub.nvidia"
    private static let account = "api-key"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func load() async -> String? {
        await Task.detached {
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
    static func save(_ key: String) async -> Bool {
        await Task.detached {
            guard key.count >= 20, key.count <= 4096, !key.contains(where: \.isWhitespace) else { return false }
            let value = [kSecValueData as String: Data(key.utf8)]
            let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }.value
    }
    static func remove() async -> Bool {
        await Task.detached { let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound }.value
    }
    static func client() -> NIMClient { NIMClient(credential: { await load() }) }
}
