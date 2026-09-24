import Foundation
import Testing
@testable import SuiteModelStore

private let GiB: UInt64 = 1 << 30

@Suite struct CatalogTests {
    @Test func builtInCatalogIsFullyPinned() throws {
        let catalog = try Catalog.builtIn()
        #expect(catalog.schemaVersion == 1)
        #expect(!catalog.models.isEmpty)
        #expect(Set(catalog.models.map(\.id)).count == catalog.models.count, "ids unique")

        for m in catalog.models {
            try m.validate()
            #expect(m.revision.count == 40 && ModelManifest.isSHA256Hex(m.revision + String(repeating: "0", count: 24)),
                    "\(m.id): revision must be a pinned 40-hex commit, got \(m.revision)")
            #expect(m.revision != "main")
            #expect(m.minRAMGB > 0)
            #expect(!m.license.isEmpty)
            for f in m.files {
                #expect(f.url.scheme == "https", "\(m.id)/\(f.path)")
                #expect(f.url.absoluteString.contains("/resolve/\(m.revision)/"), "\(m.id)/\(f.path) not pinned")
                #expect(ModelManifest.isSHA256Hex(f.sha256), "\(m.id)/\(f.path)")
                #expect(f.size > 0, "\(m.id)/\(f.path)")
                #expect(!f.path.contains("mmproj"), "vision projector must be excluded")
            }
        }
    }

    @Test func builtInDefaultsExistAndMatchRoles() throws {
        let catalog = try Catalog.builtIn()
        for role in [ModelRole.llm, .asr, .diarizer] {
            let m = try #require(catalog.defaultModel(for: role), "no default for \(role)")
            #expect(m.role == role)
        }
        #expect(catalog.defaultModel(for: .llm)?.format == .gguf)
        #expect(catalog.defaultModel(for: .asr)?.format == .coreml)
        #expect(catalog.models(for: .llm).count >= 2)
        #expect(catalog.models(for: .asr).count >= 2)
    }

    @Test func manifestJSONIsSnakeCase() throws {
        let m = ModelManifest(
            id: "x", displayName: "X", role: .vad, format: .coreml, revision: "r", license: "MIT",
            licenseURL: URL(string: "https://example.com/l"), minRAMGB: 4,
            files: [ModelFile(path: "a", url: URL(string: "https://e.com/a")!, sha256: String(repeating: "a", count: 64), size: 1)],
            notes: nil, validated: true)
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        for key in ["display_name", "min_ram_gb", "license_url", "\"validated\"", "\"vad\""] {
            #expect(json.contains(key), "\(key) missing in \(json)")
        }
        #expect(try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8)) == m)
    }
}

@Suite struct SelectionTests {
    func catalog() -> Catalog {
        func m(_ id: String, _ role: ModelRole, ram: Int, validated: Bool = true) -> ModelManifest {
            ModelManifest(
                id: id, displayName: id, role: role, format: .gguf, revision: "abc", license: "Apache-2.0",
                minRAMGB: ram,
                files: [ModelFile(path: "m.gguf", url: URL(string: "https://e.com/\(id)")!,
                                  sha256: String(repeating: "b", count: 64), size: 10)],
                validated: validated)
        }
        return Catalog(
            defaults: [.llm: "big", .asr: "asr-a"],
            models: [m("big", .llm, ram: 32), m("small", .llm, ram: 16), m("asr-a", .asr, ram: 8),
                     m("asr-b", .asr, ram: 16, validated: false)])
    }

    @Test func defaultsOutOfTheBox() {
        let r = Resolver.resolve(role: .llm, selection: ModelSelection(), catalog: catalog(), ram: 64 * GiB)
        #expect(r.origin == .catalogDefault)
        #expect(r.status == .ok)
        #expect(r.manifest?.id == "big")
        #expect(r.validated)
        #expect(!r.isCustom)
    }

    @Test func userOverrideWins() {
        var sel = ModelSelection()
        sel[.llm] = .catalog(id: "small")
        let r = Resolver.resolve(role: .llm, selection: sel, catalog: catalog(), ram: 64 * GiB)
        #expect(r.origin == .userChoice)
        #expect(r.manifest?.id == "small")
        #expect(r.status == .ok)
        // Other roles still fall back to defaults.
        #expect(Resolver.resolve(role: .asr, selection: sel, catalog: catalog(), ram: 64 * GiB).manifest?.id == "asr-a")
    }

    @Test func insufficientRAMIsReportedNotSubstituted() {
        let r = Resolver.resolve(role: .llm, selection: ModelSelection(), catalog: catalog(), ram: 16 * GiB)
        #expect(r.status == .insufficientRAM)
        #expect(r.manifest?.id == "big", "must not silently pick 'small'")
        #expect(r.requiredRAMGB == 32)
        #expect(r.availableRAMGB == 16)
        // Exactly at the minimum is fine.
        #expect(Resolver.resolve(role: .llm, selection: ModelSelection(), catalog: catalog(), ram: 32 * GiB).status == .ok)
    }

    @Test func customModelsAreNeverValidated() throws {
        var sel = ModelSelection()
        let local = CustomModel(displayName: "My GGUF", format: .gguf, source: .local(path: "/Users/me/m.gguf"))
        sel[.llm] = .custom(local)
        let r = Resolver.resolve(role: .llm, selection: sel, catalog: catalog(), ram: 64 * GiB)
        #expect(r.isCustom)
        #expect(r.validated == false)
        #expect(r.status == .ok)
        #expect(r.manifest == nil, "local models aren't store-managed")

        let sha = String(repeating: "c", count: 64)
        let remote = CustomModel(displayName: "Remote", format: .gguf,
                                 source: .remote(url: URL(string: "https://host.example/q.gguf")!, sha256: sha, size: 42),
                                 minRAMGB: 48)
        sel[.llm] = .custom(remote)
        let r2 = Resolver.resolve(role: .llm, selection: sel, catalog: catalog(), ram: 32 * GiB)
        #expect(r2.status == .insufficientRAM)
        let m = try #require(r2.manifest)
        #expect(m.validated == false)
        #expect(m.files.first?.path == "q.gguf")
        try m.validate()
    }

    @Test func unknownAndMismatchedChoices() {
        var sel = ModelSelection()
        sel[.llm] = .catalog(id: "removed-in-update")
        #expect(Resolver.resolve(role: .llm, selection: sel, catalog: catalog(), ram: 64 * GiB).status == .unknownModel)
        sel[.llm] = .catalog(id: "asr-a")
        #expect(Resolver.resolve(role: .llm, selection: sel, catalog: catalog(), ram: 64 * GiB).status == .roleMismatch)
        #expect(Resolver.resolve(role: .vad, selection: ModelSelection(), catalog: catalog(), ram: 64 * GiB).status == .noDefault)
        var s2 = ModelSelection()
        s2[.asr] = .catalog(id: "asr-b")
        #expect(Resolver.resolve(role: .asr, selection: s2, catalog: catalog(), ram: 64 * GiB).validated == false)
    }

    @Test func selectionStoreRoundTrips() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let store = SelectionStore(url: dir.url.appendingPathComponent("prefs/models.json"))
        #expect(try store.load() == ModelSelection())  // missing file → all defaults

        var sel = ModelSelection()
        sel[.llm] = .catalog(id: "small")
        sel[.asr] = .custom(CustomModel(
            displayName: "Mine", format: .mlx, source: .remote(
                url: URL(string: "https://h.example/w.safetensors")!, sha256: String(repeating: "d", count: 64), size: 7)))
        sel[.diarizer] = .custom(CustomModel(displayName: "Local", format: .coreml, source: .local(path: "/tmp/x.mlmodelc")))
        try store.save(sel)
        #expect(try store.load() == sel)

        let json = try String(contentsOf: store.url, encoding: .utf8)
        #expect(json.contains("\"llm\""))
        #expect(json.contains("\"kind\" : \"catalog\""))
        #expect(json.contains("\"local_path\""))
        #expect(json.contains("\"validated\" : false"))
    }

    @Test func physicalMemoryIsReadable() {
        #expect(SystemInfo.physicalMemory >= 8 * GiB)
    }
}

@Suite struct LocationTests {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test func environmentVariableWins() {
        let loc = StoreLocation.resolve(
            groupID: "TEAMID.suite", suiteName: "Suite", environment: ["SUITE_MODEL_STORE": "/Volumes/Fast/Models"],
            homeDirectory: home, hasGroupEntitlement: { _ in true },
            containerURL: { _ in URL(fileURLWithPath: "/group") })
        #expect(loc.source == .environment)
        #expect(loc.root.path == "/Volumes/Fast/Models")
        #expect(loc.reason.contains("SUITE_MODEL_STORE"))
    }

    @Test func relativeEnvironmentValueIsIgnored() {
        let loc = StoreLocation.resolve(
            groupID: "TEAMID.suite", suiteName: "Suite", environment: ["SUITE_MODEL_STORE": "relative/dir"],
            homeDirectory: home, hasGroupEntitlement: { _ in true },
            containerURL: { _ in URL(fileURLWithPath: "/Users/tester/Library/Group Containers/TEAMID.suite") })
        #expect(loc.source == .appGroup("TEAMID.suite"))
        #expect(loc.root.path == "/Users/tester/Library/Group Containers/TEAMID.suite/Models")
        #expect(loc.reason.contains("not an absolute path"))
    }

    @Test func unentitledFallsBackToApplicationSupport() {
        var asked = false
        let loc = StoreLocation.resolve(
            groupID: "TEAMID.suite", suiteName: "Suite", environment: [:], homeDirectory: home,
            hasGroupEntitlement: { _ in false },
            containerURL: { _ in asked = true; return URL(fileURLWithPath: "/group") })
        #expect(!asked, "must not touch the group container without the entitlement")
        #expect(loc.source == .applicationSupport)
        #expect(loc.root.path == "/Users/tester/Library/Application Support/Suite/Models")
        #expect(loc.reason.contains("entitlement"))
    }

    @Test func noGroupConfigured() {
        let loc = StoreLocation.resolve(groupID: nil, suiteName: "Suite", environment: [:], homeDirectory: home)
        #expect(loc.source == .applicationSupport)
        #expect(loc.reason.contains("no App Group id"))
    }

    @Test func testRunnerIsNotEntitled() {
        #expect(!StoreLocation.processHasAppGroupEntitlement("TEAMID.nonexistent"))
    }
}
