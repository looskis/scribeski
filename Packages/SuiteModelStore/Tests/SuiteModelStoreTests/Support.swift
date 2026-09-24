import CryptoKit
import Foundation
@testable import SuiteModelStore

/// Deterministic pseudo-random bytes (xorshift), so tests never depend on fixtures or the network.
func deterministicBytes(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            p[i] = UInt8(truncatingIfNeeded: state)
        }
    }
    return data
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A fresh temp directory, removed by `cleanup()`.
struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuiteModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Per-test fake HTTP server, reached through `StubURLProtocol`. Each server gets its own host so
/// tests can run in parallel.
final class StubServer: @unchecked Sendable {
    struct Route {
        var body: Data
        var honorRange = true
        /// On the first request only, send this many bytes and then drop the connection.
        var dropFirstRequestAfter: Int?
        /// Delay between 64 KiB chunks (to make concurrent downloads overlap).
        var chunkDelay: TimeInterval = 0
        var status = 200
    }

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var requests: [String: [String?]] = [:]  // path -> Range headers seen

    init() { StubURLProtocol.register(self) }
    deinit { StubURLProtocol.unregister(host) }

    func url(_ path: String) -> URL { URL(string: "https://\(host)/\(path)")! }

    func serve(_ path: String, _ route: Route) {
        lock.lock(); routes["/" + path] = route; lock.unlock()
    }

    func serve(_ path: String, _ body: Data) { serve(path, Route(body: body)) }

    func rangeHeaders(_ path: String) -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return requests["/" + path] ?? []
    }

    func requestCount(_ path: String) -> Int { rangeHeaders(path).count }

    var totalRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.values.reduce(0) { $0 + $1.count }
    }

    /// Records the request and returns the route to serve plus whether this is its first request.
    func take(_ request: URLRequest) -> (Route, first: Bool)? {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        let first = (requests[path] ?? []).isEmpty
        requests[path, default: []].append(request.value(forHTTPHeaderField: "Range"))
        guard let route = routes[path] else { return nil }
        return (route, first)
    }

    /// A session configuration whose traffic goes to the stub.
    var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()
    private var stopped = false
    private let stopLock = NSLock()

    static func register(_ s: StubServer) { lock.lock(); servers[s.host] = s; lock.unlock() }
    static func unregister(_ host: String) { lock.lock(); servers[host] = nil; lock.unlock() }
    static func server(_ host: String) -> StubServer? { lock.lock(); defer { lock.unlock() }; return servers[host] }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.flatMap { $0.host() }.map { server($0) != nil } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var isStopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }

    override func startLoading() {
        let request = self.request
        guard let server = request.url?.host().flatMap(Self.server),
              let (route, first) = server.take(request) else {
            respond(status: 404, headers: [:], body: Data(), dropAfter: nil, delay: 0)
            return
        }
        var body = route.body
        var status = route.status
        var headers = ["Accept-Ranges": "bytes"]
        if route.honorRange, status == 200, let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="), range.hasSuffix("-"),
           let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            if start >= body.count {
                status = 416
                headers["Content-Range"] = "bytes */\(body.count)"
                body = Data()
            } else {
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
                body = body.subdata(in: start..<body.count)
            }
        }
        headers["Content-Length"] = "\(body.count)"
        let dropAfter = first ? route.dropFirstRequestAfter : nil
        let (finalStatus, finalHeaders, finalBody, delay) = (status, headers, body, route.chunkDelay)
        DispatchQueue.global().async {
            self.respond(status: finalStatus, headers: finalHeaders, body: finalBody, dropAfter: dropAfter, delay: delay)
        }
    }

    private func respond(status: Int, headers: [String: String], body: Data, dropAfter: Int?, delay: TimeInterval) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let limit = min(body.count, dropAfter ?? body.count)
        var offset = 0
        let chunk = 64 * 1024
        while offset < limit {
            if isStopped { return }
            let end = min(offset + chunk, limit)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        if dropAfter != nil && limit < body.count {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopLock.lock(); stopped = true; stopLock.unlock()
    }
}

/// Builds a manifest whose files are served by `server`.
func makeManifest(
    id: String, role: ModelRole = .llm, format: ModelFormat = .gguf, revision: String = "0123abcd",
    minRAMGB: Int = 1, validated: Bool = true, server: StubServer, files: [(path: String, data: Data)]
) -> ModelManifest {
    ModelManifest(
        id: id, displayName: id, role: role, format: format, revision: revision, license: "Apache-2.0",
        minRAMGB: minRAMGB,
        files: files.map { f in
            let routePath = "\(id)/\(revision)/\(f.path)"
            server.serve(routePath, f.data)
            return ModelFile(path: f.path, url: server.url(routePath), sha256: sha256Hex(f.data), size: Int64(f.data.count))
        },
        validated: validated)
}

/// Route path used by `makeManifest` for a file.
func routePath(_ m: ModelManifest, _ path: String) -> String { "\(m.id)/\(m.revision)/\(path)" }

func makeStore(_ dir: TempDir, _ server: StubServer, catalog: Catalog = Catalog(defaults: [:], models: []),
               available: Int64? = nil) throws -> ModelStore {
    try ModelStore(
        root: dir.url.appendingPathComponent("Models", isDirectory: true), catalog: catalog,
        sessionConfiguration: server.configuration, diskSpaceMargin: 0,
        availableCapacity: { _ in available })
}

func blobNames(_ store: ModelStore) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: store.blobsDirectory.path).sorted()
}
