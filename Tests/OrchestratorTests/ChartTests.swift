import FormDriver
import Foundation
import ScribeskiCore
import Synchronization
import Testing
@testable import Orchestrator

let mockChart = FormMapping.Chart(origin: "http://127.0.0.1:8787", pathPattern: "/index.html",
                                  bannerSelector: "#record_banner", clientIDPattern: #"Record\s+([A-Z]{2}-\d{6})"#,
                                  clientNamePattern: #"·\s*(.+)$"#)

@Suite struct ChartSpec {
    @Test func matchesOriginAndPathOnly() {
        #expect(mockChart.matches("http://127.0.0.1:8787/index.html"))
        #expect(mockChart.matches("http://127.0.0.1:8787/index.html?tab=risk#top"))
        #expect(!mockChart.matches("http://127.0.0.1:8787/csp.html"))
        #expect(!mockChart.matches("https://127.0.0.1:8787/index.html"), "scheme is part of the origin")
        #expect(!mockChart.matches("http://evil.example/index.html"))
        let wild = FormMapping.Chart(origin: "https://ehr.example.org", pathPattern: "/clients/*/intake",
                                     bannerSelector: "#b", clientIDPattern: "(x)")
        #expect(wild.matches("https://ehr.example.org/clients/123/intake"))
        #expect(!wild.matches("https://ehr.example.org/clients/123/intake/print"))
    }

    @Test func readsClientFromTheBannerNotTheDecoy() {
        let c = mockChart.client(inBanner: "Record AB-114322 · REYES, Daniela")
        #expect(c?.id == "AB-114322")
        #expect(c?.name == "REYES, Daniela")
        #expect(mockChart.client(inBanner: "Previous client record closed: M. Okonkwo") == nil)
        #expect(mockChart.client(inBanner: "") == nil)
    }

    @Test func shortNames() {
        #expect(ChartBinding(fingerprint: "f", formName: "F", clientID: "AB-1", clientName: "REYES, Daniela").shortName == "Daniela R.")
        #expect(ChartBinding(fingerprint: "f", formName: "F", clientID: "AB-1", clientName: "Maria Reyes").shortName == "Maria R.")
        #expect(ChartBinding(fingerprint: "f", formName: "F", clientID: "AB-1", clientName: nil).shortName == "AB-1")
    }
}

/// A form library in a temp dir holding the mock EHR's learned form.
func mockLibrary() throws -> FormLibrary {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let profile = try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: root.appendingPathComponent("page/test/golden/mock-ehr.profile.json")))
    let mapping = try JSONDecoder().decode(FormMapping.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/mock-ehr/mapping.json")))
    let library = FormLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent("forms-\(UUID())"))
    try library.install(LearnedForm(profile: profile, mapping: mapping))
    return library
}

@Suite struct Finding {
    func tab(_ w: Int, _ t: Int, order: Int, current: Bool, _ url: String) -> SafariTab {
        SafariTab(windowID: w, tabIndex: t, windowOrder: order, isCurrentTab: current, url: url, title: "t")
    }

    @Test func readsBannersOnlyInLearnedFormsAndRanksTheFrontTabFirst() throws {
        let library = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let touched = Mutex<[String]>([])
        let tabs = [
            tab(10, 1, order: 1, current: false, "http://127.0.0.1:8787/index.html"),   // Maria, background tab
            tab(10, 2, order: 1, current: true, "https://claude.ai/artifact/abc"),      // not a form: never touched
            tab(20, 1, order: 2, current: true, "http://127.0.0.1:8787/index.html"),    // Sam, other window
            tab(30, 1, order: 3, current: true, "http://127.0.0.1:8787/index.html"),    // stale banner only
        ]
        let banners = [10: "Record AB-114322 · REYES, Daniela", 20: "Record AB-200001 · LEE, Sam",
                       30: "Previous client record closed: M. Okonkwo"]
        let finder = ChartFinder(forms: library, listTabs: { tabs }, readBanner: { t, _ in
            touched.withLock { $0.append(t.url) }
            return banners[t.windowID]!
        })
        let found = finder.candidates()
        #expect(found.map(\.binding.clientID) == ["AB-114322", "AB-200001"], "no banner, no candidate")
        #expect(!touched.withLock { $0 }.contains { $0.contains("claude.ai") }, "no JavaScript in other tabs")
        let sam = try #require(finder.locate(found[1].binding))
        #expect(sam.tab.windowID == 20)
    }

    @Test func sameClientInTwoTabsIsNeverGuessed() throws {
        let library = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let tabs = [tab(10, 1, order: 1, current: true, "http://127.0.0.1:8787/index.html"),
                    tab(20, 1, order: 2, current: true, "http://127.0.0.1:8787/index.html?draft=1")]
        let finder = ChartFinder(forms: library, listTabs: { tabs }, readBanner: { _, _ in "Record AB-114322 · REYES, Daniela" })
        let binding = try #require(finder.candidates().first?.binding)
        #expect(finder.locateAll(binding).count == 2)
        #expect(finder.locate(binding) == nil, "two tabs, one client: the worker chooses")
        #expect(finder.stillShows(finder.locateAll(binding)[1]))
    }
}

@Suite struct Templates {
    @Test func followUpSkipsWhatsOnFileAndMarksUpdatableFields() throws {
        let library = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let templates = try JSONDecoder().decode([NoteTemplate].self,
                                                 from: Data(contentsOf: root.appendingPathComponent("fixtures/mock-ehr/templates.json")))
        let base = try #require(library.forms().first)
        let form = LearnedForm(profile: base.profile, mapping: base.mapping, templates: templates)
        let followUp = form.template("follow-up")
        let m = followUp.apply(to: form.mapping)
        #expect(m.fields["client_dob"]?.mode == .skip, "identity is on file")
        #expect(m.fields["contact_phone"]?.mode == .discrete, "still extracted…")
        #expect(followUp.updatable.contains("contact_phone"), "…and proposed as a change")
        #expect(form.template("intake").apply(to: form.mapping) == form.mapping, "intake is the base mapping")
        #expect(form.template("no-such").id == "intake", "unknown falls back to the first")
    }

    @Test func formWithoutTemplatesHasStandard() throws {
        let library = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        #expect(library.forms().first?.templates.map(\.id) == ["standard"])
    }

    @Test func packsRoundTripAndRefuseMismatchedForms() throws {
        let source = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let pack = source.exportPack(name: "Riverside HSA", version: "2026.09")
        let data = try JSONEncoder().encode(pack)
        let target = FormLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent("forms-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: target.directory) }
        #expect(try target.importPack(JSONDecoder().decode(FormPack.self, from: data)) == 1)
        #expect(target.forms().first?.fingerprint == source.forms().first?.fingerprint)

        var bad = pack
        bad.forms[0].mapping.profileFingerprint = "sha256:other"
        #expect(throws: (any Error).self) { try target.importPack(bad) }
    }
}

@Suite struct Drift {
    @Test func anEHRUpdateIsRematchedNotRelearned() throws {
        let library = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let templates = try JSONDecoder().decode([NoteTemplate].self,
                                                 from: Data(contentsOf: root.appendingPathComponent("fixtures/mock-ehr/templates.json")))
        let base = try #require(library.forms().first)
        let old = LearnedForm(profile: base.profile, mapping: base.mapping, templates: templates)

        // The EHR's update: a key renamed, a field removed, one added, a choice list grown.
        var new = old.profile
        let dob = try #require(new.fields.firstIndex { $0.key == "client_dob" })
        new.fields[dob].key = "dob"
        new.fields.removeAll { $0.key == "gender_identity" }
        var added = new.fields[dob]
        added.key = "preferred_pharmacy"
        added.label = "Preferred pharmacy"
        new.fields.append(added)
        let pronouns = try #require(new.fields.firstIndex { $0.key == "pronouns" })
        new.fields[pronouns].options.append(.init(value: "ANY", label: "Any pronouns"))
        new.fingerprint = "sha256:new"

        let drift = FormDrift.rematch(old, to: new)
        #expect(drift.renamed == [.init(old: "client_dob", new: "dob")])
        #expect(drift.removed == ["gender_identity"])
        #expect(drift.added == ["preferred_pharmacy"])
        #expect(drift.optionsChanged == ["pronouns"])
        #expect(drift.form.mapping.fields["dob"] == old.mapping.fields["client_dob"], "the reviewed mapping moved with it")
        #expect(drift.form.mapping.fields["preferred_pharmacy"]?.mode == .skip, "new fields stay blank until mapped")
        #expect(drift.form.mapping.profileFingerprint == "sha256:new")
        #expect(drift.form.template("follow-up").fields["dob"]?.mode == .skip, "templates follow renames")
        #expect(drift.form.template("follow-up").fields["gender_identity"] == nil)
        #expect(drift.form.mapping.chart == old.mapping.chart)
        #expect(drift.kept.count == old.profile.fields.count - 2)
        #expect(drift.summary == "1 moved, 1 new (left blank until mapped), 1 removed, 1 with changed choices")
    }
}

@Suite struct PatternProposals {
    @Test func proposesPatternsThatReadTheExampleBack() throws {
        for (text, id, name) in [
            ("Record AB-114322 · REYES, Daniela", "AB-114322", "REYES, Daniela"),
            ("MRN: 00123456 | Maria Reyes", "00123456", "Maria Reyes"),
            ("Client 2024-001 Sam Lee", nil as String?, nil as String?),
            ("Chart K 12345 — Lee, Sam", "K 12345", "Lee, Sam"),
        ] {
            let p = FormMapping.Chart.proposePatterns(from: text)
            guard let id else { #expect(p == nil || p!.id.isEmpty == false); continue }
            let proposal = try #require(p, "no proposal for \(text)")
            let chart = FormMapping.Chart(origin: "x", pathPattern: "/", bannerSelector: "#b",
                                          clientIDPattern: proposal.id, clientNamePattern: proposal.name)
            let read = chart.client(inBanner: text)
            #expect(read?.id == id, "\(text) → \(proposal.id)")
            #expect(read?.name == name, "\(text) → \(proposal.name ?? "nil")")
        }
        let p = try #require(FormMapping.Chart.proposePatterns(from: "Record AB-114322 · REYES, Daniela"))
        let chart = FormMapping.Chart(origin: "x", pathPattern: "/", bannerSelector: "#b", clientIDPattern: p.id)
        #expect(chart.client(inBanner: "Record ZX-000042 · LEE, Sam")?.id == "ZX-000042", "generalizes to other clients")
        #expect(chart.client(inBanner: "Previous client record closed: M. Okonkwo") == nil)
    }
}

@Suite struct PathGeneralization {
    @Test func recordNumbersInTheURLAreNotKept() {
        for (path, want) in [
            ("/index.html", "/index.html"),
            ("/clients/114322/notes/new", "/clients/*/notes/new"),
            ("/chart/AB-114322/intake", "/chart/*/intake"),
            ("/v2/forms/progress-note", "/v2/forms/progress-note"),
            ("/r/3f2b8c1a-9d4e-4c1b-8a7f-2e6d5c4b3a21/edit", "/r/*/edit"),
            ("/doc/a1b2c3d4e5f6a7b8", "/doc/*"),
        ] {
            #expect(FormMapping.Chart.generalizePath(path) == want, "\(path)")
        }
        let chart = FormMapping.Chart(origin: "https://ehr.example", pathPattern: FormMapping.Chart.generalizePath("/clients/114322/notes/new"),
                                      bannerSelector: "#b", clientIDPattern: "(\\d+)")
        #expect(chart.matches("https://ehr.example/clients/998877/notes/new"), "another client's page")
    }
}

@Suite struct ByAddress {
    func tab(_ w: Int, order: Int, current: Bool, _ url: String) -> SafariTab {
        SafariTab(windowID: w, tabIndex: 1, windowOrder: order, isCurrentTab: current, url: url, title: "t")
    }

    @Test func bestMatchPrefersExactThenIgnoresFragmentThenQuery() {
        let tabs = [tab(1, order: 1, current: true, "http://127.0.0.1:8787/index.html?client=2"),
                    tab(2, order: 2, current: true, "http://127.0.0.1:8787/index.html?client=1#risk"),
                    tab(3, order: 3, current: true, "http://127.0.0.1:8787/csp.html")]
        func match(_ s: String) -> Int? { ChartFinder.bestMatch(URL(string: s)!, in: tabs)?.windowID }
        #expect(match("http://127.0.0.1:8787/index.html?client=1#risk") == 2, "exact")
        #expect(match("http://127.0.0.1:8787/index.html?client=1") == 2, "same page, no fragment")
        #expect(match("http://127.0.0.1:8787/index.html?client=9") == 1, "same path: the front tab wins")
        #expect(match("http://127.0.0.1:8787/risk.html") == nil)
    }

    @Test func lookupExplainsEveryOutcome() throws {
        let library = try mockLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let open = [tab(7, order: 1, current: true, "http://127.0.0.1:8787/index.html")]
        let finder = ChartFinder(forms: library, listTabs: { open }, readBanner: { _, _ in "Record AB-114322 · REYES, Daniela" })
        guard case .found(let c) = finder.lookup("  http://127.0.0.1:8787/index.html  ") else { Issue.record("not found"); return }
        #expect(c.binding.clientID == "AB-114322" && c.tab.windowID == 7)
        guard case .notLearned = finder.lookup("http://127.0.0.1:8787/csp.html") else { Issue.record("csp learned?"); return }
        guard case .notAnAddress = finder.lookup("REYES, Daniela") else { Issue.record("not an address"); return }
        guard case .notAnAddress = finder.lookup("file:///etc/passwd") else { Issue.record("file URL accepted"); return }
        let closed = ChartFinder(forms: library, listTabs: { [] }, readBanner: { _, _ in "" })
        guard case .notOpen(_, let form) = closed.lookup("http://127.0.0.1:8787/index.html") else { Issue.record("should offer to open"); return }
        #expect(form.contains("Riverside"))
        let loading = ChartFinder(forms: library, listTabs: { open }, readBanner: { _, _ in "" })
        guard case .noClient = loading.lookup("http://127.0.0.1:8787/index.html") else { Issue.record("no client yet"); return }
    }
}

@Suite struct BannerScript {
    /// The script handles both selector kinds the learn flow can save. (Run for real in the
    /// Playwright suite's banner tests; here, that it's well-formed and carries the selector
    /// only as data.)
    @Test func readsCSSOrXPathAndQuotesTheSelector() throws {
        let css = try ChartFinder.bannerScript("#record_banner")
        #expect(css.contains(##"var s="#record_banner""##))
        let xp = try ChartFinder.bannerScript("xpath=/html/body/div[1]/h2")
        #expect(xp.contains("document.evaluate(s.slice(6)"))
        let hostile = try ChartFinder.bannerScript(##"");alert(1);(""##)
        #expect(hostile.contains(##"var s="\");alert(1);(\""##), "stays a string literal")
    }
}
