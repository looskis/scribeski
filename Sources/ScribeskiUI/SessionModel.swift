import Capture
import Foundation
import Observation
import ScribeskiCore
import Orchestrator
import Transcription

/// Does the work behind the menu: capture, transcription, extraction, fill. The UI never
/// talks to those modules directly, so it can run against `SimulatedDriver` until they exist.
@MainActor public protocol SessionDriver: AnyObject {
    func start(source: CallSource, retention: Retention, model: SessionModel)
    func stop(model: SessionModel)
    /// Re-enter `stage.resumeState` from what's already persisted.
    func retry(_ stage: SessionState.Stage, model: SessionModel)
    /// The worker confirmed the chart: fill it.
    func confirmFill(model: SessionModel)
    /// Finds the bound chart's tab again (or the candidates, if none is bound yet).
    func locateChart(model: SessionModel)
    /// Review (P3.3): show one field in the form, write the worker's value, or undo every write.
    func focus(_ key: String, model: SessionModel)
    func write(_ key: String, _ value: FieldValue, model: SessionModel)
    func undoAll(model: SessionModel)
    /// Destroy the session per retention policy.
    func purge(model: SessionModel)
    /// An unfinished session from before a crash or quit, if any (sets `model.recovery`).
    func findRecovery(model: SessionModel)
    /// Picks that session up from what was sealed: notes from the transcript, or the fill.
    func resume(model: SessionModel)
    /// Destroys it (the key) instead.
    func discardRecovery(model: SessionModel)
    /// The worker accepted a changed form: re-learn it from the drift report and fill again.
    func acceptDrift(model: SessionModel)
    /// Review playback (P2.6): what was said, from the encrypted copy. Retained modes only.
    func play(_ segment: Transcript.Segment, model: SessionModel)
    func stopPlayback(model: SessionModel)
    /// Shown in the menu so a demo is never mistaken for a real session. Nil when nothing is faked.
    var simulationNote: String? { get }
}

extension SessionDriver {
    public func play(_ segment: Transcript.Segment, model: SessionModel) {}
    public func stopPlayback(model: SessionModel) {}
}

/// Everything the menu-bar UI renders. Drivers push into it; views read from it.
@MainActor @Observable public final class SessionModel {
    public private(set) var state: SessionState = .idle
    public var sources: [CallSource] = []
    public var selectedSourceID: String?
    /// Fixed at arm time for the session (BUILD_PLAN P3.5). Policy may lock it.
    public var retention: Retention
    public var consentAffirmed = false
    /// Last known TCC status. A permission not yet checked doesn't block anything.
    public var permissions: [Permission: PermissionStatus] = [:]

    // Live while recording. Levels are 0...1.
    public var workerLevel: Float = 0
    public var clientLevel: Float = 0
    /// How long the client track has been below the speech threshold.
    public var clientSilentSeconds: TimeInterval = 0
    /// Audio captured but not yet transcribed.
    public var backlogSeconds: TimeInterval = 0
    /// The mic feeding the worker track. Nil while recording means tap-only: your side is lost.
    public var microphoneName: String?
    /// A short line about work in progress, e.g. "Loading the speech model…".
    public var statusNote: String?
    /// Final text so far, in arrival order. Shown live while recording.
    public var liveSegments: [TranscribedSegment] = []
    /// The finished transcript, from Stop until purge. Memory only until storage (P3.5).
    public var transcript: Transcript?
    public var transcriberErrors: [String] = []
    /// Models used for this session that haven't passed the eval gates (P4.2 badge).
    public var unvalidatedModels: [String] = []
    /// The tab a fill would write to, shown for confirmation (P3.3).
    public var fillTarget: String?

    // Chart binding (BUILD_PLAN P3.1): whose chart this session is for.
    /// Learned charts open in Safari, found when the menu opens.
    public var chartCandidates: [ChartCandidate] = []
    /// The worker's pick among them (candidate id), or nil.
    public var chartSelectionID: String?
    /// "Pick later": start without a chart; bind it before filling.
    public var chartDeferred = false
    /// The chart the session is bound to. Set when Start is pressed, or at fill if deferred.
    public var chart: ChartBinding?
    /// Learned forms, for choosing what to extract when no chart is open at Start.
    public var learnedForms: [LearnedForm] = []
    public var selectedFormFingerprint: String?
    /// The session type (template) for this session, e.g. "follow-up".
    public var templateID: String?

    /// The form this session will be written against: the chart's, else the one picked.
    public var currentForm: LearnedForm? {
        let fp = selectedChart?.binding.fingerprint ?? chart?.fingerprint ?? selectedFormFingerprint
        return learnedForms.first { $0.fingerprint == fp } ?? learnedForms.first
    }

    /// Session types the current form offers, and the one chosen (last used for this form).
    public var templates: [NoteTemplate] { currentForm?.templates ?? [] }
    public var selectedTemplate: NoteTemplate? {
        guard let form = currentForm else { return nil }
        return form.template(templateID ?? UserDefaults.standard.string(forKey: "template.\(form.fingerprint)"))
    }

    public func chooseTemplate(_ id: String) {
        templateID = id
        if let form = currentForm { UserDefaults.standard.set(id, forKey: "template.\(form.fingerprint)") }
    }
    /// The bound chart's tab, found again at fill time. Nil means it isn't open, or it's open
    /// in several tabs and the worker hasn't chosen (`fillChoices`).
    public var fillCandidate: ChartCandidate?
    /// Tabs showing the bound chart when there's more than one.
    public var fillChoices: [ChartCandidate] = []
    /// A chart's address the worker pasted, and what looking for it found.
    public var chartAddress = ""
    public var addressNote: String?
    /// The pasted address is a learned form that isn't open: offer to open it.
    public var addressToOpen: URL?
    /// What extraction produced, and what the fill did. Memory only until review is confirmed.
    public var extraction: NotePipeline.Extraction?
    public var outcome: NotePipeline.Outcome?
    // Review panel state.
    public var reviewSelection: String?
    /// Values the worker wrote themselves, by field key. Audited as `edited_by_worker`.
    public var edited: [String: FieldValue] = [:]
    /// The field being written or focused right now; blocks other actions until done.
    public var busyKey: String?
    public var reviewError: String?
    /// The session kept audio and it's still there: review can play what was said.
    public var canPlayAudio = false
    public var playingSegmentID: String?
    /// View state for the review panel. Lives here because the package builds with the
    /// Command Line Tools, which can't expand SwiftUI's `@State` macro.
    public var reviewFilter = ReviewFilter.attention
    public var confirmingUndo = false
    public var drafts: [String: FieldValue] = [:]
    /// Set when the worker clicks a "call started" notification; the app opens the start panel.
    public var wantsStartPanel = false
    /// The form changed since it was learned: what moved, for the worker to accept.
    public var drift: FormDrift?
    /// A session that didn't finish (the app crashed or quit mid-way), offered in the menu.
    public var recovery: Recovery?

    public struct Recovery: Equatable, Sendable {
        public var sessionID: String
        public var started: Date
        public var stage: String
        public var client: String?
        public var lines: Int
        public var hasNotes: Bool

        public init(sessionID: String, started: Date, stage: String, client: String?, lines: Int, hasNotes: Bool) {
            self.sessionID = sessionID
            self.started = started
            self.stage = stage
            self.client = client
            self.lines = lines
            self.hasNotes = hasNotes
        }
    }

    public let driver: SessionDriver
    /// Off for snapshots and previews, which supply `sources` themselves.
    public var discoversSources = true
    @ObservationIgnored private var sourceObservation: AudioProcessList.Observation?
    @ObservationIgnored private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    /// BUILD_PLAN P2.2: the call app is up but the tap has been silent this long.
    public static let silentClientAlarm: TimeInterval = 10
    public static let backlogAlarm: TimeInterval = 10

    public init(driver: SessionDriver, retention: Retention = .none) {
        self.driver = driver
        self.retention = retention
    }

    // MARK: - Derived

    public var selectedSource: CallSource? {
        sources.first { $0.id == selectedSourceID }
    }

    public var canStart: Bool {
        state == .idle && consentAffirmed && selectedSource != nil && blockingPermissions.isEmpty && chartResolved
            && !tooManyUnreviewed
    }

    /// Sessions that ended without "I've reviewed this": newest last.
    public var pendingSessions: [Recovery] = []
    /// Warn at this many unreviewed sessions; refuse to start at twice it (BUILD_PLAN P3.5).
    public var unconfirmedLimit = 3
    public var unreviewedWarning: Bool { pendingSessions.count >= unconfirmedLimit && !tooManyUnreviewed }
    public var tooManyUnreviewed: Bool { pendingSessions.count >= 2 * unconfirmedLimit }

    public var selectedChart: ChartCandidate? {
        chartCandidates.first { $0.id == chartSelectionID }
    }

    /// Start needs to know whose chart this is, or be told "later". With several charts
    /// open, it never guesses.
    public var chartResolved: Bool {
        selectedChart != nil || chartDeferred || chartCandidates.isEmpty
    }

    /// Finds learned charts in Safari. One open: preselected. Several: the worker picks.
    public func refreshCharts(finder: ChartFinder = ChartFinder()) {
        guard discoversSources, state == .idle else { return }
        learnedForms = finder.forms.forms()
        chartCandidates = finder.candidates()
        if selectedChart == nil {
            chartSelectionID = chartCandidates.count == 1 ? chartCandidates[0].id : nil
        }
        if selectedFormFingerprint == nil { selectedFormFingerprint = learnedForms.first?.fingerprint }
    }

    /// Needed before recording. Safari automation only matters at the fill step.
    public static let requiredToStart: [Permission] = [.microphone, .callAudio]

    public var blockingPermissions: [Permission] {
        Self.requiredToStart.filter { permissions[$0] == .denied || permissions[$0] == .notDetermined }
    }

    /// Show the permissions block while anything is missing, including Safari automation.
    public var needsPermissionAttention: Bool {
        Permission.allCases.contains { permissions[$0] == .denied || permissions[$0] == .notDetermined }
    }

    /// What the worker can say truthfully to the client (BUILD_PLAN P3.6).
    public var retentionStatement: String {
        switch retention {
        case .none: "audio not recorded"
        case .untilConfirm: "audio kept until you confirm"
        case .days(let n): "audio kept \(n) day\(n == 1 ? "" : "s")"
        }
    }

    public var isClientSilent: Bool { state.isCapturing && clientSilentSeconds >= Self.silentClientAlarm }
    public var isFallingBehind: Bool { state.isCapturing && backlogSeconds >= Self.backlogAlarm }

    // MARK: - Call sources

    public func refreshSources() {
        microphoneName = AudioDevices.defaultInputName
        sources = CallSources.group(AudioProcessList.snapshot(), excluding: [ownBundleID])
        if selectedSource == nil {
            // Preselect a source that's in a call (using the mic), else a call app making
            // sound, else the first call app. Browsers only when they're in a call.
            selectedSourceID = (sources.first(where: \.isInCall)
                ?? sources.first { $0.kind != .browser && $0.kind != .other && $0.isPlaying }
                ?? sources.first { $0.kind == .callApp || $0.kind == .webApp })?.id
        }
    }

    public func watchSources() {
        guard discoversSources else { return }
        refreshSources()
        sourceObservation = AudioProcessList.observe { [weak self] in self?.refreshSources() }
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        guard discoversSources else { return }
        for p in Permission.allCases { permissions[p] = Permissions.status(p) }
    }

    public func request(_ permission: Permission) async {
        permissions[permission] = await Permissions.request(permission)
    }

    // MARK: - Worker actions

    public func start() {
        guard canStart, let source = selectedSource else { return }
        // Pressing Start confirms the chart shown next to it.
        chart = chartDeferred ? nil : selectedChart?.binding
        if let chart { selectedFormFingerprint = chart.fingerprint }
        templateID = selectedTemplate?.id
        transition(to: .armed)
        driver.start(source: source, retention: retention, model: self)
    }

    public func stop() {
        guard state.isCapturing else { return }
        driver.stop(model: self)
    }

    public func retry() {
        guard case .failed(let stage, _) = state else { return }
        driver.retry(stage, model: self)
    }

    /// Finds the chart again each time the fill confirmation is shown.
    public func refreshFillTarget() {
        guard discoversSources, state == .readyToFill else { return }
        driver.locateChart(model: self)
    }

    /// Finds the pasted address: selects that chart at Start, binds it at fill time, or picks
    /// its tab when the chart is open twice.
    public func useChartAddress(finder: ChartFinder = ChartFinder()) {
        addressNote = nil
        addressToOpen = nil
        switch finder.lookup(chartAddress) {
        case .found(let c): choose(c)
        case .notOpen(let url, let form):
            addressToOpen = url
            addressNote = "That \(form) page isn't open in Safari."
        case .noClient:
            addressNote = "That page is open, but it doesn't show whose chart it is yet. Wait for it to load, then try again."
        case .notLearned:
            addressNote = "That page isn't a form Scribeski has learned. Learn it first (Learn a form…)."
        case .notAnAddress:
            addressNote = "That isn't a web address. Copy it from Safari's address bar (⌘L, then ⌘C)."
        }
    }

    /// Opens the pasted address in Safari (the worker asked) and uses it once it loads.
    public func openChartAddress(finder: ChartFinder = ChartFinder()) async {
        guard let url = addressToOpen else { return }
        addressToOpen = nil
        addressNote = "Opening…"
        do {
            choose(try await finder.open(url))
            addressNote = nil
        } catch {
            addressNote = "Opened it, but couldn't read whose chart it is. Check the page, then paste the address again."
        }
    }

    private func choose(_ c: ChartCandidate) {
        chartAddress = ""
        switch state {
        case .idle:
            if !chartCandidates.contains(where: { $0.id == c.id }) { chartCandidates.append(c) }
            chartSelectionID = c.id
            chartDeferred = false
        case .readyToFill where chart == nil:
            if extraction?.profile.fingerprint == c.binding.fingerprint { bindChart(c) }
            else { addressNote = "That's a different form from the one these notes are for." }
        case .readyToFill where chart?.clientID == c.binding.clientID && chart?.fingerprint == c.binding.fingerprint:
            fillCandidate = c
            if !fillChoices.isEmpty, !fillChoices.contains(where: { $0.id == c.id }) { fillChoices.append(c) }
        case .readyToFill:
            addressNote = "That's \(c.binding.display)'s chart, not \(chart?.display ?? "this session's client")'s."
        default:
            break
        }
    }

    /// The same chart is open in several tabs: the worker picks which one to fill.
    public func chooseFillTab(_ candidate: ChartCandidate) {
        guard state == .readyToFill, fillChoices.contains(candidate) else { return }
        fillCandidate = candidate
    }

    /// Binds a chart at fill time (the worker chose "Pick later" at Start).
    public func bindChart(_ candidate: ChartCandidate) {
        guard state == .readyToFill, chart == nil else { return }
        chart = candidate.binding
        fillCandidate = candidate
    }

    public func acceptDrift() {
        guard drift != nil else { return }
        driver.acceptDrift(model: self)
    }

    public func findRecovery() {
        guard discoversSources, state == .idle else { return }
        driver.findRecovery(model: self)
    }

    public func resume(_ session: Recovery? = nil) {
        if let session { recovery = session }
        guard state == .idle, recovery != nil else { return }
        driver.resume(model: self)
    }

    public func discardRecovery(_ session: Recovery? = nil) {
        if let session { recovery = session }
        driver.discardRecovery(model: self)
    }

    public func confirmFill() {
        guard state == .readyToFill else { return }
        driver.confirmFill(model: self)
    }

    public func play(_ segment: Transcript.Segment) {
        guard canPlayAudio else { return }
        if playingSegmentID == segment.id {
            driver.stopPlayback(model: self)
        } else {
            driver.play(segment, model: self)
        }
    }

    public func focus(_ key: String) {
        guard busyKey == nil else { return }
        driver.focus(key, model: self)
    }

    public func write(_ key: String, _ value: FieldValue) {
        guard busyKey == nil, state == .reviewing else { return }
        driver.write(key, value, model: self)
    }

    public func undoAll() {
        guard busyKey == nil, state == .reviewing else { return }
        driver.undoAll(model: self)
    }

    public func confirmReviewed() {
        guard state == .reviewing else { return }
        transition(to: .confirmed)
        driver.purge(model: self)
    }

    public func discard() {
        transition(to: .idle)
        consentAffirmed = false
    }

    // MARK: - Driver callbacks

    /// Drivers move the session through here so illegal transitions surface in debug builds.
    public func transition(to next: SessionState) {
        assert(state.canTransition(to: next), "illegal transition \(state) → \(next)")
        state = next
        if !next.isCapturing {
            workerLevel = 0
            clientLevel = 0
            clientSilentSeconds = 0
            backlogSeconds = 0
        }
        if next == .idle { consentAffirmed = false }
    }
}

extension SessionModel {
    /// Dev (`--demo-review`): puts a finished fill in front of the review panel, from files.
    public func loadDemoReview(outcome: URL, profile: URL, transcript: URL, select key: String?) throws {
        discoversSources = false
        let out = try JSONDecoder().decode(NotePipeline.Outcome.self, from: Data(contentsOf: outcome))
        let prof = try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: profile))
        let text = try String(contentsOf: transcript, encoding: .utf8)
        self.transcript = try TranscriptText.parse(text, sessionId: "SES-DEMO").transcript
        extraction = NotePipeline.Extraction(pageTitle: out.pageTitle, profile: prof, results: out.results, seconds: out.seconds)
        self.outcome = out
        for s: SessionState in [.armed, .recording(startedAt: .now), .stopping, .transcribing, .extracting,
                                .readyToFill, .filling, .reviewing] { transition(to: s) }
        reviewFilter = .all
        reviewSelection = key
    }

    /// Dev: drives one real session without clicks (`--auto-session`): picks `source`, affirms
    /// consent, starts, waits, stops, and waits for review. Exercises the same path as the menu.
    public func autoRun(source: CallSource, seconds: Double) async {
        discoversSources = false
        sources = [source]
        selectedSourceID = source.id
        refreshPermissions()
        consentAffirmed = true
        start()
        while !state.isCapturing {
            if case .failed = state { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(seconds))
        stop()
        while state != .reviewing {
            if case .failed = state { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
