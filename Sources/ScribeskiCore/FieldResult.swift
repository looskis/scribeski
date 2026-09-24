/// What extraction concluded for one field, and why.
public struct FieldResult: Codable, Hashable, Sendable {
    public var key: String
    public var status: Status
    public var value: FieldValue?
    public var evidence: [Evidence]
    /// Why the verifier rejected the model's answer. Kept for eval; the UI shows
    /// `insufficient_evidence`.
    public var rejectReason: RejectReason?
    /// Model name and weights hash, e.g. `qwen3-8b-q4_k_m@sha256:…`. Nil when no model ran.
    public var model: String?
    public var prefillTokens: Int?
    public var ms: Int?

    public init(key: String, status: Status, value: FieldValue? = nil, evidence: [Evidence] = [],
                rejectReason: RejectReason? = nil, model: String? = nil,
                prefillTokens: Int? = nil, ms: Int? = nil) {
        self.key = key
        self.status = status
        self.value = value
        self.evidence = evidence
        self.rejectReason = rejectReason
        self.model = model
        self.prefillTokens = prefillTokens
        self.ms = ms
    }

    enum CodingKeys: String, CodingKey {
        case key, status, value, evidence, model, ms
        case rejectReason = "reject_reason"
        case prefillTokens = "prefill_tokens"
    }

    public enum Status: String, Codable, Hashable, Sendable {
        case filled
        case insufficientEvidence = "insufficient_evidence"
        case clinicianOnly = "clinician_only"
        case derived
        case rejected
    }

    public enum RejectReason: String, Codable, Hashable, Sendable {
        case quoteNotFound = "quote_not_found"
        case speakerMismatch = "speaker_mismatch"
        case segmentNotFound = "segment_not_found"
        case invalidOption = "invalid_option"
        /// Every client quote is a short negation ("No. None of that.") but the value is a
        /// positive selection.
        case negatedAnswer = "negated_answer"
        /// A bare affirmation ("Yeah.") was cited without the worker question it answers.
        case missingQuestionContext = "missing_question_context"
        /// The model's output wasn't valid JSON of the requested shape. With grammar-constrained
        /// decoding this should never happen; a count above zero means the constraint isn't on.
        case malformedOutput = "malformed_output"
        /// A questionnaire answer that follows a different item's question.
        case questionMismatch = "question_mismatch"
        /// A questionnaire item filled although its question was never read out.
        case questionNotAsked = "question_not_asked"
    }

    public struct Evidence: Codable, Hashable, Sendable {
        public var segment: String
        /// Verbatim text from the segment. Offsets are computed by the verifier, never
        /// asked of the model.
        public var quote: String

        public init(segment: String, quote: String) {
            self.segment = segment
            self.quote = quote
        }
    }
}
