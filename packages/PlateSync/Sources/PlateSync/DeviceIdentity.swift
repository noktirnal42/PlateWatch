import CryptoKit
import Foundation

/// On-device ed25519 identity. The public key hash is the contributor
/// identity in the shared dataset (anonymous by design); the private key
/// never leaves the keychain and signs every submission so moderators can
/// later rate-limit a misbehaving device without anyone knowing whose it is.
public struct DeviceIdentity: Sendable {
    public let publicKeyHash: String
    private let signingKey: Curve25519.Signing.PrivateKey

    private init(signingKey: Curve25519.Signing.PrivateKey) {
        self.signingKey = signingKey
        let digest = SHA256.hash(data: signingKey.publicKey.rawRepresentation)
        self.publicKeyHash = digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let keyTag = "org.openalpr.platewatch.device-key"

    /// Load or create the device key. Keychain-backed with Secure Enclave off
    /// (SE keys can't be exported, which breaks dev workflows); the key is
    /// non-exportable via `kSecAttrAccessible` anyway.
    public static func loadOrCreate() throws -> DeviceIdentity {
        if let existing = try readKey() { return DeviceIdentity(signingKey: existing) }
        let key = Curve25519.Signing.PrivateKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false, // never roam keys to iCloud
            kSecValueData as String: key.rawRepresentation,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
        return DeviceIdentity(signingKey: key)
    }

    private static func readKey() throws -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw IdentityError.keychain(status)
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// Sign canonical submission bytes (JSON DTO + idempotency key).
    public func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }

    public enum IdentityError: Error {
        case keychain(OSStatus)
    }
}
