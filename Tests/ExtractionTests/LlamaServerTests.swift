import Foundation
import Testing
@testable import Extraction

@Suite struct UnixSocketHTTPParsing {
    @Test func parsesContentLengthResponse() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
        let r = try UnixSocketHTTP.parse(raw)
        #expect(r.status == 200)
        #expect(String(decoding: r.body, as: UTF8.self) == "ok")
    }

    @Test func dechunksChunkedResponse() throws {
        let raw = Data("HTTP/1.1 401 Unauthorized\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\n\r\n".utf8)
        let r = try UnixSocketHTTP.parse(raw)
        #expect(r.status == 401)
        #expect(String(decoding: r.body, as: UTF8.self) == "Wikipedia")
    }

    @Test func rejectsGarbage() {
        #expect(throws: UnixSocketHTTP.Failure.self) { try UnixSocketHTTP.parse(Data("nope".utf8)) }
    }
}

/// Launches the real sidecar with the default model: slow (model load) and needs the weights,
/// so it only runs with SCRIBESKI_LLM_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SCRIBESKI_LLM_TESTS"] != nil))
struct LlamaServerLifecycle {
    @Test func startsLockedDownAnswersAndCleansUp() async throws {
        let server = LlamaServer(try .fromModelStore())
        let client = try await server.start() // throws if /slots, the web UI, or keyless access work
        let socketDir = URL(fileURLWithPath: client.http.socketPath).deletingLastPathComponent()
        let attrs = try FileManager.default.attributesOfItem(atPath: socketDir.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: socketDir.appendingPathComponent("key").path),
                "key file is removed once the server has read it")

        let reply = try await client.complete(ChatRequest(
            messages: [ChatMessage(role: "user", content: "Reply with the single word OK.")], maxTokens: 5))
        #expect(reply.content.localizedCaseInsensitiveContains("ok"))

        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: socketDir.path))
    }
}
