import Foundation
import JavaScriptCore
import Testing
@testable import FormDriver

/// A transport backed by JavaScriptCore with a minimal `window`, so the real page bundle's
/// install, version guard, and job protocol run without Safari.
final class JSCTransport: JSTransport, @unchecked Sendable {
    let context: JSContext
    var calls = 0

    init() {
        context = JSContext()!
        // Just enough DOM for the bundle's install step (it scans for comboboxes and frames).
        context.evaluateScript("""
            var window = this; var location = {origin: 'jsc://test', pathname: '/'};
            var document = {querySelectorAll: function () { return []; }, querySelector: function () { return null; }};
            """)
    }

    func evaluate(_ script: String) throws(TransportError) -> String {
        calls += 1
        context.exception = nil
        let value = context.evaluateScript(script)
        if let e = context.exception { throw .scriptError(e.toString()) }
        return value?.toString() ?? ""
    }
}

@Suite struct PageSessionTests {
    let bundle: String

    init() throws {
        bundle = try PageSession.loadBundle()
    }

    @Test func bundleVersionComesFromBanner() throws {
        let session = try PageSession(transport: JSCTransport(), bundleSource: bundle)
        #expect(session.bundleVersion.split(separator: ".").count == 3)
    }

    @Test func installsOnceThenRespectsVersionGuard() throws {
        let session = try PageSession(transport: JSCTransport(), bundleSource: bundle)
        #expect(try session.ensureInstalled())
        #expect(try !session.ensureInstalled())
    }

    @Test func runsAJobThroughStartAndPoll() async throws {
        let session = try PageSession(transport: JSCTransport(), bundleSource: bundle)
        let result = try await session.run(["op": "ping"]) as? [String: Any]
        #expect(result?["pong"] as? Bool == true)
        #expect(result?["url"] as? String == "jsc://test/")
    }

    @Test func pageErrorsSurfaceAsJobErrors() async throws {
        let session = try PageSession(transport: JSCTransport(), bundleSource: bundle)
        await #expect(throws: PageSession.Error.self) {
            try await session.run(["op": "no_such_op"])
        }
    }

    @Test func expressionExceptionsDoNotBecomeTransportErrors() throws {
        let session = try PageSession(transport: JSCTransport(), bundleSource: bundle)
        do {
            _ = try session.evaluate("undefinedThing.x")
            Issue.record("expected an error")
        } catch {
            guard case .job = error else { Issue.record("wrong error: \(error)"); return }
        }
    }

    @Test(arguments: ["plain", "quote \" and \\ backslash", "line\nbreak", "unicode — ✓ \u{2028}"])
    func jsStringRoundTrips(_ s: String) throws {
        let t = JSCTransport()
        #expect(try t.evaluate(PageSession.jsString(s)) == s)
    }

    @Test func versionComparison() {
        #expect(PageSession.isNewer("0.1.0", than: "0.0.9"))
        #expect(!PageSession.isNewer("0.0.1", than: "0.0.1"))
        #expect(!PageSession.isNewer("0.0.1", than: "0.1"))
    }

    @Test func classifiesSafariErrors() {
        let off = "You must enable the 'Allow JavaScript from Apple Events' option in Safari's Develop menu to use 'do JavaScript'."
        #expect(TransportError.classify(message: off, code: 8) == .javaScriptFromAppleEventsDisabled)
        // Safari 27 wording; Safari 26 said "…option in Safari's Develop menu…". Match the stable part.
        let off27 = "You must enable 'Allow JavaScript from Apple Events' in the Developer section of Safari Settings to use 'do JavaScript'."
        #expect(TransportError.classify(message: off27, code: 8) == .javaScriptFromAppleEventsDisabled)
        #expect(TransportError.classify(message: "x", code: -1743) == .automationNotPermitted)
        #expect(TransportError.classify(message: "Safari got an error: AppleEvent timed out.", code: -1712) == .timedOut)
    }
}

@Suite struct OpenedTabCheck {
    /// `open` only returns a tab that shows the address asked for, never just "the front tab".
    @Test func sameAddressIgnoresFragmentAndTrailingSlashOnly() {
        let url = URL(string: "http://127.0.0.1:8787/risk.html")!
        #expect(SafariTabs.sameAddress("http://127.0.0.1:8787/risk.html#top", url))
        #expect(SafariTabs.sameAddress("http://127.0.0.1:8787/risk.html/", url))
        #expect(!SafariTabs.sameAddress("http://127.0.0.1:8787/index.html", url), "the front tab isn't it")
        #expect(!SafariTabs.sameAddress("https://127.0.0.1:8787/risk.html", url))
        #expect(!SafariTabs.sameAddress("http://127.0.0.1:9999/risk.html", url))
    }
}
