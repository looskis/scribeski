import Capture
import Foundation
import ScribeskiCore
import Transcription
import Testing
@testable import ScribeskiUI

/// A defaults domain where chosen keys are "forced", as a configuration profile does.
final class ManagedDefaults: UserDefaults {
    var forced: Set<String> = []
    override func objectIsForced(forKey key: String) -> Bool { forced.contains(key) }
}

@MainActor @Suite struct SettingsBehaviour {
    static func fresh() -> (ManagedDefaults, String) {
        let name = "scribeski.test.\(UUID().uuidString.prefix(8))"
        return (ManagedDefaults(suiteName: name)!, name)
    }

    @Test func defaultsAreTheSafeOnes() {
        let (d, name) = Self.fresh()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        #expect(s.retention == .none, "zero recording unless someone chooses otherwise")
        #expect(s.transcriptDays == 30)
        #expect(s.unconfirmedLimit == 3)
        #expect(s.engine == .parakeet)
        #expect(!s.onboarded)
        #expect(s.vocabulary.starts(with: Vocabulary.default))
    }

    @Test func changesPersistAndOutOfRangeValuesAreClamped() {
        let (d, name) = Self.fresh()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.retention = .days(7)
        s.engine = .speechanalyzer
        s.extraVocabulary = ["Medi-Cal", "CalFresh"]
        d.set(500, forKey: AppSettings.Key.transcriptDays)
        d.set(0, forKey: AppSettings.Key.unconfirmedLimit)
        let again = AppSettings(defaults: d)
        #expect(again.retention == .days(7))
        #expect(again.engine == .speechanalyzer)
        #expect(again.vocabulary.suffix(2) == ["Medi-Cal", "CalFresh"])
        #expect(again.transcriptDays == 90)
        #expect(again.unconfirmedLimit == 1)
    }

    @Test func garbageFromAProfileFallsBackToDefaults() {
        let (d, name) = Self.fresh()
        defer { d.removePersistentDomain(forName: name) }
        d.set("forever", forKey: AppSettings.Key.retention)
        d.set("whisper", forKey: AppSettings.Key.engine)
        let s = AppSettings(defaults: d)
        #expect(s.retention == .none)
        #expect(s.engine == .parakeet)
    }

    @Test func anAgencyLockedSettingCantBeChangedHere() {
        let (d, name) = Self.fresh()
        defer { d.removePersistentDomain(forName: name) }
        d.set("until_confirm", forKey: AppSettings.Key.retention)
        d.forced = [AppSettings.Key.retention]
        let s = AppSettings(defaults: d)
        #expect(s.retentionLocked)
        #expect(!s.engineLocked)
        #expect(s.retention == .untilConfirm)
        s.retention = .none
        #expect(d.string(forKey: AppSettings.Key.retention) == "until_confirm", "not written over the profile")
        #expect(AppSettings(defaults: d).retention == .untilConfirm)
    }
}

@MainActor @Suite struct UnreviewedSessionsGate {
    let zoom = CallSource(bundleID: "us.zoom.xos", name: "Zoom", kind: .callApp, processes: [])

    func ready() -> SessionModel {
        let model = SessionModel(driver: SimulatedDriver())
        model.sources = [zoom]
        model.selectedSourceID = zoom.id
        model.consentAffirmed = true
        return model
    }

    func pending(_ n: Int) -> [SessionModel.Recovery] {
        (0..<n).map { SessionModel.Recovery(sessionID: "SES-\($0)", started: .now, stage: "reviewing",
                                            client: nil, lines: 10, hasNotes: true) }
    }

    @Test func warnsAtTheLimitAndBlocksAtTwiceIt() {
        let model = ready()
        model.unconfirmedLimit = 3
        model.pendingSessions = pending(2)
        #expect(model.canStart && !model.unreviewedWarning)
        model.pendingSessions = pending(3)
        #expect(model.canStart && model.unreviewedWarning)
        model.pendingSessions = pending(6)
        #expect(!model.canStart && model.tooManyUnreviewed && !model.unreviewedWarning)
    }
}
