import AppKit
import Capture
import Extraction
import Foundation
import ScribeskiCore
import Orchestrator
import Storage
import SuiteModelStore
import Transcription
import UserNotifications

/// The real session (P2–P3): capture and streaming transcription feeding the menu, then
/// extraction on the locked-down sidecar, the worker's confirmation of the target tab, and
/// the fill. Every step is audited (no text), and session data is sealed with its own key.
@MainActor public final class LiveDriver: SessionDriver {
    public let simulationNote: String? = nil
    private var transcriber: any Transcriber
    /// Loads the speech model once, at launch, so Start doesn't wait on it; again if Settings
    /// changes the engine or the vocabulary.
    private var prepared: Task<Void, Error>
    private var preparedFor: (AppSettings.Engine, [String])?
    private let settings = AppSettings.shared
    private var live: LiveTranscription?
    private var vault: AudioVault?
    private var player: SegmentPlayer?
    private var poller: Task<Void, Never>?
    private var sleepAssertion: SessionGuards.SleepAssertion?
    private let store: SessionStore?
    private let audit = AuditLog()
    private let tagger = ClientTagger()
    private let forms = FormLibrary()
    private var sessionID: String?
    private var checkpoint: Task<Void, Never>?
    private var recordingStarted: Date?

    /// How long a confirmed session's transcript and results stay before the key is destroyed
    /// (DESIGN §8). Settings → General; lockable by the agency.
    public var transcriptDays: Int { settings.transcriptDays }
    #if DEBUG
    /// Dev only (`--silent` with `--auto-session`): mute the tapped test player. Not in Release.
    nonisolated(unsafe) public static var devSilenceSource = false
    #endif

    public init(transcriber: (any Transcriber)? = nil) {
        let engine = AppSettings.shared.engine, vocabulary = AppSettings.shared.vocabulary
        let transcriber = transcriber ?? Self.defaultTranscriber(engine)
        self.transcriber = transcriber
        preparedFor = (engine, vocabulary)
        prepared = Task { try await transcriber.prepare(locale: Locale(identifier: "en_US"), vocabulary: vocabulary) }
        store = try? SessionStore()
        // Retention scheduler: at launch, then hourly (BUILD_PLAN P3.5).
        Task { [weak self] in
            while let self {
                self.purgeDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// The chosen engine. Parakeet falls back to Apple's SpeechAnalyzer (nothing to install)
    /// until its weights are downloaded.
    public static func defaultTranscriber(_ engine: AppSettings.Engine = .parakeet) -> any Transcriber {
        switch engine {
        case .parakeet: (try? ParakeetTranscriber.fromModelStore()) ?? SpeechAnalyzerTranscriber()
        case .speechanalyzer: SpeechAnalyzerTranscriber()
        }
    }

    /// Re-prepares if Settings changed the engine or vocabulary since the last session.
    private func refreshTranscriber() {
        let want = (settings.engine, settings.vocabulary)
        guard preparedFor.map({ $0.0 != want.0 || $0.1 != want.1 }) ?? true else { return }
        let t = Self.defaultTranscriber(want.0)
        transcriber = t
        preparedFor = want
        prepared = Task { try await t.prepare(locale: Locale(identifier: "en_US"), vocabulary: want.1) }
    }

    public var engine: String { transcriber.engine }

    private func stage(_ name: String) {
        guard let sessionID else { return }
        try? store?.update(sessionID, stage: name)
    }

    private func log(_ event: String, _ details: [String: String] = [:]) {
        guard let sessionID else { return }
        try? audit.append(session: sessionID, event: event, details)
    }

    private func purgeDue() {
        for id in (try? store?.purgeDue()) ?? [] {
            try? audit.append(session: id, event: "purged", ["reason": "retention"])
        }
    }

    // MARK: - Recording

    public func start(source: CallSource, retention: Retention, model: SessionModel) {
        model.statusNote = "Loading the speech model…"
        refreshTranscriber()
        Task {
            var created: String?  // this attempt's session, and only it, is cleaned up on failure
            do {
                if retention == .none { try SessionGuards.checkZeroRecording() }
                try await prepared.value
                let id = "SES-\(UUID().uuidString.prefix(8))"
                try store?.create(id: id, retention: retention)
                created = id
                // Retained modes only: the encrypted audio copy, under its own key (P2.6).
                var vault: AudioVault?
                if retention.retainsAudio, let store { vault = try AudioVault(store: store, sessionID: id) }
                self.vault = vault
                var tee: (@Sendable (Utterance) -> Void)?
                if let vault {
                    tee = { u in vault.append(u.speaker, u.buffer.int16Samples, at: u.start) }
                }
                let live = LiveTranscription(sessionId: id, retention: retention, transcriber: transcriber, handlers: .init(
                    levels: { levels in Task { @MainActor in model.apply(levels: levels) } },
                    segment: { segment in Task { @MainActor in model.liveSegments.append(segment) } },
                    audio: tee))
                sessionID = live.sessionId
                if let chart = model.chart { try? store?.seal(chart, as: "chart", in: live.sessionId) }
                try? store?.update(live.sessionId, form: model.chart?.fingerprint ?? model.selectedFormFingerprint,
                                   template: model.templateID)
                var armed = ["consent": "affirmed", "retention": retention.rawValue, "source": source.bundleID,
                             "source_kind": "\(source.kind)", "engine": transcriber.engine]
                if let chart = model.chart {
                    // The worker confirmed this chart by pressing Start. Keyed hash, never the ID.
                    armed["client"] = (try? tagger.tag(chart.clientID)) ?? "untagged"
                    armed["form"] = chart.formName
                } else {
                    armed["client"] = "unbound"
                }
                log("armed", armed)
                #if DEBUG
                try live.start(source: source, silenceSource: Self.devSilenceSource)
                #else
                try live.start(source: source)
                #endif
                self.live = live
                recordingStarted = .now
                sleepAssertion = SessionGuards.SleepAssertion()
                model.statusNote = nil
                model.microphoneName = live.microphoneName
                model.liveSegments = []
                model.transition(to: .recording(startedAt: live.startedAt))
                stage("recording")
                log("recording", ["microphone": live.microphoneName == nil ? "none" : "yes"])
                // Crash recovery: seal the transcript so far every 20 s. Text, encrypted.
                checkpoint = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        guard !Task.isCancelled else { return }
                        try? self?.store?.seal(live.snapshot(), as: "transcript-partial", in: id)
                    }
                }
                poller = Task { [weak model] in
                    while !Task.isCancelled, let model {
                        model.backlogSeconds = live.backlogSeconds
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            } catch {
                model.statusNote = nil
                log("failed", ["stage": "arming", "error": "\(type(of: error))"])
                // Nothing was captured: don't leave an empty session waiting for review.
                vault = nil
                if let id = created { try? store?.purge(id); sessionID = nil }
                model.transition(to: .failed(stage: .arming, message: "\(error)"))
            }
        }
    }

    public func stop(model: SessionModel) {
        poller?.cancel()
        poller = nil
        guard let live else { return }
        self.live = nil
        sleepAssertion = nil
        checkpoint?.cancel()
        checkpoint = nil
        stage("transcribing")
        model.transition(to: .stopping)
        model.transition(to: .transcribing)
        let seconds = recordingStarted.map { Date.now.timeIntervalSince($0) } ?? 0
        log("stopped", ["seconds": String(Int(seconds))])
        Task {
            // Capture stops at once; the transcriber finalizes what's in flight (seconds).
            let transcript = await live.stop()
            vault?.finish()
            vault = nil
            model.transcript = transcript
            model.transcriberErrors = live.errors
            if let id = sessionID { try? store?.seal(transcript, as: "transcript", in: id) }
            log("transcribed", ["segments": String(transcript.segments.count), "gaps": String(transcript.gaps.count),
                                "engine": transcriber.engine, "bleed_dropped": String(live.bleedDropped)])
            await extract(model)
        }
    }

    // MARK: - Notes

    private func pipeline() throws -> NotePipeline {
        NotePipeline(llm: try .fromModelStore(), forms: forms)
    }

    private func extract(_ model: SessionModel) async {
        guard let transcript = model.transcript else { return }
        model.transition(to: .extracting)
        stage("extracting")
        do {
            // The learned form is enough: the chart needn't be open until it's time to fill.
            let fingerprint = model.chart?.fingerprint ?? model.selectedFormFingerprint
            guard let form = fingerprint.flatMap(forms.form(fingerprint:)) ?? forms.forms().first else {
                throw NotePipeline.Failure.formNotLearned(title: "No form", fingerprint: "none learned")
            }
            let pipeline = try pipeline()
            model.unvalidatedModels = Self.unvalidated(llm: pipeline.llm)
            let template = form.template(model.templateID)
            let extraction = try await pipeline.extract(transcript: transcript, form: form, binding: model.chart,
                                                        template: template) { stage in
                Task { @MainActor in
                    model.statusNote = switch stage {
                    case .profiling: "Reading the form…"
                    case .loadingModel: "Loading the language model…"
                    case .extracting: "Writing the notes…"
                    case .filling: nil
                    }
                }
            }
            model.statusNote = nil
            model.extraction = extraction
            if let id = sessionID { try? store?.seal(extraction.results, as: "results", in: id) }
            var counts: [String: String] = ["model": pipeline.llm.modelName, "form": form.name, "template": template.id]
            for r in extraction.results { counts[r.status.rawValue, default: "0"] = String(Int(counts[r.status.rawValue] ?? "0")! + 1) }
            log("extracted", counts)
            model.transition(to: .readyToFill)
            stage("readyToFill")
            locateChart(model: model)
            Self.notify("Notes are ready", model.chart.map { "Fill \($0.shortName)'s chart when you're ready." }
                        ?? "Choose the chart to fill.")
        } catch {
            model.statusNote = nil
            Self.notify("Notes couldn't be written", "Open Scribeski to retry. The transcript is saved.")
            log("failed", ["stage": "extracting", "error": "\(type(of: error))"])
            model.transition(to: .failed(stage: .extracting, message: "\(error)"))
        }
    }

    /// Models in use that haven't passed the eval gates (custom, or not yet validated).
    static func unvalidated(llm: LlamaServer.Configuration) -> [String] {
        var out: [String] = []
        if !llm.validated { out.append(llm.modelName) }
        if let locator = try? ModelLocator(appName: "Scribeski", appID: "scribeski"),
           AppSettings.shared.engine == .parakeet, !locator.resolution(.asr).validated {
            out.append(locator.name(.asr) ?? "speech model")
        }
        return out
    }

    /// Bound: find that client's tab. Not yet bound: offer the open charts of this form.
    public func locateChart(model: SessionModel) {
        let finder = ChartFinder(forms: forms)
        if let chart = model.chart {
            let all = finder.locateAll(chart)
            model.fillChoices = all.count > 1 ? all : []
            // Keep the worker's earlier choice if that tab still shows the chart.
            if let chosen = model.fillCandidate, all.contains(where: { $0.id == chosen.id }) {
                model.fillCandidate = all.first { $0.id == chosen.id }
            } else {
                model.fillCandidate = all.count == 1 ? all[0] : nil
            }
            model.fillTarget = model.fillCandidate?.tab.title
        } else {
            let fingerprint = model.extraction?.profile.fingerprint
            model.chartCandidates = finder.candidates().filter { $0.binding.fingerprint == fingerprint }
            model.fillCandidate = nil
            model.fillTarget = nil
        }
    }

    /// The tab chosen for this chart, checked fresh: tabs move, windows close. Review actions
    /// stay on the tab that was filled.
    private func chartTab(_ model: SessionModel) throws -> ChartCandidate {
        guard let chart = model.chart else { throw NotePipeline.Failure.wrongTarget(expected: "a chart", found: "none chosen") }
        let finder = ChartFinder(forms: forms)
        if let chosen = model.fillCandidate {
            guard let current = finder.locateAll(chart).first(where: { $0.id == chosen.id }) else {
                throw NotePipeline.Failure.chartNotOpen(chart)
            }
            return current
        }
        guard let found = finder.locate(chart) else { throw NotePipeline.Failure.chartNotOpen(chart) }
        return found
    }

    public func confirmFill(model: SessionModel) {
        guard var extraction = model.extraction, let chart = model.chart else { return }
        let target: ChartCandidate
        do {
            target = try chartTab(model)
        } catch {
            model.reviewError = "\(error)"
            locateChart(model: model)
            return
        }
        extraction.binding = chart
        model.extraction = extraction
        model.transition(to: .filling)
        stage("filling")
        try? store?.seal(chart, as: "chart", in: sessionID ?? "")
        let client = (try? tagger.tag(chart.clientID)) ?? "untagged"
        log("fill_confirmed", ["fields": String(extraction.results.count), "client": client])
        Task {
            do {
                let outcome = try await pipeline().fill(extraction, at: target)
                model.outcome = outcome
                if let id = sessionID { try? store?.seal(outcome.reports, as: "fill-reports", in: id) }
                var counts: [String: String] = ["page_requests": String(outcome.pageNetworkRequests),
                                                "identity": outcome.identity, "client": client]
                for r in outcome.reports { counts[r.outcome.rawValue, default: "0"] = String(Int(counts[r.outcome.rawValue] ?? "0")! + 1) }
                log("filled", counts)
                refreshPlayback(model)
                model.transition(to: .reviewing)
                stage("reviewing")
            } catch let NotePipeline.Failure.formChanged(form, drift) {
                model.drift = drift
                log("form_changed", ["form": form, "summary": drift?.summary ?? "unknown"])
                model.transition(to: .failed(stage: .filling,
                                             message: "\(NotePipeline.Failure.formChanged(form: form, drift: drift))"))
            } catch {
                log("failed", ["stage": "filling", "error": "\(type(of: error))", "client": client])
                model.transition(to: .failed(stage: .filling, message: "\(error)"))
            }
        }
    }

    // MARK: - Review

    public func focus(_ key: String, model: SessionModel) {
        model.busyKey = key
        model.reviewError = nil
        Task {
            defer { model.busyKey = nil }
            do { try await pipeline().focus(key: key, at: chartTab(model)) } catch { model.reviewError = "\(error)" }
        }
    }

    public func write(_ key: String, _ value: FieldValue, model: SessionModel) {
        model.busyKey = key
        model.reviewError = nil
        Task {
            defer { model.busyKey = nil }
            do {
                if let report = try await pipeline().write(key: key, value: value, at: chartTab(model)) {
                    model.outcome?.reports.append(report)
                    if report.outcome == .ok {
                        model.edited[key] = value
                    } else {
                        model.reviewError = "The form didn't keep that value (\(report.outcome.rawValue))."
                    }
                    // The key, never the value: the audit log holds no session content.
                    log("edited_by_worker", ["field": key, "outcome": report.outcome.rawValue])
                }
            } catch {
                model.reviewError = "\(error)"
            }
        }
    }

    public func undoAll(model: SessionModel) {
        guard let reports = model.outcome?.reports else { return }
        model.busyKey = "*"
        model.reviewError = nil
        Task {
            defer { model.busyKey = nil }
            do {
                let results = try await pipeline().undo(reports: reports, at: chartTab(model))
                let restored = results.filter { $0.outcome == "restored" }.count
                log("undo_all", ["restored": String(restored), "fields": String(results.count)])
                model.outcome = nil
                model.edited = [:]
                model.transition(to: .readyToFill)
                locateChart(model: model)
            } catch {
                model.reviewError = "\(error)"
            }
        }
    }

    public func retry(_ stage: SessionState.Stage, model: SessionModel) {
        switch stage.resumeState {
        case .extracting:
            Task { await extract(model) }
        case .readyToFill:
            model.transition(to: .readyToFill)
            locateChart(model: model)
        case .transcribing where model.transcript != nil:
            model.transition(to: .transcribing)
            Task { await extract(model) }
        default:
            model.transition(to: .idle)
        }
    }

    /// A notification while the worker is elsewhere (P3.6). Clicking it opens the panel. No
    /// session content: the client's short name at most.
    static func notify(_ title: String, _ body: String) {
        guard !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "scribeski-\(UUID())", content: content, trigger: nil))
    }

    // MARK: - Recovery

    public func findRecovery(model: SessionModel) {
        model.unconfirmedLimit = settings.unconfirmedLimit
        if model.state == .idle { model.retention = settings.retention }
        guard model.state == .idle, live == nil, let store else {
            model.recovery = nil
            return
        }
        model.pendingSessions = store.resumable.map { meta in
            let transcript = (try? store.open(Transcript.self, "transcript", in: meta.id))
                ?? (try? store.open(Transcript.self, "transcript-partial", in: meta.id))
            let chart = try? store.open(ChartBinding.self, "chart", in: meta.id)
            return .init(sessionID: meta.id, started: meta.created, stage: meta.stage ?? "?",
                         client: chart?.display, lines: transcript?.segments.count ?? 0,
                         hasNotes: store.has("results", in: meta.id))
        }
        model.recovery = model.pendingSessions.last
    }

    /// From sealed results: straight to the fill confirmation. Else from the sealed
    /// transcript (full, or the last checkpoint): extract. Never "record again".
    public func resume(model: SessionModel) {
        guard let recovery = model.recovery, let store else { return }
        let id = recovery.sessionID
        guard let transcript = (try? store.open(Transcript.self, "transcript", in: id))
                ?? (try? store.open(Transcript.self, "transcript-partial", in: id)) else {
            model.recovery = nil
            return
        }
        let meta = try? store.meta(id)
        sessionID = id
        model.recovery = nil
        model.transcript = transcript
        model.chart = try? store.open(ChartBinding.self, "chart", in: id)
        model.selectedFormFingerprint = meta?.form ?? model.chart?.fingerprint
        model.templateID = meta?.template
        log("resumed", ["from": recovery.stage, "lines": String(transcript.segments.count)])
        if let results = try? store.open([FieldResult].self, "results", in: id),
           let form = forms.form(fingerprint: model.chart?.fingerprint ?? meta?.form ?? "") {
            model.extraction = NotePipeline.Extraction(pageTitle: form.name, profile: form.profile, results: results,
                                                       binding: model.chart, template: form.template(meta?.template))
            model.transition(to: .readyToFill)
            stage("readyToFill")
            locateChart(model: model)
        } else {
            Task { await extract(model) }
        }
    }

    /// Installs the re-matched form in place of the old one, moves the notes to the new keys
    /// (a moved field keeps its answer; a removed one drops it), and returns to the fill.
    public func acceptDrift(model: SessionModel) {
        guard let drift = model.drift, var chart = model.chart, var extraction = model.extraction else { return }
        do {
            try forms.replace(chart.fingerprint, with: drift.form)
        } catch {
            model.reviewError = "\(error)"
            return
        }
        let renames = Dictionary(uniqueKeysWithValues: drift.renamed.map { ($0.old, $0.new) })
        let keys = Set(drift.form.profile.fields.map(\.key))
        extraction.results = extraction.results.compactMap { r in
            var r = r
            r.key = renames[r.key] ?? r.key
            return keys.contains(r.key) ? r : nil
        }
        extraction.profile = drift.form.profile
        chart.fingerprint = drift.form.fingerprint
        extraction.binding = chart
        model.extraction = extraction
        model.chart = chart
        model.drift = nil
        log("form_relearned", ["summary": drift.summary, "moved": String(drift.renamed.count),
                               "new": String(drift.added.count), "removed": String(drift.removed.count)])
        retry(.filling, model: model)
    }

    public func discardRecovery(model: SessionModel) {
        guard let recovery = model.recovery else { return }
        try? store?.purge(recovery.sessionID)
        try? audit.append(session: recovery.sessionID, event: "discarded", ["from": recovery.stage])
        model.pendingSessions.removeAll { $0.sessionID == recovery.sessionID }
        model.recovery = model.pendingSessions.last
    }

    // MARK: - Playback (P2.6)

    public func play(_ segment: Transcript.Segment, model: SessionModel) {
        guard let store, let id = sessionID, store.hasAudio(id) else { model.canPlayAudio = false; return }
        do {
            // A little either side, so the first and last words aren't clipped.
            let samples = try AudioVault.read(store, sessionID: id, speaker: segment.speaker,
                                              from: max(0, segment.start - 0.3), to: segment.end + 0.3)
            let player = self.player ?? SegmentPlayer()
            self.player = player
            model.playingSegmentID = segment.id
            try player.play(samples) { [weak model] in
                if model?.playingSegmentID == segment.id { model?.playingSegmentID = nil }
            }
            log("played", ["seconds": String(Int((segment.end - segment.start).rounded()))])
        } catch {
            model.playingSegmentID = nil
            model.reviewError = "Couldn't play that: \(error)"
        }
    }

    public func stopPlayback(model: SessionModel) {
        player?.stop()
        model.playingSegmentID = nil
    }

    private func refreshPlayback(_ model: SessionModel) {
        model.canPlayAudio = sessionID.map { store?.hasAudio($0) ?? false } ?? false
    }

    public func purge(model: SessionModel) {
        // Confirmed: schedule the key's destruction per transcript retention. Audio kept
        // "until you confirm" is destroyed now (its own key); in `none` there never was any.
        stopPlayback(model: model)
        player = nil
        if let id = sessionID {
            let hadAudio = store?.hasAudio(id) ?? false
            try? store?.confirm(id, transcriptDays: transcriptDays)
            log("confirmed", ["transcript_days": String(transcriptDays)])
            if hadAudio, !(store?.hasAudio(id) ?? false) { log("audio_purged", ["reason": "confirmed"]) }
        }
        model.canPlayAudio = false
        model.transcript = nil
        model.liveSegments = []
        model.extraction = nil
        model.outcome = nil
        model.fillTarget = nil
        model.fillCandidate = nil
        model.chart = nil
        model.chartSelectionID = nil
        model.chartDeferred = false
        model.edited = [:]
        model.reviewSelection = nil
        model.reviewError = nil
        sessionID = nil
        model.transition(to: .purged)
        model.transition(to: .idle)
    }
}

extension SessionModel {
    /// Below this the client track counts as silent (about -54 dBFS).
    static let silenceRMS: Float = 0.002

    func apply(levels: [Speaker: Float]) {
        guard state.isCapturing else { return }
        clientLevel = Self.meter(levels[.client] ?? 0)
        workerLevel = Self.meter(levels[.worker] ?? 0)
        let silent = (levels[.client] ?? 0) < Self.silenceRMS
        clientSilentSeconds = silent ? clientSilentSeconds + 0.05 : 0
    }

    /// Maps RMS onto 0...1 across -60...0 dBFS; speech sits around the middle.
    static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 60) / 60, 0), 1)
    }
}

/// Words the transcriber should expect (DESIGN §3: biasing matters more than model choice).
/// A starting list; P3.4 adds the agency's own terms and the client's name from the form.
public enum Vocabulary {
    public static let `default` = [
        "SNAP", "TANF", "SSI", "SSDI", "CPS", "IEP", "ADLs", "IADLs", "WIC", "Medi-Cal", "Medicaid",
        "PHQ-9", "GAD-7", "HSA", "IHSS", "CalFresh", "Section 8", "SI", "HI",
        "sertraline", "fluoxetine", "trazodone", "quetiapine", "buprenorphine", "naloxone",
    ]
}
