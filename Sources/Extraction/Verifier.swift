import Foundation
import ScribeskiCore

/// Checks a model answer against the transcript, in code. The model is never trusted to
/// have quoted correctly, attributed correctly, or read a "No" as a no.
///
/// Rules, applied to each evidence group (a discrete value, one checkbox option, or one
/// narrative sentence):
/// 1. Every quote is found (normalized, word-bounded) in its cited segment, or across a run
///    of adjacent same-speaker segments that are all cited. Unknown id → `segment_not_found`;
///    otherwise → `quote_not_found`.
/// 2. `evidence_speaker: client` needs at least one verified CLIENT quote (`worker`: one
///    WORKER quote) → else `speaker_mismatch`. `any` accepts either.
/// 3. If every client quote is a short negation ("No. None of that.") and the value is a
///    positive selection → `negated_answer`.
/// 4. If every client quote is a bare affirmation ("Yeah.") or a short negation ("No, never.")
///    the worker question right before it must also be cited → else `missing_question_context`.
///
/// Before the rules, a quote whose cited segment id is wrong is **relocated** when it is long
/// (≥ 6 words), not a bare yes/no answer, and occurs in exactly one segment of the whole
/// transcript. Models copy quotes verbatim but misnumber segments; a long unique quote
/// identifies its segment unambiguously, and every rule below then runs against the real
/// segment. Short answers are never moved across the transcript: "No. None of that." means
/// nothing without the question it followed, even when it's unique. The one exception is
/// local and unambiguous: a quote cited under a WORKER line's id that appears in the CLIENT
/// line immediately after it is the answer to that question, so it moves there.
///
/// Questionnaire items (radio groups registered in `questions`): the question a client was
/// answering is the most recent item the worker read. A client answer must follow *this*
/// item's question: another item's → `question_mismatch`; no item at all (the
/// questionnaire wasn't given; the model mapped a general complaint onto it) →
/// `question_not_asked`.
///
/// Checkbox options are verified independently; failing options are dropped. Narrative
/// sentences likewise, then the text is capped at `max_chars` by whole sentences.
///
/// Result statuses: a failed discrete value is `rejected` with its reason. A checkbox or
/// narrative with nothing left is `insufficient_evidence` with the first reason kept. A
/// checkbox or narrative that lost only *some* options/sentences is `filled` and still
/// carries the first dropped reason in `rejectReason`, for eval.
public struct Verifier: Sendable {
    public let transcript: Transcript
    private let indexByID: [String: Int]
    private let normalized: [String]
    /// Questionnaire item key → its question text (e.g. PHQ-9 items), for question anchoring.
    private let questions: [String: Set<String>]

    public init(transcript: Transcript, questions: [String: String] = [:]) {
        self.questions = questions.mapValues(Self.contentWords)
        self.transcript = transcript
        var index: [String: Int] = [:]
        for (i, s) in transcript.segments.enumerated() { index[s.id] = i }
        self.indexByID = index
        self.normalized = transcript.segments.map { TextNormalizer.normalize($0.text) }
    }

    // MARK: - Entry points

    /// Verifies raw model output text (the JSON the grammar produced).
    public func verify(field: FormProfile.Field, mapping: FormMapping.FieldMapping,
                       output: String) -> FieldResult {
        guard let answer = try? JSONValue.parse(output) else {
            return FieldResult(key: field.key, status: .rejected, rejectReason: .malformedOutput)
        }
        return verify(field: field, mapping: mapping, answer: answer)
    }

    /// Verifies a parsed model answer.
    public func verify(field: FormProfile.Field, mapping: FormMapping.FieldMapping,
                       answer original: JSONValue) -> FieldResult {
        var answer = original
        // The "was it discussed?" gate (SchemaBuilder, gated fields).
        if let discussed = answer["discussed"]?.stringValue {
            if discussed != "yes" { return FieldResult(key: field.key, status: .insufficientEvidence) }
            guard let raised = Self.parseEvidence(.array([answer["raised_at"] ?? .null])).map(relocated)?.first,
                  let i = indexByID[raised.segment], quoteFound(raised.quote, at: i, cited: [i]) else {
                return FieldResult(key: field.key, status: .rejected, rejectReason: .quoteNotFound)
            }
            answer = Self.addingRaisedAt(raised, to: answer)
        }
        // Frequency fields: the model reports count + period; code picks the band.
        if let bands = mapping.perMonthBands, answer["status"]?.stringValue == "filled" {
            guard let band = Self.band(count: answer["count"]?.doubleValue,
                                       period: answer["period"]?.stringValue, bands: bands) else {
                return FieldResult(key: field.key, status: .insufficientEvidence, rejectReason: .invalidOption)
            }
            if var o = answer.objectValue { o["value"] = .string(band); answer = .object(o) }
        }
        switch answer["status"]?.stringValue {
        case "insufficient_evidence":
            return FieldResult(key: field.key, status: .insufficientEvidence)
        case "filled":
            break
        default:
            return FieldResult(key: field.key, status: .rejected, rejectReason: .malformedOutput)
        }
        if mapping.mode == .narrative {
            return verifyNarrative(field: field, mapping: mapping, answer: answer)
        }
        if field.kind == .checkboxGroup {
            return verifyCheckbox(field: field, mapping: mapping, answer: answer)
        }
        return verifyDiscrete(field: field, mapping: mapping, answer: answer)
    }

    // MARK: - Shapes

    func verifyDiscrete(field: FormProfile.Field, mapping: FormMapping.FieldMapping,
                        answer: JSONValue) -> FieldResult {
        let evidence = Self.parseEvidence(answer["evidence"]).map(relocated)
        guard let raw = answer["value"]?.stringValue else {
            return FieldResult(key: field.key, status: .rejected, evidence: evidence ?? [],
                               rejectReason: .invalidOption)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = FieldValue.single(text)
        var positive = false

        switch field.kind {
        case .select, .radioGroup, .combobox:
            guard let option = field.options.first(where: { $0.value == text }) else {
                return FieldResult(key: field.key, status: .rejected, value: value,
                                   evidence: evidence ?? [], rejectReason: .invalidOption)
            }
            positive = !TextNormalizer.isNegativeOption(
                value: option.value, label: option.label, semantics: mapping.optionSemantics?[option.value])
        case .date:
            guard Self.isISODate(text) else {
                return FieldResult(key: field.key, status: .rejected, value: value,
                                   evidence: evidence ?? [], rejectReason: .invalidOption)
            }
        case .text, .textarea, .hidden, .checkboxGroup:
            guard !text.isEmpty else {
                return FieldResult(key: field.key, status: .insufficientEvidence)
            }
        }

        guard let evidence else {
            return FieldResult(key: field.key, status: .rejected, value: value, rejectReason: .quoteNotFound)
        }
        if let reason = check(evidence, speaker: mapping.evidenceSpeaker, positiveSelection: positive,
                              questionnaire: questions[field.key] != nil)
            ?? checkQuestion(field: field, evidence: evidence) {
            return FieldResult(key: field.key, status: .rejected, value: value, evidence: evidence,
                               rejectReason: reason)
        }
        return FieldResult(key: field.key, status: .filled, value: value, evidence: evidence)
    }

    func verifyCheckbox(field: FormProfile.Field, mapping: FormMapping.FieldMapping,
                        answer: JSONValue) -> FieldResult {
        var kept: [(value: String, evidence: [FieldResult.Evidence], positive: Bool)] = []
        var firstReason: FieldResult.RejectReason?
        var seen: Set<String> = []

        for selection in answer["selections"]?.arrayValue ?? [] {
            guard let value = selection["value"]?.stringValue,
                  let option = field.options.first(where: { $0.value == value }) else {
                firstReason = firstReason ?? .invalidOption
                continue
            }
            guard seen.insert(value).inserted else { continue }
            let positive = !TextNormalizer.isNegativeOption(
                value: option.value, label: option.label, semantics: mapping.optionSemantics?[option.value])
            guard let evidence = Self.parseEvidence(selection["evidence"]).map(relocated) else {
                firstReason = firstReason ?? .quoteNotFound
                continue
            }
            if let reason = check(evidence, speaker: mapping.evidenceSpeaker, positiveSelection: positive) {
                firstReason = firstReason ?? reason
                continue
            }
            kept.append((value, evidence, positive))
        }

        // "None" options are exclusive: once a positive option survives, they go.
        if kept.contains(where: \.positive) { kept.removeAll { !$0.positive } }

        guard !kept.isEmpty else {
            return FieldResult(key: field.key, status: .insufficientEvidence, rejectReason: firstReason)
        }
        let order = Dictionary(uniqueKeysWithValues: field.options.enumerated().map { ($1.value, $0) })
        kept.sort { order[$0.value, default: 0] < order[$1.value, default: 0] }
        return FieldResult(key: field.key, status: .filled, value: .multiple(kept.map(\.value)),
                           evidence: kept.flatMap(\.evidence), rejectReason: firstReason)
    }

    func verifyNarrative(field: FormProfile.Field, mapping: FormMapping.FieldMapping,
                         answer: JSONValue) -> FieldResult {
        let maxChars = mapping.maxChars ?? SchemaBuilder.defaultNarrativeMaxChars
        var firstReason: FieldResult.RejectReason?
        var text = ""
        var evidence: [FieldResult.Evidence] = []

        for sentence in answer["sentences"]?.arrayValue ?? [] {
            let s = (sentence["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            guard let cited = Self.parseEvidence(sentence["evidence"]).map(relocated) else {
                firstReason = firstReason ?? .quoteNotFound
                continue
            }
            if let reason = check(cited, speaker: mapping.evidenceSpeaker, positiveSelection: false) {
                firstReason = firstReason ?? reason
                continue
            }
            let candidate = text.isEmpty ? s : text + " " + s
            guard candidate.count <= maxChars else { break } // cap by whole sentences
            text = candidate
            evidence.append(contentsOf: cited)
        }

        guard !text.isEmpty else {
            return FieldResult(key: field.key, status: .insufficientEvidence, rejectReason: firstReason)
        }
        return FieldResult(key: field.key, status: .filled, value: .single(text), evidence: evidence,
                           rejectReason: firstReason)
    }

    // MARK: - Evidence rules

    /// Applies rules 1–4 to one evidence group. Nil means it passed.
    /// `questionnaire`: the field is a registered questionnaire item, whose question is found
    /// automatically (`checkQuestion`), so a short "No" needn't cite it.
    public func check(_ evidence: [FieldResult.Evidence], speaker: FormMapping.EvidenceSpeaker,
                      positiveSelection: Bool, questionnaire: Bool = false) -> FieldResult.RejectReason? {
        guard !evidence.isEmpty else { return .quoteNotFound }

        // Rule 1: every segment exists and every quote is in it.
        var indices: [Int] = []
        for item in evidence {
            guard let i = indexByID[item.segment] else { return .segmentNotFound }
            indices.append(i)
        }
        let cited = Set(indices)
        for (item, i) in zip(evidence, indices) where !quoteFound(item.quote, at: i, cited: cited) {
            return .quoteNotFound
        }

        let segments = transcript.segments
        let clientItems = zip(evidence, indices).filter { segments[$0.1].speaker == .client }

        // Rule 2: speaker.
        switch speaker {
        case .client where clientItems.isEmpty: return .speakerMismatch
        case .worker where !indices.contains(where: { segments[$0].speaker == .worker }): return .speakerMismatch
        default: break
        }

        guard !clientItems.isEmpty else { return nil }

        // Rule 3: "No. None of that." never supports a positive selection.
        if positiveSelection, clientItems.allSatisfy({ TextNormalizer.isNegatedShortAnswer($0.0.quote) }) {
            return .negatedAnswer
        }

        // Rule 4: a bare "Yeah." needs the question it answers, and so does a short "No"
        // supporting a negative value: "No, never." means nothing without its question.
        if clientItems.allSatisfy({ TextNormalizer.isBareAffirmation($0.0.quote) })
            || (!questionnaire && clientItems.allSatisfy({ TextNormalizer.isNegatedShortAnswer($0.0.quote) })) {
            for (_, i) in clientItems {
                guard let question = precedingWorkerSegment(before: i), cited.contains(question) else {
                    return .missingQuestionContext
                }
            }
        }
        return nil
    }

    /// Whether `quote` is in segment `i`, or spans a run of adjacent cited segments of the
    /// same speaker that includes `i`.
    func quoteFound(_ quote: String, at i: Int, cited: Set<Int>) -> Bool {
        let q = TextNormalizer.normalize(quote)
        guard !q.isEmpty else { return false }
        if TextNormalizer.contains(normalizedHaystack: normalized[i], normalizedNeedle: q) { return true }

        let segments = transcript.segments
        let speaker = segments[i].speaker
        var lo = i, hi = i
        while lo > 0, cited.contains(lo - 1), segments[lo - 1].speaker == speaker { lo -= 1 }
        while hi + 1 < segments.count, cited.contains(hi + 1), segments[hi + 1].speaker == speaker { hi += 1 }
        guard lo < hi else { return false }
        for a in lo...i {
            for b in i...hi where b > a {
                let joined = normalized[a...b].joined(separator: " ")
                if TextNormalizer.contains(normalizedHaystack: joined, normalizedNeedle: q) { return true }
            }
        }
        return false
    }

    /// `raised_at` joins the evidence (of the value, or of every checkbox selection): it's
    /// verified like any quote and supplies the question context for short answers.
    static func addingRaisedAt(_ raised: FieldResult.Evidence, to answer: JSONValue) -> JSONValue {
        guard var o = answer.objectValue else { return answer }
        let item = JSONValue.obj(["segment": .string(raised.segment), "quote": .string(raised.quote)])
        func prepend(_ list: JSONValue?) -> JSONValue {
            let items = list?.arrayValue ?? []
            return items.contains(item) ? .array(items) : .array([item] + items)
        }
        if let selections = o["selections"]?.arrayValue {
            o["selections"] = .array(selections.map { s in
                guard var so = s.objectValue else { return s }
                so["evidence"] = prepend(so["evidence"])
                return .object(so)
            })
        } else if o["status"]?.stringValue == "filled" {
            o["evidence"] = prepend(o["evidence"])
        }
        return .object(o)
    }

    /// Occasions per month → the band containing it. Nil if the rate falls in no band.
    static func band(count: Double?, period: String?, bands: [String: [Double]]) -> String? {
        guard let count, count >= 0, let period else { return nil }
        let perMonth: Double
        switch period {
        case "day": perMonth = count * 30.4
        case "week": perMonth = count * 4.345
        case "month": perMonth = count
        case "year": perMonth = count / 12
        default: return nil
        }
        return bands.sorted { $0.key < $1.key }.first { _, range in
            range.count == 2 && perMonth >= range[0] && perMonth <= range[1]
        }?.key
    }

    /// Rewrites a misnumbered citation to the one segment that actually contains the quote.
    func relocated(_ evidence: [FieldResult.Evidence]) -> [FieldResult.Evidence] {
        let cited = Set(evidence.compactMap { indexByID[$0.segment] })
        return evidence.map { item in
            if let i = indexByID[item.segment], quoteFound(item.quote, at: i, cited: cited) { return item }
            let q = TextNormalizer.normalize(item.quote)
            // Question id cited with its answer's words.
            if let i = indexByID[item.segment], i + 1 < normalized.count,
               transcript.segments[i].speaker == .worker, transcript.segments[i + 1].speaker == .client,
               !q.isEmpty, TextNormalizer.contains(normalizedHaystack: normalized[i + 1], normalizedNeedle: q) {
                return FieldResult.Evidence(segment: transcript.segments[i + 1].id, quote: item.quote)
            }
            guard q.split(separator: " ").count >= Self.minRelocatableWords,
                  !TextNormalizer.isNegatedShortAnswer(item.quote), !TextNormalizer.isBareAffirmation(item.quote)
            else { return item }
            let hits = normalized.indices.filter {
                TextNormalizer.contains(normalizedHaystack: normalized[$0], normalizedNeedle: q)
            }
            guard hits.count == 1 else { return item }
            return FieldResult.Evidence(segment: transcript.segments[hits[0]].id, quote: item.quote)
        }
    }

    static let minRelocatableWords = 6

    /// For a questionnaire item: every client answer must follow this item's question, not
    /// another item's. Nil when it does, or when no question can be identified.
    func checkQuestion(field: FormProfile.Field, evidence: [FieldResult.Evidence]) -> FieldResult.RejectReason? {
        guard questions[field.key] != nil else { return nil }
        var answered: [String] = []
        for item in evidence {
            guard let i = indexByID[item.segment], transcript.segments[i].speaker == .client,
                  let key = questionAnswered(at: i) else { continue }
            answered.append(key)
        }
        if answered.contains(field.key) { return nil }
        // An item that was never read out can't have been answered.
        return answered.isEmpty ? .questionNotAsked : .questionMismatch
    }

    /// The questionnaire item most recently read by the worker before segment `i`
    /// (looking back at most `questionLookback` worker segments).
    func questionAnswered(at i: Int) -> String? {
        var j = i - 1, workerSeen = 0
        while j >= 0, workerSeen < Self.questionLookback {
            if transcript.segments[j].speaker == .worker {
                workerSeen += 1
                let words = Set(normalized[j].split(separator: " ").map(String.init))
                let scored = questions.map { key, q in (key, Double(q.intersection(words).count) / Double(max(q.count, 1))) }
                if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= Self.questionMatchThreshold { return best.0 }
            }
            j -= 1
        }
        return nil
    }

    static let questionLookback = 4
    static let questionMatchThreshold = 0.6

    /// Distinctive words of a question: normalized, 4+ letters.
    static func contentWords(_ text: String) -> Set<String> {
        Set(TextNormalizer.normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 4 })
    }

    func precedingWorkerSegment(before i: Int) -> Int? {
        var j = i - 1
        while j >= 0 {
            if transcript.segments[j].speaker == .worker { return j }
            j -= 1
        }
        return nil
    }

    // MARK: - Parsing

    /// Nil when the evidence array is missing or any item is malformed.
    static func parseEvidence(_ json: JSONValue?) -> [FieldResult.Evidence]? {
        guard let items = json?.arrayValue else { return nil }
        var out: [FieldResult.Evidence] = []
        for item in items {
            guard let segment = item["segment"]?.stringValue, let quote = item["quote"]?.stringValue else {
                return nil
            }
            out.append(.init(segment: segment, quote: stripLinePrefix(quote)))
        }
        return out
    }

    /// Models sometimes copy the transcript line's prefix into the quote
    /// ("s0330 CLIENT: Um, sertraline…"). The prefix is our formatting, not speech.
    static func stripLinePrefix(_ quote: String) -> String {
        let pattern = #"^\s*(\[[0-9]{1,3}:[0-9]{2}(:[0-9]{2})?\]\s*)?(s[0-9]{4}\s+)?(WORKER|CLIENT)\s*:\s*"#
        guard let r = quote.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return quote }
        return String(quote[r.upperBound...])
    }

    static func isISODate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: comps) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d
    }
}
