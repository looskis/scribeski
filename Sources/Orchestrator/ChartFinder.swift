import FormDriver
import Foundation
import ScribeskiCore

/// Which client's chart a session belongs to (BUILD_PLAN P3.1). Chosen at Start and
/// confirmed by the worker; every fill and edit is refused unless the tab shows this client.
public struct ChartBinding: Codable, Hashable, Sendable {
    public var fingerprint: String
    public var formName: String
    public var clientID: String
    public var clientName: String?

    public init(fingerprint: String, formName: String, clientID: String, clientName: String?) {
        self.fingerprint = fingerprint
        self.formName = formName
        self.clientID = clientID
        self.clientName = clientName
    }

    /// "REYES, Daniela · AB-114322"
    public var display: String { clientName.map { "\($0) · \(clientID)" } ?? clientID }

    /// For a button: "Daniela R." from "REYES, Daniela", else the ID.
    public var shortName: String {
        guard let name = clientName else { return clientID }
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let last = parts[0].first {
            return "\(parts[1].split(separator: " ").first ?? "") \(last)."
        }
        let words = name.split(separator: " ")
        return words.count >= 2 ? "\(words[0]) \(words.last!.prefix(1))." : name
    }
}

/// A tab showing a learned form for a particular client.
public struct ChartCandidate: Hashable, Sendable, Identifiable {
    public var tab: SafariTab
    public var binding: ChartBinding
    public var id: String { "\(tab.windowID)/\(tab.tabIndex)" }

    public init(tab: SafariTab, binding: ChartBinding) {
        self.tab = tab
        self.binding = binding
    }
}

/// Finds charts open in Safari (BUILD_PLAN P3.1). Lists every tab by URL and title only; runs
/// JavaScript only in tabs whose URL is a learned form, and there only to read the banner.
/// No other tab is touched.
public struct ChartFinder: Sendable {
    public var forms: FormLibrary
    public var listTabs: @Sendable () throws -> [SafariTab]
    public var readBanner: @Sendable (SafariTab, String) throws -> String

    public init(forms: FormLibrary = FormLibrary(),
                listTabs: @escaping @Sendable () throws -> [SafariTab] = { try SafariTabs.list() },
                readBanner: @escaping @Sendable (SafariTab, String) throws -> String = ChartFinder.bannerText) {
        self.forms = forms
        self.listTabs = listTabs
        self.readBanner = readBanner
    }

    /// Every learned chart open in Safari: the tab the worker is looking at first, then by
    /// window order. Tabs whose banner can't be read or names no client are left out.
    public func candidates() -> [ChartCandidate] {
        let learned = forms.forms().filter { $0.mapping.chart != nil }
        guard !learned.isEmpty, let tabs = try? listTabs() else { return [] }
        return tabs.compactMap { tab -> ChartCandidate? in
            guard let form = learned.first(where: { $0.mapping.chart!.matches(tab.url) }),
                  let chart = form.mapping.chart,
                  let text = try? readBanner(tab, chart.bannerSelector),
                  let client = chart.client(inBanner: text) else { return nil }
            return ChartCandidate(tab: tab, binding: ChartBinding(fingerprint: form.fingerprint, formName: form.name,
                                                                   clientID: client.id, clientName: client.name))
        }
        .sorted { a, b in
            if a.tab.isFront != b.tab.isFront { return a.tab.isFront }
            if a.tab.windowOrder != b.tab.windowOrder { return a.tab.windowOrder < b.tab.windowOrder }
            return a.tab.tabIndex < b.tab.tabIndex
        }
    }

    /// Every open tab showing this exact chart (same form, same client), front one first.
    public func locateAll(_ binding: ChartBinding) -> [ChartCandidate] {
        candidates().filter { $0.binding.fingerprint == binding.fingerprint && $0.binding.clientID == binding.clientID }
    }

    /// The tab for this chart if exactly one shows it. With the same chart in two tabs the
    /// worker chooses (`locateAll`): a draft and a saved copy aren't interchangeable.
    public func locate(_ binding: ChartBinding) -> ChartCandidate? {
        let all = locateAll(binding)
        return all.count == 1 ? all[0] : nil
    }

    /// `tab` still shows this chart (tabs move and change between confirming and writing).
    public func stillShows(_ candidate: ChartCandidate) -> Bool {
        locateAll(candidate.binding).contains { $0.tab.windowID == candidate.tab.windowID && $0.tab.tabIndex == candidate.tab.tabIndex }
    }

    // MARK: - By address

    public enum AddressLookup: Sendable {
        /// Open in this tab, showing this client.
        case found(ChartCandidate)
        /// A learned form, but no tab has it open. Offer to open it.
        case notOpen(URL, formName: String)
        /// Open, but the banner names no client (not loaded yet, or the wrong page).
        case noClient(SafariTab)
        case notLearned(String)
        case notAnAddress(String)
    }

    /// A pasted address: which learned form it is, and which tab has it open. Only that
    /// tab's banner is read.
    public func lookup(_ text: String) -> AddressLookup {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return .notAnAddress(trimmed) }
        guard let form = forms.form(forURL: trimmed), let chart = form.mapping.chart else {
            return .notLearned(trimmed)
        }
        guard let tab = Self.bestMatch(url, in: (try? listTabs()) ?? []) else {
            return .notOpen(url, formName: form.name)
        }
        guard let text = try? readBanner(tab, chart.bannerSelector), let client = chart.client(inBanner: text) else {
            return .noClient(tab)
        }
        return .found(ChartCandidate(tab: tab, binding: ChartBinding(fingerprint: form.fingerprint, formName: form.name,
                                                                     clientID: client.id, clientName: client.name)))
    }

    /// Opens a learned form's address in Safari and waits (up to `timeout`) for its banner to
    /// name a client. Only called when the worker clicks Open.
    public func open(_ url: URL, timeout: Duration = .seconds(20)) async throws -> ChartCandidate {
        _ = try await SafariTabs.open(url)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if case .found(let c) = lookup(url.absoluteString) { return c }
        }
        throw NotePipeline.Failure.chartNotOpen(ChartBinding(fingerprint: "", formName: "", clientID: url.absoluteString,
                                                             clientName: nil))
    }

    /// The tab showing this address: the exact URL first, else the same page ignoring the
    /// fragment, else the same path ignoring the query. The front tab wins a tie.
    public static func bestMatch(_ url: URL, in tabs: [SafariTab]) -> SafariTab? {
        func key(_ u: URL, query: Bool) -> String? {
            guard let host = u.host() else { return nil }
            var path = u.path()
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return "\(u.scheme?.lowercased() ?? "")://\(host.lowercased()):\(u.port ?? -1)\(path)" + (query ? "?\(u.query() ?? "")" : "")
        }
        let ordered = tabs.sorted { a, b in a.isFront != b.isFront ? a.isFront : a.windowOrder < b.windowOrder }
        let parsed = ordered.compactMap { t in URL(string: t.url).map { (t, $0) } }
        if let exact = parsed.first(where: { $0.0.url == url.absoluteString }) { return exact.0 }
        for withQuery in [true, false] {
            let want = key(url, query: withQuery)
            if let m = parsed.first(where: { key($0.1, query: withQuery) == want }) { return m.0 }
        }
        return nil
    }

    /// Reads one element's text in one tab. The selector travels as a JSON string literal; CSS,
    /// or `xpath=…` as the page bundle's banner candidates write it (same rule as `queryAll`).
    @Sendable public static func bannerText(_ tab: SafariTab, _ selector: String) throws -> String {
        try ScriptingBridgeSafari(tab: tab).evaluate(bannerScript(selector))
    }

    static func bannerScript(_ selector: String) throws -> String {
        let literal = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
        return "(function(){var s=\(literal),e=null;try{"
            + "e=s.indexOf(\"xpath=\")===0"
            + "?document.evaluate(s.slice(6),document,null,9,null).singleNodeValue"
            + ":document.querySelector(s);}catch(x){}"
            + "return e?String(e.textContent):\"\";})()"
    }
}
