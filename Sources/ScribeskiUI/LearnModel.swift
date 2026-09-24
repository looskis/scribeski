import Extraction
import FormDriver
import Foundation
import Observation
import Orchestrator
import ScribeskiCore

/// Learning a form (BUILD_PLAN P3.4, DESIGN §6): read the front tab's structure, pick the
/// client banner, preview exactly what goes to the mapping model, generate the mapping,
/// review it, save it as a learned form. Nothing here reads or keeps field values.
@MainActor @Observable public final class LearnModel {
    public enum Step: Int, CaseIterable { case read, banner, mapping, review, saved }

    public var step = Step.read
    public var error: String?
    public var busy: String?

    // Read
    /// The form's address, if the worker pasted one instead of bringing its tab forward.
    public var address = ""
    /// The pasted address isn't open in Safari: offer to open it.
    public var addressToOpen: URL?
    public var tab: SafariTab?
    public var profile: FormProfile?
    public var formName = ""
    /// The same page learned before, and how it differs now.
    public var existing: LearnedForm?
    public var drift: FormDrift?

    // Banner
    public var banners: [PageSession.BannerCandidate] = []
    public var bannerSelector: String?
    public var idPattern = ""
    public var namePattern = ""

    // Mapping
    public var payloadText = ""
    public var scrubReport = ""
    public var scrubOK = false
    public var mapping: FormMapping?

    @ObservationIgnored public var library: FormLibrary
    @ObservationIgnored let transportFor: @Sendable (SafariTab) -> any JSTransport

    public init(library: FormLibrary = FormLibrary(),
                transportFor: @escaping @Sendable (SafariTab) -> any JSTransport = { ScriptingBridgeSafari(tab: $0) }) {
        self.library = library
        self.transportFor = transportFor
    }

    /// Dev (`--demo-learn`): a learn session on files, at `step`, without Safari.
    public func loadDemo(profile: FormProfile, mapping: FormMapping, step: Step) {
        self.profile = profile
        tab = SafariTab(windowID: 1, tabIndex: 1, windowOrder: 1, isCurrentTab: true,
                        url: profile.origin + profile.pathPattern, title: mapping.name ?? "Form")
        formName = mapping.name ?? ""
        banners = [.init(selector: "#record_banner", text: "Record AB-114322 · REYES, Daniela"),
                   .init(selector: "xpath=/html/body/div[2]", text: "Previous client record closed: M. Okonkwo · 0042117")]
        chooseBanner("#record_banner")
        preparePayload()
        self.mapping = mapping
        self.step = step
    }

    // MARK: - Read

    /// Reads the tab the worker has in front.
    public func readFrontTab() async {
        do {
            guard let front = try SafariTabs.list().first(where: \.isFront) else { throw TransportError.noWindow }
            await read(front)
        } catch {
            self.error = "\(error)"
        }
    }

    /// Reads the tab showing the pasted address, or offers to open it.
    public func readAddress() async {
        error = nil
        addressToOpen = nil
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else {
            error = "That isn't a web address. Copy it from Safari's address bar (⌘L, then ⌘C)."
            return
        }
        guard let tab = ChartFinder.bestMatch(url, in: (try? SafariTabs.list()) ?? []) else {
            addressToOpen = url
            return
        }
        await read(tab)
    }

    /// Opens the pasted address (the worker asked), waits for it to load, and reads it.
    public func openAddress() async {
        guard let url = addressToOpen else { return }
        addressToOpen = nil
        busy = "Opening…"
        do {
            let tab = try await SafariTabs.open(url)
            let transport = transportFor(tab)
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(500))
                if (try? transport.evaluate("document.readyState")) == "complete" { break }
            }
            busy = nil
            await read(tab)
        } catch {
            busy = nil
            self.error = "\(error)"
        }
    }

    /// Reads one tab the worker chose (in front, or by address): the one kind of tab Scribeski
    /// injects into without it being a learned form, because the worker asked.
    func read(_ front: SafariTab) async {
        error = nil
        busy = "Reading the form…"
        defer { busy = nil }
        do {
            let session = try PageSession(transport: transportFor(front), bundleSource: PageSession.loadBundle())
            let profile = try await session.profile()
            tab = front
            self.profile = profile
            formName = front.title
            banners = (try? await session.bannerCandidates()) ?? []
            if let first = banners.first { chooseBanner(first.selector) }
            existing = library.forms().first { $0.profile.origin == profile.origin && $0.profile.pathPattern == profile.pathPattern }
            drift = existing.flatMap { $0.fingerprint == profile.fingerprint ? nil : FormDrift.rematch($0, to: profile) }
            if let existing { formName = existing.name }
        } catch {
            self.error = "\(error)"
        }
    }

    public var unreachableWarning: String? {
        guard let p = profile, !p.unreachable.isEmpty else { return nil }
        return "\(p.unreachable.count) part\(p.unreachable.count == 1 ? " is" : "s are") in another site's frame, "
            + "which Safari won't let Scribeski reach. Fields there can't be filled."
    }

    /// Already learned and unchanged: nothing to do.
    public var alreadyLearned: Bool { existing != nil && drift == nil }

    /// The page changed since it was learned: carry the reviewed mapping across.
    public func acceptDrift() {
        guard let drift, let existing else { return }
        do {
            try library.replace(existing.fingerprint, with: drift.form)
            step = .saved
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: - Banner

    public func chooseBanner(_ selector: String) {
        bannerSelector = selector
        guard let text = banners.first(where: { $0.selector == selector })?.text,
              let proposal = FormMapping.Chart.proposePatterns(from: text) else { return }
        idPattern = proposal.id
        namePattern = proposal.name ?? ""
    }

    public var chart: FormMapping.Chart? {
        guard let tab, let url = URL(string: tab.url), let scheme = url.scheme, let host = url.host(),
              let selector = bannerSelector, !idPattern.isEmpty else { return nil }
        return .init(origin: "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")", pathPattern: url.path(),
                     bannerSelector: selector, clientIDPattern: idPattern,
                     clientNamePattern: namePattern.isEmpty ? nil : namePattern)
    }

    /// What the chosen banner and patterns read on this page right now.
    public var bannerPreview: (id: String, name: String?)? {
        guard let chart, let text = banners.first(where: { $0.selector == chart.bannerSelector })?.text else { return nil }
        return chart.client(inBanner: text)
    }

    // MARK: - Mapping

    /// The exact payload the mapping model would receive, scrubbed. Nothing is sent yet.
    public func preparePayload() {
        guard let profile else { return }
        let (payload, report) = MapRun.prepare(options(for: profile))
        payloadText = MapRun.payloadText(payload)
        scrubReport = MapRun.reportText(report)
        scrubOK = report.ok
    }

    private func options(for profile: FormProfile) -> MapRun.Options {
        // Re-learning keeps what was already reviewed: only fields the old mapping lacks go out.
        MapRun.Options(profile: profile, base: drift?.form.mapping.withoutPlaceholders ?? existing?.mapping,
                       endpoint: URL(string: "http://localhost")!, yes: true)
    }

    /// Runs the local model on the payload shown. The sidecar starts for this and stops after.
    public func generate() async {
        guard let profile, scrubOK else { return }
        error = nil
        busy = "Loading the language model…"
        defer { busy = nil }
        let server: LlamaServer
        do {
            server = LlamaServer(try .fromModelStore())
            let client = try await server.start()
            busy = "Writing the mapping…"
            let outcome = await MapRun.run(options(for: profile), client: client)
            server.stop()
            guard let mapping = outcome.mapping else {
                throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: outcome.stderr])
            }
            self.mapping = mapping
            step = .review
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: - Save

    public func save() {
        guard let profile, var mapping else { return }
        mapping.name = formName.isEmpty ? nil : formName
        mapping.chart = chart
        do {
            if let existing { try library.replace(existing.fingerprint, with: LearnedForm(profile: profile, mapping: mapping,
                                                                                          templates: existing.templates)) }
            else { try library.install(LearnedForm(profile: profile, mapping: mapping)) }
            step = .saved
        } catch {
            self.error = "\(error)"
        }
    }
}

extension FormMapping {
    /// Drops the "not mapped yet" placeholders a drift re-match adds, so a re-learn sends
    /// exactly those fields to the model.
    var withoutPlaceholders: FormMapping {
        var m = self
        m.fields = m.fields.filter { $0.value.intent != "New field since this form was learned; not mapped yet." }
        return m
    }
}
