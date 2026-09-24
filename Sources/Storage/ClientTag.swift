import CryptoKit
import Foundation

/// A keyed hash of a client's record ID, for the audit log (decided 2026-09-23). Given an ID
/// you can show "Scribeski filled this chart on this date", but the log alone never lists
/// clients, and without this install's key the tags can't be brute-forced from ID formats.
public struct ClientTagger: Sendable {
    public let keys: SessionKeys
    public static let keyID = "audit-client-tag"

    public init(keys: SessionKeys = SessionKeys(service: "com.looski.scribeski.audit")) {
        self.keys = keys
    }

    /// HMAC-SHA256 of the normalized ID under this install's key, first 128 bits, hex.
    public func tag(_ clientID: String) throws -> String {
        let key: SymmetricKey
        if let existing = try? keys.key(for: Self.keyID) {
            key = existing
        } else {
            try keys.create(for: Self.keyID)
            key = try keys.key(for: Self.keyID)
        }
        let normalized = clientID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
        return "ct:" + mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
