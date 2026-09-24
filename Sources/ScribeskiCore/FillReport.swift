/// What actually landed in the page for one field, after read-back.
public struct FillReport: Codable, Hashable, Sendable {
    public var key: String
    public var intended: FieldValue?
    public var readBack: FieldValue?
    public var outcome: Outcome
    /// The value before we wrote, for undo.
    public var priorValue: FieldValue?

    public init(key: String, intended: FieldValue?, readBack: FieldValue?, outcome: Outcome,
                priorValue: FieldValue?) {
        self.key = key
        self.intended = intended
        self.readBack = readBack
        self.outcome = outcome
        self.priorValue = priorValue
    }

    enum CodingKeys: String, CodingKey {
        case key, intended, outcome
        case readBack = "read_back"
        case priorValue = "prior_value"
    }

    public enum Outcome: String, Codable, Hashable, Sendable {
        case ok
        /// Written, then the page changed it back before the settle period ended.
        case reverted
        /// The field already held a different non-empty value; the worker may have typed it.
        case conflictSkipped = "conflict_skipped"
        case notFound = "not_found"
        case computedVerified = "computed_verified"
        case computedMismatch = "computed_mismatch"
    }
}
