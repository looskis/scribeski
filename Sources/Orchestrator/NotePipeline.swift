import Extraction
import FormDriver
import Foundation
import ScribeskiCore

/// Transcript in, filled chart out (BUILD_PLAN P1.7, P3.1–P3.2). Independent of capture: it
/// takes any `Transcript`, live or from a file.
///
/// 1. Extract against the learned form (profile + mapping). The page needn't be open: the
///    locked-down LLM sidecar starts now, after the call, and stops as soon as it's done,
///    which erases its KV cache, the last copy of the transcript outside our process.
/// 2. Fill the bound client's tab: bring it forward, re-profile it (the form must not have
///    changed), and write only if its banner still names that client. Read-back follows.
///
/// Submitting the form stays the worker's own action.
public struct NotePipeline: Sendable {
    public enum Stage: String, Sendable {
        case profiling, loadingModel, extracting, filling
    }

    /// What extraction produced, waiting for the worker to confirm the fill target.
    public struct Extraction: Codable, Sendable {
        public var pageTitle: String
        public var profile: FormProfile
        public var results: [FieldResult]
        public var seconds: [String: Double]
        /// The chart the notes are for. Nil until the worker picks one (bound at fill).
        public var binding: ChartBinding?
        /// The session type the notes were written for; decides which on-file values may be
        /// proposed as changes in review.
        public var template: NoteTemplate?

        public init(pageTitle: String, profile: FormProfile, results: [FieldResult],
                    seconds: [String: Double] = [:], binding: ChartBinding? = nil, template: NoteTemplate? = nil) {
            self.pageTitle = pageTitle
            self.profile = profile
            self.results = results
            self.seconds = seconds
            self.binding = binding
            self.template = template
        }
    }

    public struct Outcome: Codable, Sendable {
        public var pageTitle: String
        public var profileFingerprint: String
        public var results: [FieldResult]
        public var reports: [FillReport]
        /// Requests the page made while we filled. Non-zero may mean the EHR autosaved.
        public var pageNetworkRequests: Int
        /// "verified": the banner named the bound client. "unchecked": no chart spec learned.
        public var identity: String
        public var seconds: [String: Double]
    }

    public enum Failure: Error, CustomStringConvertible {
        case formNotLearned(title: String, fingerprint: String)
        case formChanged(form: String, drift: FormDrift?)
        case chartNotOpen(ChartBinding)
        case wrongTarget(expected: String, found: String)

        public var description: String {
            switch self {
            case .formNotLearned(let title, let fp):
                "“\(title)” isn't a form Scribeski has learned (\(fp.prefix(19))…). Learn it first, "
                    + "or bring the right tab to the front."
            case .formChanged(let form, let drift):
                "“\(form)” has changed since it was learned" + (drift.map { ": \($0.summary)." } ?? ". Re-learn it before filling.")
            case .chartNotOpen(let b):
                "The chart for \(b.display) isn't open in Safari. Open it, then fill again."
            case .wrongTarget(let expected, let found):
                "The front tab is “\(found)”, not the form the notes were written for (“\(expected)”). "
                    + "Bring that form to the front and fill again."
            }
        }
    }

    public var llm: LlamaServer.Configuration
    public var forms: FormLibrary
    public var concurrency = 1

    public init(llm: LlamaServer.Configuration, forms: FormLibrary = FormLibrary()) {
        self.llm = llm
        self.forms = forms
    }

    // MARK: - Extract (no page needed)

    /// Extracts against a learned form. Fills nothing and touches no page.
    public func extract(transcript: Transcript, form: LearnedForm, binding: ChartBinding?,
                        template: NoteTemplate? = nil,
                        progress: @Sendable (Stage) -> Void = { _ in }) async throws -> Extraction {
        let template = template ?? form.templates[0]
        let mapping = template.apply(to: form.mapping)
        var seconds: [String: Double] = [:]
        progress(.loadingModel)
        let server = LlamaServer(llm)
        defer { server.stop() }
        let client = try await Self.timed("load_model", &seconds) { try await server.start() }

        progress(.extracting)
        let extractor = Extractor(client: client, model: llm.modelName, concurrency: concurrency)
        let results = try await Self.timed("extract", &seconds) {
            try await extractor.extract(transcript: transcript, profile: form.profile, mapping: mapping)
        }
        server.stop() // the transcript leaves the sidecar's memory as soon as we're done with it
        return Extraction(pageTitle: form.name, profile: form.profile, results: results, seconds: seconds,
                          binding: binding, template: template)
    }

    // MARK: - Fill the bound chart

    /// Brings the chart's tab forward, checks it's still the learned form, and writes only if
    /// its banner names the bound client (checked in the page, just before writing).
    public func fill(_ extraction: Extraction, at chart: ChartCandidate,
                     progress: @Sendable (Stage) -> Void = { _ in }) async throws -> Outcome {
        var seconds = extraction.seconds
        progress(.filling)
        let (session, profile, identity) = try await open(chart)
        let fill = try await Self.timed("fill", &seconds) {
            try await session.fill(profile: profile, results: extraction.results, identity: identity)
        }
        return Outcome(pageTitle: chart.tab.title, profileFingerprint: profile.fingerprint, results: extraction.results,
                       reports: fill.reports, pageNetworkRequests: fill.network.requests,
                       identity: fill.identity, seconds: seconds)
    }

    /// "Show in form": opens the field's step and scrolls to it. Changes nothing.
    public func focus(key: String, at chart: ChartCandidate) async throws {
        let (session, profile, _) = try await open(chart)
        try await session.focus(profile: profile, key: key)
    }

    /// Writes the worker's own value for one field, replacing whatever is there.
    public func write(key: String, value: FieldValue, at chart: ChartCandidate) async throws -> FillReport? {
        let (session, profile, identity) = try await open(chart)
        let outcome = try await session.fill(profile: profile, results: [FieldResult(key: key, status: .filled, value: value)],
                                             identity: identity, overwrite: [key], settleMs: 300)
        return outcome.reports.first
    }

    /// Puts every field back the way it was before Scribeski wrote to it.
    public func undo(reports: [FillReport], at chart: ChartCandidate) async throws -> [PageSession.UndoResult] {
        let (session, profile, _) = try await open(chart)
        return try await session.undo(profile: profile, reports: reports)
    }

    /// A session on the chart's own tab (not whatever is in front), after bringing it forward
    /// and checking the form hasn't changed. The identity guard is checked by the page itself
    /// at write time, so a tab switched to another client in between still writes nothing.
    private func open(_ chart: ChartCandidate) async throws -> (PageSession, FormProfile, PageSession.Identity?) {
        try? SafariTabs.bringToFront(chart.tab)
        let session = try PageSession(transport: ScriptingBridgeSafari(tab: chart.tab), bundleSource: PageSession.loadBundle())
        let profile = try await session.profile()
        guard profile.fingerprint == chart.binding.fingerprint, let form = forms.form(fingerprint: profile.fingerprint) else {
            throw Failure.formChanged(form: chart.binding.formName,
                                      drift: forms.form(fingerprint: chart.binding.fingerprint).map { FormDrift.rematch($0, to: profile) })
        }
        let identity = form.mapping.chart.map {
            PageSession.Identity(selector: $0.bannerSelector, expected: chart.binding.clientID)
        }
        return (session, profile, identity)
    }

    // MARK: - Front tab (the CLI's `note`)

    /// Profiles the front tab, extracts, and fills it: no confirmation in between. The client
    /// is read from the banner first when the form has a chart spec, and enforced at fill.
    public func run(transcript: Transcript, progress: @Sendable (Stage) -> Void = { _ in }) async throws -> Outcome {
        progress(.profiling)
        let front = try SafariTabs.list().first(where: \.isFront)
        let session = try PageSession(transport: front.map(ScriptingBridgeSafari.init(tab:)) ?? ScriptingBridgeSafari(),
                                      bundleSource: PageSession.loadBundle())
        let title = (try? session.evaluate("document.title") as? String) ?? "the front tab"
        let profile = try await session.profile()
        guard let form = forms.form(fingerprint: profile.fingerprint) else {
            throw Failure.formNotLearned(title: title, fingerprint: profile.fingerprint)
        }
        var binding: ChartBinding?
        if let chart = form.mapping.chart, let front,
           let client = chart.client(inBanner: (try? ChartFinder.bannerText(front, chart.bannerSelector)) ?? "") {
            binding = ChartBinding(fingerprint: form.fingerprint, formName: form.name, clientID: client.id, clientName: client.name)
        }
        let extraction = try await extract(transcript: transcript, form: form, binding: binding, progress: progress)
        progress(.filling)
        let identity = binding.flatMap { b in form.mapping.chart.map { PageSession.Identity(selector: $0.bannerSelector, expected: b.clientID) } }
        var seconds = extraction.seconds
        let fill = try await Self.timed("fill", &seconds) {
            try await session.fill(profile: profile, results: extraction.results, identity: identity)
        }
        return Outcome(pageTitle: title, profileFingerprint: profile.fingerprint, results: extraction.results,
                       reports: fill.reports, pageNetworkRequests: fill.network.requests,
                       identity: fill.identity, seconds: seconds)
    }

    private static func timed<T>(_ name: String, _ seconds: inout [String: Double],
                                 _ body: () async throws -> T) async throws -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        let d = clock.now - start
        seconds[name] = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return value
    }
}
