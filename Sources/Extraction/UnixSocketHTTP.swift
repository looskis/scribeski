import Foundation
import Network

/// Minimal HTTP/1.1 over a unix domain socket (BUILD_PLAN P3.2). URLSession can't reach
/// unix sockets, and a socket in a 0700 directory beats a loopback port: no other user on
/// the Mac can connect, and nothing listens on TCP at all.
///
/// One request per connection (`Connection: close`), response read to EOF. That's all
/// llama-server needs for non-streaming completions.
public struct UnixSocketHTTP: Sendable {
    public let socketPath: String
    public var timeout: Duration

    public init(socketPath: String, timeout: Duration = .seconds(300)) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data
    }

    public enum Failure: Error, CustomStringConvertible {
        case connection(String)
        case malformed
        case timedOut

        public var description: String {
            switch self {
            case .connection(let m): "LLM socket: \(m)"
            case .malformed: "LLM socket: malformed HTTP response"
            case .timedOut: "LLM socket: timed out"
            }
        }
    }

    public func request(_ method: String, _ path: String, headers: [String: String] = [:],
                        body: Data? = nil) async throws -> Response {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        let payload = Data(head.utf8) + (body ?? Data())

        let raw = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await exchange(payload) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return try Self.parse(raw)
    }

    private func exchange(_ payload: Data) async throws -> Data {
        let exchange = Exchange(socketPath: socketPath, payload: payload)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { exchange.start($0) }
        } onCancel: {
            exchange.cancel()
        }
    }

    /// One request on one connection. Every callback runs on `queue`, so state needs no lock.
    private final class Exchange: @unchecked Sendable {
        let connection: NWConnection
        let payload: Data
        let queue = DispatchQueue(label: "com.looski.scribeski.llm-socket")
        var data = Data()
        var continuation: CheckedContinuation<Data, Error>?

        init(socketPath: String, payload: Data) {
            connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            self.payload = payload
        }

        func start(_ continuation: CheckedContinuation<Data, Error>) {
            queue.async { [self] in
                self.continuation = continuation
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        connection.send(content: payload, completion: .contentProcessed { [self] error in
                            if let error { finish(.failure(Failure.connection("\(error)"))) }
                        })
                        receive()
                    case .failed(let error), .waiting(let error):
                        finish(.failure(Failure.connection("\(error)")))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] chunk, _, isComplete, error in
                if let chunk { data.append(chunk) }
                if let error { return finish(.failure(Failure.connection("\(error)"))) }
                if isComplete { return finish(.success(data)) }
                receive()
            }
        }

        func finish(_ result: Result<Data, Error>) {
            guard let c = continuation else { return }
            continuation = nil
            c.resume(with: result)
            connection.cancel()
        }

        func cancel() {
            queue.async { [self] in finish(.failure(CancellationError())) }
        }
    }

    /// Status line, headers, then a body that's either chunked or everything to EOF.
    static func parse(_ raw: Data) throws -> Response {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.malformed }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { throw Failure.malformed }
        var body = Data(raw[split.upperBound...])
        let chunked = lines.dropFirst().contains {
            $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked")
        }
        if chunked { body = try dechunk(body) }
        return Response(status: status, body: body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { throw Failure.malformed }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw Failure.malformed }
            if size == 0 { break }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size else { throw Failure.malformed }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}

/// `LLMClient` for llama-server on a unix socket. Same request body and response parsing as
/// `OpenAIChatClient`; only the transport differs.
public struct UnixSocketChatClient: LLMClient {
    public let http: UnixSocketHTTP
    public let apiKey: String
    private let format: OpenAIChatClient

    public init(socketPath: String, model: String, apiKey: String, timeout: Duration = .seconds(300)) {
        http = UnixSocketHTTP(socketPath: socketPath, timeout: timeout)
        self.apiKey = apiKey
        format = OpenAIChatClient(endpoint: URL(string: "http://localhost")!, model: model)
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await http.request(
            "POST", "/v1/chat/completions",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(apiKey)"],
            body: format.body(for: request).serializedData())
        let elapsed = clock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        guard (200..<300).contains(response.status) else {
            throw LLMClientError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        return try OpenAIChatClient.parse(response.body, ms: ms)
    }
}
