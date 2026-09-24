// Contract types, mirrored from Sources/ScribeskiCore (FormProfile, FieldResult, FillReport).
// JSON keys are snake_case exactly as the Swift CodingKeys; optional keys are omitted, not null.

export type Kind = "text" | "textarea" | "date" | "select" | "radio_group" | "checkbox_group" | "combobox" | "hidden";

export type LabelSource =
  | "label_for"
  | "label_wrap"
  | "aria_labelledby"
  | "aria_label"
  | "placeholder"
  | "preceding_text"
  | "legend";

export type WriteStrategy = "native_setter" | "select" | "click_toggle" | "combobox_click" | "never";

/** One string, or the checked option values of a checkbox group. */
export type FieldValue = string | string[];

export interface Option {
  value: string;
  label: string;
}

export interface Field {
  key: string;
  step: string;
  /** Iframe selector path from the top document; empty for top-level fields. */
  frame: string[];
  kind: Kind;
  label: string;
  label_source?: LabelSource;
  help?: string;
  required: boolean;
  options: Option[];
  /** Most specific first; the last is always an `xpath=` structural path. */
  selectors: string[];
  write: WriteStrategy;
  computed: boolean;
}

export interface Step {
  id: string;
  activate: { click: string[] };
}

export interface FormProfile {
  schema: "scribeski.form-profile/1";
  origin: string;
  path_pattern: string;
  fingerprint: string;
  steps: Step[];
  fields: Field[];
  unreachable: { frame: string; reason: string }[];
}

/** The subset of FieldResult the filler keeps. Evidence is dropped on receipt. */
export interface FieldResult {
  key: string;
  status: string;
  value?: FieldValue | null;
}

export type Outcome = "ok" | "reverted" | "conflict_skipped" | "not_found" | "computed_verified" | "computed_mismatch";

export interface FillReport {
  key: string;
  intended: FieldValue | null;
  read_back: FieldValue | null;
  outcome: Outcome;
  prior_value: FieldValue | null;
}
