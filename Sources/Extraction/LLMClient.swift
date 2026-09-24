import Foundation

/// One chat message. `role` is `system`, `user`, or `assistant`.
public struct ChatMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// A chat-completion request, independent of transport.
public struct ChatRequest: Hashable, Sendable {
    public var messages: [ChatMessage]
    /// A `response_format` object (see `SchemaBuilder.responseFormat`), or nil.
    public var responseFormat: JSONValue?
    public var maxTokens: Int?

    public init(messages: [ChatMessage], responseFormat: JSONValue? = nil, maxTokens: Int? = nil) {
        self.messages = messages
        self.responseFormat = responseFormat
        self.maxTokens = maxTokens
    }
}

/// What came back, with the timings the cache assertion needs.
public struct ChatResponse: Hashable, Sendable {
    public var content: String
    /// Prompt tokens actually evaluated (not served from the prefix cache). From llama-server
    /// `timings.prompt_n`, else `usage.prompt_tokens - cached_tokens`, else `prompt_tokens`.
    public var prefillTokens: Int?
    /// Prompt tokens reused from the cache (`timings.cache_n`), when reported.
    public var cachedTokens: Int?
    /// Generated tokens (`timings.predicted_n` or `usage.completion_tokens`).
    public var predictedTokens: Int?
    /// Wall-clock milliseconds for the HTTP round trip.
    public var ms: Int

    public init(content: String, prefillTokens: Int? = nil, cachedTokens: Int? = nil,
                predictedTokens: Int? = nil, ms: Int = 0) {
        self.content = content
        self.prefillTokens = prefillTokens
        self.cachedTokens = cachedTokens
        self.predictedTokens = predictedTokens
        self.ms = ms
    }
}

/// Anything that can answer a chat request: llama-server, a cloud endpoint, or a test fake.
public protocol LLMClient: Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResponse
}

public enum LLMClientError: Error, Hashable, Sendable, CustomStringConvertible {
    case http(status: Int, body: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .http(let status, let body): "HTTP \(status): \(body.prefix(500))"
        case .malformedResponse(let why): "malformed response: \(why)"
        }
    }
}

/// OpenAI-compatible `POST /v1/chat/completions`, tuned for llama-server.
///
/// Sends `temperature: 0`, `cache_prompt: true` (llama-server prefix reuse), and
/// `chat_template_kwargs: {enable_thinking: false}` (keeps reasoning-capable templates from
/// emitting thinking tokens, which the grammar would reject). Servers that don't know
/// those keys ignore them.
public struct OpenAIChatClient: LLMClient {
    public var endpoint: URL
    public var model: String
    public var apiKey: String?
    public var timeout: TimeInterval
    let session: URLSession

    public init(endpoint: URL, model: String, apiKey: String? = nil,
                timeout: TimeInterval = 300, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    /// `{endpoint}/v1/chat/completions`; an endpoint already ending in `/v1` is not doubled.
    public var completionsURL: URL {
        var base = endpoint.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return URL(string: base + "/chat/completions")!
    }

    /// The exact JSON body sent for `request`.
    public func body(for request: ChatRequest) -> JSONValue {
        var o = JSONObject()
        o["model"] = .string(model)
        o["messages"] = .array(request.messages.map {
            .obj(["role": .string($0.role), "content": .string($0.content)])
        })
        o["temperature"] = 0
        if let maxTokens = request.maxTokens { o["max_tokens"] = .int(maxTokens) }
        if let rf = request.responseFormat { o["response_format"] = rf }
        o["cache_prompt"] = true
        o["chat_template_kwargs"] = .obj(["enable_thinking": false])
        return .object(o)
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        var http = URLRequest(url: completionsURL, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        http.httpBody = body(for: request).serializedData()

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: http)
        let elapsed = clock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw LLMClientError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.parse(data, ms: ms)
    }

    /// Parses an OpenAI-style completion, reading llama-server `timings` when present.
    public static func parse(_ data: Data, ms: Int) throws -> ChatResponse {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch {
            throw LLMClientError.malformedResponse("not JSON")
        }
        guard let content = json["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue else {
            throw LLMClientError.malformedResponse("no choices[0].message.content")
        }
        let timings = json["timings"]
        let usage = json["usage"]
        let promptTotal = usage?["prompt_tokens"]?.intValue
        let usageCached = usage?["prompt_tokens_details"]?["cached_tokens"]?.intValue
        let cached = timings?["cache_n"]?.intValue ?? usageCached
        var prefill = timings?["prompt_n"]?.intValue
        if prefill == nil, let promptTotal {
            prefill = promptTotal - (usageCached ?? 0)
        }
        let predicted = timings?["predicted_n"]?.intValue ?? usage?["completion_tokens"]?.intValue
        return ChatResponse(content: content, prefillTokens: prefill, cachedTokens: cached,
                            predictedTokens: predicted, ms: ms)
    }
}
