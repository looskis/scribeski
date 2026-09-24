import Capture
import FormDriver
import Foundation
import Orchestrator
import Foundation
import ScribeskiCore
import Testing
@testable import ScribeskiUI

@Suite struct SessionStateTransitions {
    @Test func happyPathIsLegalEndToEnd() {
        let path: [SessionState] = [.idle, .armed, .recording(startedAt: .now), .stopping, .transcribing,
                                    .extracting, .readyToFill, .filling, .reviewing, .confirmed, .purged, .idle]
        for (a, b) in zip(path, path.dropFirst()) {
            #expect(a.canTransition(to: b), "\(a) → \(b)")
        }
    }

    @Test func resumeEntersOnlyAtExtractionOrFill() {
        #expect(SessionState.idle.canTransition(to: .extracting))
        #expect(SessionState.idle.canTransition(to: .readyToFill))
        #expect(!SessionState.idle.canTransition(to: .filling), "a resumed fill is confirmed again")
        #expect(!SessionState.idle.canTransition(to: .reviewing))
    }

    @Test func cannotSkipReview() {
        #expect(!SessionState.filling.canTransition(to: .confirmed))
        #expect(!SessionState.extracting.canTransition(to: .filling), "no fill without the worker confirming the tab")
        #expect(!SessionState.reviewing.canTransition(to: .purged))
    }

    /// Nothing ever asks the worker to re-record (BUILD_PLAN P3.1).
    @Test func captureFailureResumesFromTranscriptNotRecording() {
        let failed = SessionState.failed(stage: .recording, message: "device vanished")
        #expect(failed.canTransition(to: .transcribing))
        #expect(!failed.canTransition(to: .recording(startedAt: .now)))
        #expect(SessionState.Stage.extracting.resumeState == .extracting)
    }
}

@MainActor @Suite struct SessionModelFlow {
    let zoom = CallSource(bundleID: "us.zoom.xos", name: "Zoom", kind: .callApp, processes: [])

    @Test func startNeedsConsentAndSource() {
        let model = SessionModel(driver: SimulatedDriver())
        model.sources = [zoom]
        #expect(!model.canStart)
        model.selectedSourceID = zoom.id
        #expect(!model.canStart)
        model.consentAffirmed = true
        #expect(model.canStart)
        model.permissions[.callAudio] = .notDetermined
        #expect(!model.canStart)
        #expect(model.blockingPermissions == [.callAudio])
        model.permissions[.callAudio] = .granted
        model.permissions[.safariAutomation] = .denied
        #expect(model.canStart, "Safari automation is only needed to fill")
    }

    @Test func simulatedSessionReachesReviewThenIdle() async throws {
        let model = SessionModel(driver: SimulatedDriver(stageDelay: .milliseconds(5)))
        model.sources = [zoom]
        model.selectedSourceID = zoom.id
        model.consentAffirmed = true
        model.start()
        #expect(model.state.isCapturing)
        model.stop()
        for _ in 0..<200 where model.state != .readyToFill {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.state == .readyToFill, "stops for the worker to confirm the tab")
        model.confirmFill()
        for _ in 0..<200 where model.state != .reviewing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.state == .reviewing)
        model.confirmReviewed()
        #expect(model.state == .idle)
        #expect(!model.consentAffirmed, "consent is per session")
    }

    @Test func retentionStatementIsSayable() {
        #expect(SessionModel(driver: SimulatedDriver()).retentionStatement == "audio not recorded")
        #expect(SessionModel(driver: SimulatedDriver(), retention: .days(1)).retentionStatement == "audio kept 1 day")
    }
}

@MainActor @Suite struct CallStartDetection {
    func zoom(inCall: Bool) -> CallSource {
        CallSource(bundleID: "us.zoom.xos", name: "Zoom", kind: .callApp, processes: [
            AudioProcess(objectID: 1, pid: 1, bundleID: "us.zoom.xos", responsibleBundleID: "us.zoom.xos",
                         isRunningOutput: true, isRunningInput: inCall)])
    }

    @Test func promptsOncePerCallAndOnlyWhenIdle() {
        let model = SessionModel(driver: SimulatedDriver())
        let watcher = CallWatcher(model: model)
        #expect(watcher.callStarted(in: [zoom(inCall: false)]) == nil, "open but not in a call")
        #expect(watcher.callStarted(in: [zoom(inCall: true)])?.name == "Zoom", "joined")
        #expect(watcher.callStarted(in: [zoom(inCall: true)]) == nil, "same call, no repeat")
        #expect(watcher.callStarted(in: [zoom(inCall: false)]) == nil, "left")
        model.sources = [zoom(inCall: true)]
        model.selectedSourceID = "us.zoom.xos"
        model.consentAffirmed = true
        model.start() // a session is running now
        #expect(watcher.callStarted(in: [zoom(inCall: true)]) == nil, "never while a session runs")
    }
}

@MainActor @Suite struct ChartBindingAtStart {
    func candidate(_ id: String, window: Int) -> ChartCandidate {
        ChartCandidate(tab: SafariTab(windowID: window, tabIndex: 1, windowOrder: window, isCurrentTab: true,
                                      url: "http://127.0.0.1:8787/index.html", title: "ICR"),
                       binding: ChartBinding(fingerprint: "fp", formName: "ICR", clientID: id, clientName: nil))
    }

    func ready() -> SessionModel {
        let m = SessionModel(driver: SimulatedDriver())
        m.sources = [CallSource(bundleID: "us.zoom.xos", name: "Zoom", kind: .callApp, processes: [])]
        m.selectedSourceID = "us.zoom.xos"
        m.consentAffirmed = true
        return m
    }

    @Test func noChartOpenStillStarts() {
        #expect(ready().canStart)
    }

    @Test func severalChartsNeverGuess() {
        let m = ready()
        m.chartCandidates = [candidate("AB-1", window: 1), candidate("AB-2", window: 2)]
        #expect(!m.canStart, "two clients' charts open and none chosen")
        m.chartSelectionID = m.chartCandidates[1].id
        #expect(m.canStart)
        m.start()
        #expect(m.chart?.clientID == "AB-2", "pressing Start binds the chart shown")
    }

    @Test func pickLaterStartsUnbound() {
        let m = ready()
        m.chartCandidates = [candidate("AB-1", window: 1), candidate("AB-2", window: 2)]
        m.chartDeferred = true
        #expect(m.canStart)
        m.start()
        #expect(m.chart == nil)
    }
}

@Suite struct ProposedChanges {
    @Test func onFileValueBecomesAProposalOnlyWhereTheTemplateAllows() {
        let r = FieldResult(key: "contact_phone", status: .filled, value: .single("510-555-0193"))
        let kept = FillReport(key: "contact_phone", intended: .single("510-555-0193"), readBack: .single("510-555-0100"),
                              outcome: .conflictSkipped, priorValue: .single("510-555-0100"))
        #expect(ReviewStatus.of(r, kept, edited: false) == .conflictSkipped)
        #expect(ReviewStatus.of(r, kept, edited: false, updatable: ["contact_phone"]) == .proposedChange)
        #expect(ReviewStatus.of(r, kept, edited: true, updatable: ["contact_phone"]) == .edited, "accepted")
    }
}

@MainActor @Suite struct PastedAddress {
    func finder(_ banner: String) throws -> (ChartFinder, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profile = try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: root.appendingPathComponent("page/test/golden/mock-ehr.profile.json")))
        let mapping = try JSONDecoder().decode(FormMapping.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/mock-ehr/mapping.json")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forms-\(UUID())")
        let library = FormLibrary(directory: dir)
        try library.install(LearnedForm(profile: profile, mapping: mapping))
        let tabs = [SafariTab(windowID: 5, tabIndex: 2, windowOrder: 2, isCurrentTab: false,
                              url: "http://127.0.0.1:8787/index.html", title: "ICR")]
        return (ChartFinder(forms: library, listTabs: { tabs }, readBanner: { _, _ in banner }), dir)
    }

    @Test func pastingAtStartSelectsThatChart() throws {
        let (f, dir) = try finder("Record AB-114322 · REYES, Daniela")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = SessionModel(driver: SimulatedDriver())
        m.chartAddress = "http://127.0.0.1:8787/index.html"
        m.useChartAddress(finder: f)
        #expect(m.selectedChart?.binding.clientID == "AB-114322")
        #expect(m.selectedChart?.tab.windowID == 5, "a background tab, found by address")
        #expect(m.chartAddress.isEmpty && m.addressNote == nil)
    }

    @Test func pastingAnotherClientsChartAtFillIsRefused() throws {
        let (f, dir) = try finder("Record AB-200001 · LEE, Sam")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = SessionModel(driver: SimulatedDriver())
        for s: SessionState in [.armed, .recording(startedAt: .now), .stopping, .transcribing, .extracting, .readyToFill] {
            m.transition(to: s)
        }
        m.chart = ChartBinding(fingerprint: try #require(f.forms.forms().first?.fingerprint), formName: "ICR",
                               clientID: "AB-114322", clientName: "REYES, Daniela")
        m.chartAddress = "http://127.0.0.1:8787/index.html"
        m.useChartAddress(finder: f)
        #expect(m.fillCandidate == nil)
        #expect(m.addressNote?.contains("LEE, Sam") == true)
    }
}
