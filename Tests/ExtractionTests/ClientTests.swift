import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

/// Serves canned responses per host and records what was sent. No network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]

    static func stub(host: String, status: Int = 200, body: String) {
        lock.withLock { stubs[host] = Stub(status: status, body: Data(body.utf8)) }
    }

    static func requests(host: String) -> [URLRequest] { lock.withLock { captured[host] ?? [] } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            request.httpBody = data
        }
        let host = request.url?.host ?? ""
        let stub = Self.lock.withLock { () -> Stub? in
            Self.captured[host, default: []].append(request)
            return Self.stubs[host]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct OpenAIChatClientTests {
    static let llamaResponse = """
    {"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant",
     "content":"{\\"status\\":\\"filled\\",\\"evidence\\":[{\\"segment\\":\\"s0043\\",\\"quote\\":\\"She/her.\\"}],\\"value\\":\\"SHE_HER\\"}"}}],
     "usage":{"prompt_tokens":9120,"completion_tokens":31,"total_tokens":9151},
     "timings":{"cache_n":9084,"prompt_n":36,"prompt_ms":41.2,"predicted_n":31,"predicted_ms":402.0}}
    """

    @Test func sendsLlamaServerRequestAndParsesTimings() async throws {
        let host = "llama.stub.test"
        StubURLProtocol.stub(host: host, body: Self.llamaResponse)
        let client = OpenAIChatClient(endpoint: URL(string: "http://\(host):8080")!, model: "gemma-4-26b-a4b-qat-q4_0",
                                      apiKey: "sk-test", session: StubURLProtocol.session())
        let format = JSONValue.obj(["type": "json_schema", "json_schema": .obj(["name": "field_x", "strict": true,
                                                                                "schema": .obj(["type": "object"])])])
        let response = try await client.complete(ChatRequest(
            messages: [ChatMessage(role: "system", content: "rules + transcript"), ChatMessage(role: "user", content: "field")],
            responseFormat: format, maxTokens: 512))

        #expect(response.content.contains("SHE_HER"))
        #expect(response.prefillTokens == 36)
        #expect(response.cachedTokens == 9084)
        #expect(response.predictedTokens == 31)
        #expect(response.ms >= 0)

        let sent = try #require(StubURLProtocol.requests(host: host).last)
        #expect(sent.url?.absoluteString == "http://\(host):8080/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONValue.parse(try #require(sent.httpBody))
        #expect(body["model"] == "gemma-4-26b-a4b-qat-q4_0")
        #expect(body["temperature"] == 0)
        #expect(body["cache_prompt"] == true)
        #expect(body["chat_template_kwargs"]?["enable_thinking"] == false)
        #expect(body["max_tokens"] == 512)
        #expect(body["response_format"] == format)
        #expect(body["messages"]?.arrayValue?.map { $0["role"] } == ["system", "user"])
        #expect(body["messages"]?.arrayValue?.first?["content"] == "rules + transcript")
    }

    @Test func bodyKeyOrderIsStable() {
        let client = OpenAIChatClient(endpoint: URL(string: "http://127.0.0.1:8080/v1/")!, model: "m")
        let text = client.body(for: ChatRequest(messages: [ChatMessage(role: "user", content: "é \"q\"\n")])).serialized()
        #expect(text == #"{"model":"m","messages":[{"role":"user","content":"é \"q\"\n"}],"temperature":0,"cache_prompt":true,"chat_template_kwargs":{"enable_thinking":false}}"#)
        #expect(client.completionsURL.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
    }

    @Test func noApiKeyMeansNoAuthorizationHeader() async throws {
        let host = "nokey.stub.test"
        StubURLProtocol.stub(host: host, body: Self.llamaResponse)
        let client = OpenAIChatClient(endpoint: URL(string: "http://\(host)")!, model: "m", session: StubURLProtocol.session())
        _ = try await client.complete(ChatRequest(messages: [ChatMessage(role: "user", content: "x")]))
        #expect(StubURLProtocol.requests(host: host).last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func httpErrorThrows() async throws {
        let host = "error.stub.test"
        StubURLProtocol.stub(host: host, status: 500, body: #"{"error":"grammar failed"}"#)
        let client = OpenAIChatClient(endpoint: URL(string: "http://\(host)")!, model: "m", session: StubURLProtocol.session())
        await #expect(throws: LLMClientError.self) {
            _ = try await client.complete(ChatRequest(messages: [ChatMessage(role: "user", content: "x")]))
        }
    }

    @Test func openAIUsageFallback() throws {
        let data = Data(#"{"choices":[{"message":{"content":"{}"}}],"usage":{"prompt_tokens":1000,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":960}}}"#.utf8)
        let r = try OpenAIChatClient.parse(data, ms: 7)
        #expect(r.prefillTokens == 40)
        #expect(r.cachedTokens == 960)
        #expect(r.predictedTokens == 5)
        #expect(r.ms == 7)
    }
}
