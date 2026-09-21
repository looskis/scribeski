import Foundation
import Observation
import ScribeskiCore
import Transcription

/// Policy and preferences (BUILD_PLAN P3.5, P4.2). Stored in the app's defaults domain, so an
/// agency can lock any of them with a configuration profile (managed preferences): a locked
/// setting shows its value and "Set by your agency", and can't be changed here.
///
/// Keys, for the profile (domain `com.looski.scribeski`):
/// - `Retention`: `none` | `until_confirm` | `days:N`
/// - `TranscriptDays`: days a confirmed session's transcript and notes are kept (1–90)
/// - `UnconfirmedLimit`: warn at this many unreviewed sessions, refuse to start at twice it
/// - `TranscriptionEngine`: `parakeet` | `speechanalyzer`
/// - `Vocabulary`: extra words to expect (array of strings), added to the built-in list
@MainActor @Observable public final class AppSettings {
    public static let shared = AppSettings()

    public enum Engine: String, CaseIterable, Sendable {
        case parakeet, speechanalyzer

        public var title: String {
            switch self {
            case .parakeet: "Parakeet (on the Neural Engine)"
            case .speechanalyzer: "Apple Speech"
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        retention = defaults.string(forKey: Key.retention).flatMap(Retention.init(rawValue:)) ?? .none
        transcriptDays = Self.clamp(defaults.object(forKey: Key.transcriptDays) as? Int ?? 30, 1, 90)
        unconfirmedLimit = Self.clamp(defaults.object(forKey: Key.unconfirmedLimit) as? Int ?? 3, 1, 20)
        engine = defaults.string(forKey: Key.engine).flatMap(Engine.init(rawValue:)) ?? .parakeet
        extraVocabulary = defaults.stringArray(forKey: Key.vocabulary) ?? []
        onboarded = defaults.bool(forKey: Key.onboarded)
    }

    enum Key {
        static let retention = "Retention"
        static let transcriptDays = "TranscriptDays"
        static let unconfirmedLimit = "UnconfirmedLimit"
        static let engine = "TranscriptionEngine"
        static let vocabulary = "Vocabulary"
        static let onboarded = "Onboarded"
    }

    public var retention: Retention { didSet { save(retention.rawValue, Key.retention) } }
    public var transcriptDays: Int { didSet { save(transcriptDays, Key.transcriptDays) } }
    public var unconfirmedLimit: Int { didSet { save(unconfirmedLimit, Key.unconfirmedLimit) } }
    public var engine: Engine { didSet { save(engine.rawValue, Key.engine) } }
    public var extraVocabulary: [String] { didSet { save(extraVocabulary, Key.vocabulary) } }

    /// First-run setup finished (or skipped through). Not agency-lockable.
    public var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Key.onboarded) } }

    /// The agency's configuration profile sets it: shown, not editable.
    public func isLocked(_ key: String) -> Bool { defaults.objectIsForced(forKey: key) }
    public var retentionLocked: Bool { isLocked(Key.retention) }
    public var transcriptDaysLocked: Bool { isLocked(Key.transcriptDays) }
    public var unconfirmedLimitLocked: Bool { isLocked(Key.unconfirmedLimit) }
    public var engineLocked: Bool { isLocked(Key.engine) }
    public var vocabularyLocked: Bool { isLocked(Key.vocabulary) }

    /// Built-in terms plus the agency's and the worker's.
    public var vocabulary: [String] { Vocabulary.default + extraVocabulary }

    private func save(_ value: Any, _ key: String) {
        guard !isLocked(key) else { return }
        defaults.set(value, forKey: key)
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
