import Foundation

public enum ModelStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The downloaded (or stored) bytes don't hash to the pinned SHA-256. The partial/blob has
    /// already been deleted when this is thrown; the file is never loaded.
    case hashMismatch(path: String, expected: String, actual: String)
    /// The byte count doesn't match the manifest.
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    /// Not enough free space for the remaining bytes plus the safety margin.
    case insufficientDiskSpace(required: Int64, available: Int64)
    /// The server answered with a non-success status.
    case httpStatus(Int, url: URL)
    case invalidManifest(String)
    case invalidAppID(String)
    case lockFailed(path: String, errno: Int32)
    case io(String)

    public var description: String {
        switch self {
        case let .hashMismatch(path, expected, actual):
            return "SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        case let .sizeMismatch(path, expected, actual):
            return "size mismatch for \(path): expected \(expected) bytes, got \(actual)"
        case let .insufficientDiskSpace(required, available):
            return "insufficient disk space: need \(required) bytes, \(available) available"
        case let .httpStatus(code, url):
            return "HTTP \(code) from \(url.absoluteString)"
        case let .invalidManifest(msg): return "invalid manifest: \(msg)"
        case let .invalidAppID(id): return "invalid app id '\(id)'"
        case let .lockFailed(path, err): return "flock(\(path)) failed: errno \(err)"
        case let .io(msg): return msg
        }
    }
}

/// Progress of `ModelStore.ensure`. Byte counts are for the whole manifest unless noted.
public struct DownloadProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        /// Another task or process holds this blob's download lock; waiting to reuse its result.
        case waitingForLock
        /// Re-hashing bytes already in `tmp/<sha>.partial` before resuming.
        case hashingPartial
        case downloading
        /// This file was already in `blobs/`.
        case alreadyPresent
        /// This file finished and was verified.
        case fileComplete
    }

    public var modelID: String
    public var phase: Phase
    /// The file this event is about.
    public var path: String
    public var fileBytesCompleted: Int64
    public var fileSize: Int64
    public var totalBytesCompleted: Int64
    public var totalBytes: Int64

    public var fractionCompleted: Double {
        totalBytes > 0 ? Double(totalBytesCompleted) / Double(totalBytes) : 1
    }
}

/// Events from `ModelStore.ensureStream`.
public enum EnsureEvent: Sendable, Hashable {
    case progress(DownloadProgress)
    /// The model's snapshot directory, ready to load.
    case completed(URL)
}
