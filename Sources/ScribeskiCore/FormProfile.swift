/// What the profiler saw on a form. Structure only, never values.
public struct FormProfile: Codable, Hashable, Sendable {
    public enum Schema: SchemaIdentifier { public static let id = "scribeski.form-profile/1" }

    public var schema = SchemaTag<Schema>()
    public var origin: String
    public var pathPattern: String
    /// `sha256:` over (key, kind, options) of every field. Changes when the EHR drifts.
    public var fingerprint: String
    public var steps: [Step]
    public var fields: [Field]
    public var unreachable: [Unreachable]

    public init(origin: String, pathPattern: String, fingerprint: String,
                steps: [Step], fields: [Field], unreachable: [Unreachable] = []) {
        self.origin = origin
        self.pathPattern = pathPattern
        self.fingerprint = fingerprint
        self.steps = steps
        self.fields = fields
        self.unreachable = unreachable
    }

    enum CodingKeys: String, CodingKey {
        case schema, origin, fingerprint, steps, fields, unreachable
        case pathPattern = "path_pattern"
    }

    public struct Step: Codable, Hashable, Sendable {
        public var id: String
        public var activate: Activation

        public init(id: String, activate: Activation) {
            self.id = id
            self.activate = activate
        }
    }

    public struct Activation: Codable, Hashable, Sendable {
        /// Selectors clicked in order to make the step visible.
        public var click: [String]

        public init(click: [String]) { self.click = click }
    }

    public enum Kind: String, Codable, Hashable, Sendable {
        case text, textarea, date, select, combobox, hidden
        case radioGroup = "radio_group"
        case checkboxGroup = "checkbox_group"
    }

    public enum LabelSource: String, Codable, Hashable, Sendable {
        case labelFor = "label_for"
        case labelWrap = "label_wrap"
        case ariaLabelledby = "aria_labelledby"
        case ariaLabel = "aria_label"
        case placeholder
        case precedingText = "preceding_text"
        case legend
    }

    public enum WriteStrategy: String, Codable, Hashable, Sendable {
        case nativeSetter = "native_setter"
        case select
        case clickToggle = "click_toggle"
        case comboboxClick = "combobox_click"
        case never
    }

    public struct Option: Codable, Hashable, Sendable {
        public var value: String
        public var label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public struct Field: Codable, Hashable, Sendable {
        /// Stable key: id → name → data-testid → hash(label, kind, step).
        public var key: String
        public var step: String
        /// Iframe selector path from the top document; empty for top-level fields.
        public var frame: [String]
        public var kind: Kind
        public var label: String
        /// Nil for fields with no visible label (hidden inputs).
        public var labelSource: LabelSource?
        public var help: String?
        public var required: Bool
        public var options: [Option]
        /// Ordered candidates, most specific first. `xpath=` prefix for XPath.
        public var selectors: [String]
        public var write: WriteStrategy
        /// True for page-computed fields (e.g. `phq9_score`). Never written, only verified.
        public var computed: Bool

        public init(key: String, step: String, frame: [String] = [], kind: Kind, label: String,
                    labelSource: LabelSource?, help: String? = nil, required: Bool = false,
                    options: [Option] = [], selectors: [String], write: WriteStrategy,
                    computed: Bool = false) {
            self.key = key
            self.step = step
            self.frame = frame
            self.kind = kind
            self.label = label
            self.labelSource = labelSource
            self.help = help
            self.required = required
            self.options = options
            self.selectors = selectors
            self.write = write
            self.computed = computed
        }

        enum CodingKeys: String, CodingKey {
            case key, step, frame, kind, label, help, required, options, selectors, write, computed
            case labelSource = "label_source"
        }
    }

    public struct Unreachable: Codable, Hashable, Sendable {
        public var frame: String
        public var reason: String

        public init(frame: String, reason: String) {
            self.frame = frame
            self.reason = reason
        }
    }
}
