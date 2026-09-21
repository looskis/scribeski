import Foundation
import ScribeskiCore

/// Typed wrappers over the page bundle's profile / fill / undo commands.
extension PageSession {
    public func profile() async throws(Error) -> FormProfile {
        let raw = try await run(["op": "profile"])
        return try decode(FormProfile.self, raw)
    }

    public struct FillOutcome: Decodable, Sendable {
        public struct Network: Decodable, Sendable {
            public var requests: Int
            public var urls: [String]
        }

        public var reports: [FillReport]
        public var network: Network
        /// `verified` or `unchecked`.
        public var identity: String
        public var highlight: String
    }

    public struct Identity: Sendable {
        public var selector: String
        public var expected: String

        public init(selector: String, expected: String) {
            self.selector = selector
            self.expected = expected
        }
    }

    /// Fills the page from extraction results.
    ///
    /// Only what the page needs crosses the bridge: `filled` results become `{key, status,
    /// value}` with no evidence, and `derived` results become expectations the page's own
    /// computed fields are checked against. Quotes never reach the EHR page.
    /// `overwrite`: keys the worker edited in the review panel. Their value replaces whatever
    /// the field holds; never pass machine-written keys here.
    public func fill(profile: FormProfile, results: [FieldResult], identity: Identity?,
                     overwrite: [String] = [], settleMs: Int = 1000) async throws(Error) -> FillOutcome {
        var command: [String: Any] = [
            "op": "fill",
            "profile": try jsonObject(profile),
            "results": results.filter { $0.status == .filled && $0.value != nil }.map {
                ["key": $0.key, "status": "filled", "value": Self.plain($0.value!), "evidence": [] as [Any]]
            },
            "derived": Dictionary(uniqueKeysWithValues: results.filter { $0.status == .derived }.map {
                ($0.key, $0.value.map(Self.plain) ?? NSNull())
            }),
            "settle_ms": settleMs,
        ]
        if !overwrite.isEmpty { command["overwrite"] = overwrite }
        if let identity { command["identity"] = ["selector": identity.selector, "expected": identity.expected] }
        let raw = try await run(command, timeout: .seconds(60))
        return try decode(FillOutcome.self, raw)
    }

    public struct BannerCandidate: Decodable, Sendable, Hashable {
        public var selector: String
        public var text: String

        public init(selector: String, text: String) {
            self.selector = selector
            self.text = text
        }
    }

    /// Elements that probably name whose record is open (learn-form only). Their text shows
    /// on the worker's screen to pick from and never leaves the Mac.
    public func bannerCandidates() async throws(Error) -> [BannerCandidate] {
        try decode([BannerCandidate].self, try await run(["op": "banner_candidates"], timeout: .seconds(10)))
    }

    /// Opens the field's step, scrolls to it, and focuses it. Changes no value. With
    /// `identity`, only on the bound client's chart.
    public func focus(profile: FormProfile, key: String, identity: Identity? = nil) async throws(Error) {
        var command: [String: Any] = ["op": "focus", "profile": try jsonObject(profile), "key": key]
        if let identity { command["identity"] = ["selector": identity.selector, "expected": identity.expected] }
        _ = try await run(command, timeout: .seconds(10))
    }

    /// Restores each field to the value it had before `reports` were written: only on the
    /// bound client's chart (`identity`), and only fields still holding what was written.
    public func undo(profile: FormProfile, reports: [FillReport], identity: Identity?) async throws(Error) -> [UndoResult] {
        var command: [String: Any] = ["op": "undo", "profile": try jsonObject(profile), "reports": try jsonObject(reports)]
        if let identity { command["identity"] = ["selector": identity.selector, "expected": identity.expected] }
        let raw = try await run(command, timeout: .seconds(60))
        struct Response: Decodable { var results: [UndoResult] }
        return try decode(Response.self, raw).results
    }

    public struct UndoResult: Decodable, Sendable {
        public var key: String
        /// restored | failed | unrestorable | not_found | changed_since (left alone: it no
        /// longer holds what Scribeski wrote).
        public var outcome: String
    }

    private static func plain(_ v: FieldValue) -> Any {
        switch v {
        case .single(let s): s
        case .multiple(let a): a
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws(Error) -> Any {
        do {
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        } catch {
            throw .badResponse("unencodable \(T.self)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ raw: Any?) throws(Error) -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: raw ?? NSNull(), options: [.fragmentsAllowed])
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .badResponse("\(T.self): \(error)")
        }
    }
}
