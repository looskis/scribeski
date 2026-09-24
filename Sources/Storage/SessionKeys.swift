import CryptoKit
import Foundation
import Security

/// One AES-256 key per session, in the Keychain (DESIGN §8). Deleting the key is the delete:
/// on APFS (copy-on-write, SSD wear-levelling) overwriting a file proves nothing, but
/// ciphertext without its key is noise, and removing a Keychain item is instant.
public struct SessionKeys: Sendable {
    public let service: String

    public init(service: String = "com.looski.scribeski.session") {
        self.service = service
    }

    public enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case missing(String)

        public var description: String {
            switch self {
            case .keychain(let s): "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "")"
            case .missing(let id): "No key for session \(id): it was destroyed, so its data is gone."
            }
        }
    }

    /// Where keys live. The data-protection keychain honours "this device only, when
    /// unlocked"; it needs a provisioned app (P4.1). Unprovisioned builds and tests fall back
    /// to the login keychain, which is still encrypted at rest but can sync to backups.
    public enum Backend: String, Sendable { case dataProtection, login }

    private func base(_ id: String, _ backend: Backend) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        if backend == .dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Creates the session's key. Returns which keychain it went into.
    @discardableResult
    public func create(for id: String) throws -> Backend {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        for backend in [Backend.dataProtection, .login] {
            var q = base(id, backend)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            q[kSecAttrLabel as String] = "Scribeski session key"
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return backend }
            if status == errSecMissingEntitlement { continue }
            throw Failure.keychain(status)
        }
        throw Failure.keychain(errSecMissingEntitlement)
    }

    public func key(for id: String) throws -> SymmetricKey {
        for backend in [Backend.dataProtection, .login] {
            var q = base(id, backend)
            q[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess, let data = out as? Data { return SymmetricKey(data: data) }
            if status == errSecItemNotFound || status == errSecMissingEntitlement { continue }
            throw Failure.keychain(status)
        }
        throw Failure.missing(id)
    }

    /// Destroys the key. Idempotent.
    public func destroy(_ id: String) throws {
        for backend in [Backend.dataProtection, .login] {
            let status = SecItemDelete(base(id, backend) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                throw Failure.keychain(status)
            }
        }
    }

    public func exists(_ id: String) -> Bool { (try? key(for: id)) != nil }
}
