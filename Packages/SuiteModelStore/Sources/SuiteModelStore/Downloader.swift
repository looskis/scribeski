import CryptoKit
import Foundation

/// Streams one pinned file into `tmp/<sha>.partial`, resuming with an HTTP `Range` request and
/// hashing incrementally. It never moves anything into `blobs/`; the caller does that after this
/// returns a matching digest.
struct Downloader: Sendable {
    let configuration: URLSessionConfiguration
    static let hashChunk = 4 * 1024 * 1024

    /// Result of `download`: the partial now holds exactly `file.size` bytes hashing to `file.sha256`.
    /// Throws `hashMismatch` / `sizeMismatch` after deleting the partial.
    func download(
        _ file: ModelFile, to partial: URL,
        onHashingPartial: @Sendable () -> Void,
        onBytes: @escaping @Sendable (_ fileBytesCompleted: Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        var offset: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: partial.path), let n = attrs[.size] as? NSNumber {
            offset = n.int64Value
        }
        if offset > file.size {
            try? fm.removeItem(at: partial)
            offset = 0
        }
        if !fm.fileExists(atPath: partial.path) {
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw ModelStoreError.io("cannot create \(partial.path)")
            }
        }

        // Resume: the hash must cover every byte, so re-hash what's already on disk.
        var hasher = SHA256()
        if offset > 0 {
            onHashingPartial()
            let reader = try FileHandle(forReadingFrom: partial)
            defer { try? reader.close() }
            var hashed: Int64 = 0
            while hashed < offset {
                try Task.checkCancellation()
                let want = Int(min(Int64(Self.hashChunk), offset - hashed))
                guard let chunk = try reader.read(upToCount: want), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                hashed += Int64(chunk.count)
            }
            offset = hashed
            onBytes(offset)
        }

        if offset < file.size {
            let result: (hasher: SHA256, length: Int64)
            do {
                result = try await fetch(file: file, partial: partial, offset: offset, hasher: hasher, onBytes: onBytes)
            } catch let error as ModelStoreError {
                // The server sent more bytes than pinned: the partial can't be trusted.
                if case .sizeMismatch = error { try? fm.removeItem(at: partial) }
                throw error
            }
            hasher = result.hasher
            offset = result.length
        }

        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if offset != file.size {
            try? fm.removeItem(at: partial)
            throw ModelStoreError.sizeMismatch(path: file.path, expected: file.size, actual: offset)
        }
        if actual != file.sha256 {
            try? fm.removeItem(at: partial)
            throw ModelStoreError.hashMismatch(path: file.path, expected: file.sha256, actual: actual)
        }
    }

    private func fetch(
        file: ModelFile, partial: URL, offset: Int64, hasher: SHA256,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> (hasher: SHA256, length: Int64) {
        var request = URLRequest(url: file.url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let writer = try FileHandle(forWritingTo: partial)
        try writer.truncate(atOffset: UInt64(offset))
        try writer.seekToEnd()
        let sink = StreamSink(
            path: file.path, url: file.url, writer: writer, hasher: hasher, offset: offset,
            expectedSize: file.size, onBytes: onBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                sink.setContinuation(cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// URLSession delegate that appends each chunk to the partial file and feeds it to SHA-256.
/// All callbacks arrive on one serial delegate queue.
private final class StreamSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let path: String
    let url: URL
    let writer: FileHandle
    var hasher: SHA256
    var length: Int64
    let startOffset: Int64
    let expectedSize: Int64
    let onBytes: @Sendable (Int64) -> Void
    var failure: Error?
    var lastReported: Int64 = 0
    private var continuation: CheckedContinuation<(hasher: SHA256, length: Int64), Error>?
    private let lock = NSLock()

    init(path: String, url: URL, writer: FileHandle, hasher: SHA256, offset: Int64, expectedSize: Int64,
         onBytes: @escaping @Sendable (Int64) -> Void) {
        self.path = path
        self.url = url
        self.writer = writer
        self.hasher = hasher
        self.length = offset
        self.startOffset = offset
        self.expectedSize = expectedSize
        self.onBytes = onBytes
    }

    func setContinuation(_ c: CheckedContinuation<(hasher: SHA256, length: Int64), Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 206 where startOffset > 0:
            // Content-Range must start exactly where the partial ends.
            let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard range.hasPrefix("bytes \(startOffset)-") else {
                failure = ModelStoreError.io("unexpected Content-Range '\(range)' resuming \(path) at \(startOffset)")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        case 200:
            if startOffset > 0 {
                // Server ignored the Range header: start over from byte 0.
                do {
                    try writer.truncate(atOffset: 0)
                    try writer.seek(toOffset: 0)
                } catch {
                    failure = error
                    completionHandler(.cancel)
                    return
                }
                hasher = SHA256()
                length = 0
            }
            completionHandler(.allow)
        default:
            failure = ModelStoreError.httpStatus(status, url: url)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        if length + Int64(data.count) > expectedSize {
            failure = ModelStoreError.sizeMismatch(
                path: path, expected: expectedSize, actual: length + Int64(data.count))
            dataTask.cancel()
            return
        }
        do {
            try writer.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        length += Int64(data.count)
        if length - lastReported >= 1 << 20 || length == expectedSize {
            lastReported = length
            onBytes(length)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? writer.synchronize()
        try? writer.close()
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let failure {
            c?.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                c?.resume(throwing: CancellationError())
            } else {
                c?.resume(throwing: error)
            }
        } else {
            c?.resume(returning: (hasher, length))
        }
    }
}
