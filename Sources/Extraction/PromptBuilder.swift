import Foundation
import ScribeskiCore

/// Builds the per-field chat messages.
///
/// Layout is load-bearing (DESIGN §4): the **prefix** (rules, session metadata, transcript)
/// is byte-identical for every field of a session so the server's prefix cache serves it;
/// the **suffix** describes exactly one field and nothing else.
///
/// Nothing here is model-specific. Chat templates without a system role (Gemma) fold the
/// system message into the first user turn *ahead of* the user content, so the token prefix
/// stays identical either way; `.singleUser` exists for templates that reject a system
/// message outright.
public struct PromptBuilder: Sendable {
    public enum Layout: String, Sendable, Hashable {
        /// `[system: prefix, user: field]`.
        case systemAndUser
        /// `[user: prefix + "\n\n" + field]`.
        case singleUser
    }

    public var layout: Layout
    /// Eval only: a per-run marker at the very start of the prefix. It makes request 1 a cold
    /// prefill whatever the server already cached, so the cache assertion measures reuse
    /// within this run. Identical for every request in the run, so it doesn't break reuse.
    public var runNonce: String?

    public init(layout: Layout = .systemAndUser, runNonce: String? = nil) {
        self.layout = layout
        self.runNonce = runNonce
    }

    public func messages(transcript: Transcript, field: FormProfile.Field,
                         mapping: FormMapping.FieldMapping, gated: Bool = false) -> [ChatMessage] {
        let prefix = (runNonce.map { "[eval run \($0)]\n" } ?? "") + Self.prefix(transcript: transcript)
        let suffix = Self.suffix(field: field, mapping: mapping, gated: gated)
        switch layout {
        case .systemAndUser:
            return [ChatMessage(role: "system", content: prefix), ChatMessage(role: "user", content: suffix)]
        case .singleUser:
            return [ChatMessage(role: "user", content: prefix + "\n\n" + suffix)]
        }
    }

    // MARK: - Prefix

    static let rules = """
    You fill one field of a social-work session note from the session transcript below.
    Each request asks about exactly one field. Answer only about that field, as JSON.

    Rules:
    1. Quote verbatim. Every piece of evidence is a segment id (like s0042) and an exact quote copied from that segment's text. Do not paraphrase, fix grammar, join distant lines, or use "..." to skip words. If the words you need span consecutive lines by the same speaker, cite each line as its own evidence item. Quote only the words that carry the answer: usually one short sentence, never a whole paragraph.
    2. Prefer insufficient_evidence. If the transcript does not clearly state the answer, return status "insufficient_evidence" with no evidence and a null value. A blank field is safe; a wrong one goes into a clinical record. Never guess, and never pick an option just because it seems likely.
    3. Never infer scores, totals, severity bands, diagnoses, or risk levels. Only record what was said.
    4. Speakers matter. WORKER lines are the social worker; CLIENT lines are the client. A worker's question is not the client's answer: when the worker names something in a question and the client answers "No", that thing is denied, not reported.
    5. Other people are not the client. Something true of a family member, friend, or anyone else (their language, drinking, faith, health) is never an answer about the client.
    6. Hypotheticals, plans, and conditionals are not facts. "If I lose the apartment..." does not mean it happened; "we'll do that next week" means it was not done this session.
    7. Something applied for, suggested, or considered is not something received, agreed, or done.
    8. Resolve relative dates ("next Thursday", "the 24th") against the session date below and write dates as YYYY-MM-DD.
    """

    /// The shared prefix: rules, session metadata, and the rendered transcript.
    public static func prefix(transcript: Transcript) -> String {
        var session = "Session:\n"
        if let started = transcript.startedAt {
            session += "- started_at: \(started)"
            if let weekday = weekday(ofISODate: started) {
                session += " (session date \(started.prefix(10)), a \(weekday))"
            }
        } else {
            session += "- started_at: unknown (do not resolve relative dates)"
        }
        return rules + "\n\n" + answerGuide + "\n\n" + session + "\n\nTranscript (each line: [mm:ss] segment_id SPEAKER: text):\n"
            + TranscriptText.renderForPrompt(transcript) + "\n[end of transcript]"
    }

    static func weekday(ofISODate iso: String) -> String? {
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    /// Everything that's the same for every field of a kind lives here, in the cached prefix,
    /// so each request only pays for its own field (~100 tokens instead of ~340).
    static let answerGuide = """
    ANSWER GUIDE (each request names its evidence rule and answer format)

    Evidence rules:
    - CLIENT: at least one quote must be the CLIENT's own words from a CLIENT line. You may also cite the WORKER question it answers. A worker's statement or question alone is never evidence of what the client said. If the client only answers "yes", "yeah", or "no", also cite the worker question.
    - WORKER: at least one quote must come from a WORKER line.
    - EITHER: quotes may come from either speaker, e.g. the worker stating it and the client confirming. If the client only answers "yes", "yeah", or "no", also cite the worker question.

    Was it discussed? (fields marked "ask first"): decide whether the topic actually came up: the worker asked about it, or the client talked about it. If it never came up, answer "discussed": "no". Not discussing a topic is not the same as "none", "no", "independent", "secure", or any other option: never pick an option because nothing was said. If it did come up, give raised_at: the line where it was asked or raised.

    Answer formats:
    - VALUE: {"status":"filled","evidence":[{"segment":"s0000","quote":"<exact words>"}],"value":"<option, YYYY-MM-DD date, or text>"} · not clearly stated: {"status":"insufficient_evidence","evidence":[],"value":null}
    - CHOICES: {"status":"filled","selections":[{"value":"<OPTION>","evidence":[{"segment":"s0000","quote":"<exact words>"}]}]} · each selected option needs evidence that supports that option; never select one the client denied or that was only mentioned in a question · nothing supported: {"status":"insufficient_evidence","selections":[]}
    - FREQUENCY: don't choose an option; report count (a number; the midpoint of a range, e.g. "one or two" → 1.5; 0 for never) and period (day, week, month, or year): {"status":"filled","evidence":[...],"count":2,"period":"month"} ("every other weekend" → 2 per month) · not stated: {"status":"insufficient_evidence","evidence":[],"count":null,"period":null}
    - NARRATIVE: {"status":"filled","sentences":[{"text":"<one sentence>","evidence":[{"segment":"s0000","quote":"<exact words>"}]}]} · plain, factual, third-person sentences, each with its own evidence, saying only what its quotes support · nothing to write: {"status":"insufficient_evidence","sentences":[]}
    - With "ask first", every answer starts with the gate: {"discussed":"yes","raised_at":{"segment":"s0000","quote":"<where it came up>"},"status":...} or {"discussed":"no","status":"insufficient_evidence", then the empty answer}.
    """

    // MARK: - Suffix

    /// The one-field request. Mentions no other field.
    public static func suffix(field: FormProfile.Field, mapping: FormMapping.FieldMapping,
                              gated: Bool = false) -> String {
        var lines: [String] = ["FIELD"]
        lines.append("key: \(field.key)")
        lines.append("label: \(field.label)")
        if let help = field.help, !help.isEmpty { lines.append("help: \(help)") }
        lines.append("meaning: \(mapping.intent)")
        lines.append("kind: \(kindDescription(field, mapping))")

        if mapping.mode != .narrative, !field.options.isEmpty {
            lines.append("options (use the value in capitals):")
            for option in field.options {
                var line = "- \(option.value): \(option.label)"
                if let meaning = mapping.optionSemantics?[option.value], !meaning.isEmpty {
                    line += " (means: \(meaning))"
                }
                lines.append(line)
            }
        }

        let rule = switch mapping.evidenceSpeaker {
        case .client: "CLIENT"
        case .worker: "WORKER"
        case .any: "EITHER"
        }
        let format = mapping.mode == .narrative ? "NARRATIVE"
            : mapping.perMonthBands != nil ? "FREQUENCY"
            : field.kind == .checkboxGroup ? "CHOICES" : "VALUE"
        lines.append("")
        lines.append("evidence rule: \(rule) · answer format: \(format)" + (gated ? " · ask first: was it discussed?" : ""))
        return lines.joined(separator: "\n")
    }

    static func kindDescription(_ field: FormProfile.Field, _ mapping: FormMapping.FieldMapping) -> String {
        if mapping.mode == .narrative {
            let cap = mapping.maxChars ?? SchemaBuilder.defaultNarrativeMaxChars
            return "narrative (short factual sentences, at most \(cap) characters in total)"
        }
        switch field.kind {
        case .select, .combobox: return "single choice"
        case .radioGroup: return "single choice"
        case .checkboxGroup: return "multiple choice (select every option that applies, each with its own evidence)"
        case .date: return "date (YYYY-MM-DD)"
        case .text, .hidden:
            return "short text (at most \(mapping.maxChars ?? SchemaBuilder.defaultTextMaxChars) characters)"
        case .textarea:
            return "text (at most \(mapping.maxChars ?? SchemaBuilder.defaultTextMaxChars) characters)"
        }
    }
}
