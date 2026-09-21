// Filler + read-back (P1.3): writes FieldResults with per-kind strategies, waits for the
// page to settle, reads everything back, and returns FillReports. Also undo and read_values.
//
// Nothing from extraction but key and value ever reaches this code's working set: evidence
// is deleted from the command on receipt, and no transcript text, quote, or rationale is
// ever put in the DOM (page scripts can read anything we inject).
import {
  comboValue,
  defaultValue,
  idList,
  norm,
  queryAll,
  readValue,
  rememberComboDefaults,
  resolveField,
  sameValue,
  sleep,
  tag,
  view,
} from "./dom";
import { guardedClick, SubmitGuardError } from "./guard";
import { NetWatch, sameOriginWindows, type NetworkSummary } from "./netwatch";
import type { Field, FieldResult, FieldValue, FillReport, FormProfile, Step } from "./types";

export interface FillCommand {
  op: "fill";
  profile: FormProfile;
  results: FieldResult[];
  /** Host-computed values for page-computed fields; null asserts the field stays empty. */
  derived?: Record<string, FieldValue | null>;
  /** Wrong-client guard: textContent of `selector` (top document) must contain `expected`. */
  identity?: { selector: string; expected: string };
  settle_ms?: number;
  /**
   * Keys the worker edited in the review panel: their value replaces whatever the field
   * holds, skipping the conflict check. Never set for machine-written results.
   */
  overwrite?: string[];
  /** Test-only: these keys use a naive `el.value = x`, to prove read-back catches reverts. */
  debug_naive?: string[];
}

export interface UndoCommand {
  op: "undo";
  profile: FormProfile;
  reports: FillReport[];
  /** Same wrong-client guard as fill: restoring client A's values into B's chart is a write. */
  identity?: { selector: string; expected: string };
  settle_ms?: number;
}

export interface FillResponse {
  reports: FillReport[];
  network: NetworkSummary;
  identity: "verified" | "unchecked";
  /** "attribute_only" when the page refused our constructable stylesheet (e.g. CSP). */
  highlight: "stylesheet" | "attribute_only" | "none";
}

export interface UndoResult {
  key: string;
  /** `changed_since`: the field no longer holds what we wrote (the worker or the page changed
   *  it), so it's left alone rather than overwritten with the old value. */
  outcome: "restored" | "failed" | "unrestorable" | "not_found" | "changed_since";
  read_back: FieldValue | null;
}

const DEFAULT_SETTLE_MS = 1000;
const COMBO_OPEN_TIMEOUT_MS = 2000;
const STEP_SETTLE_MS = 50;

type WriteResult = "written" | "no_target" | "unsupported";

interface Work {
  field: Field;
  value: FieldValue;
  report: FillReport;
  els?: Element[];
}

// ---------------------------------------------------------------------------------- fill

export async function fill(cmd: FillCommand): Promise<FillResponse> {
  stripEvidence(cmd);
  const { profile } = cmd;
  const derived = cmd.derived ?? {};
  const naive = new Set(cmd.debug_naive ?? []);
  const overwrite = new Set(cmd.overwrite ?? []);
  const settle = Math.max(0, cmd.settle_ms ?? DEFAULT_SETTLE_MS);

  if (cmd.identity) checkIdentity(cmd.identity);
  rememberComboDefaults();

  const byKey = new Map(profile.fields.map((f) => [f.key, f]));
  const reports: FillReport[] = [];
  const work: Work[] = [];
  const verify: { field: Field; expected: FieldValue | null; report: FillReport }[] = [];

  for (const r of cmd.results) {
    if (r.status !== "filled" || r.value === undefined || r.value === null) continue;
    const field = byKey.get(r.key);
    const report: FillReport = { key: r.key, intended: r.value, read_back: null, outcome: "not_found", prior_value: null };
    if (field?.write === "never") {
      // A page-computed field is never written; its value is an expectation (derived wins).
      if (!(r.key in derived)) {
        verify.push({ field, expected: r.value, report });
        reports.push(report);
      }
      continue;
    }
    reports.push(report);
    if (!field) continue;
    const value = field.kind === "checkbox_group" && !Array.isArray(r.value) ? [r.value] : r.value;
    report.intended = value;
    work.push({ field, value, report });
  }
  for (const [key, expected] of Object.entries(derived)) {
    const field = byKey.get(key);
    const report: FillReport = { key, intended: expected, read_back: null, outcome: "not_found", prior_value: null };
    reports.push(report);
    if (field) verify.push({ field, expected, report });
  }

  const watch = new NetWatch(sameOriginWindows());
  const marks = { any: false, sheet: false };
  let network: NetworkSummary;
  try {
    await forEachByStep(profile, work, async (w) => {
      const els = resolveField(w.field);
      if (!els.length) return; // stays not_found
      const prior = readValue(w.field, els);
      w.report.prior_value = prior;
      w.report.read_back = prior;
      // A value the page didn't load with, and that isn't ours, was typed by someone. Keep it.
      if (!overwrite.has(w.field.key) && !sameValue(prior, defaultValue(w.field, els)) && !sameValue(prior, w.value)) {
        w.report.outcome = "conflict_skipped";
        return;
      }
      const result = sameValue(prior, w.value) ? "written" : await write(w.field, els, w.value, naive.has(w.field.key));
      if (result !== "written") return; // no such option: not_found
      w.els = els;
      marks.any = true;
      if (mark(els, true)) marks.sheet = true;
    });

    await sleep(settle);

    for (const w of work) {
      if (!w.els) continue;
      w.report.read_back = readValue(w.field, w.els);
      w.report.outcome = sameValue(w.report.read_back, w.value) ? "ok" : "reverted";
      if (w.report.outcome === "reverted") mark(w.els, false);
    }
    for (const v of verify) {
      const els = resolveField(v.field);
      if (!els.length) continue;
      v.report.read_back = readValue(v.field, els);
      v.report.outcome = sameValue(v.report.read_back, v.expected ?? "") ? "computed_verified" : "computed_mismatch";
    }
  } finally {
    network = watch.stop();
  }
  const highlight = !marks.any ? "none" : marks.sheet ? "stylesheet" : "attribute_only";
  return { reports, network, identity: cmd.identity ? "verified" : "unchecked", highlight };
}

/** Keeps only key/status/value of each result, in place, before anything else runs. */
function stripEvidence(cmd: { results?: unknown }): void {
  if (!Array.isArray(cmd.results)) throw new Error("bad_command: results must be an array");
  for (const r of cmd.results as Record<string, unknown>[]) {
    for (const k of Object.keys(r)) if (k !== "key" && k !== "status" && k !== "value") delete r[k];
  }
}

function checkIdentity(identity: { selector: string; expected: string }): void {
  const canon = (s: string) => s.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
  const el = queryAll(document, identity.selector)[0];
  const want = canon(identity.expected ?? "");
  if (!el || !want || !containsToken(canon(el.textContent ?? ""), want)) throw new Error("identity_mismatch");
}

/**
 * `want` appears in `text` as a whole token: not glued to a letter or digit either side, so
 * record "AB-11432" doesn't match a banner showing "AB-114322".
 */
export function containsToken(text: string, want: string): boolean {
  const word = /[\p{L}\p{N}]/u;
  for (let i = text.indexOf(want); i >= 0; i = text.indexOf(want, i + 1)) {
    const before = i > 0 ? text[i - 1] : "";
    const after = text[i + want.length] ?? "";
    if (!word.test(before) && !word.test(after)) return true;
  }
  return false;
}

// --------------------------------------------------------------------------------- focus

export interface FocusCommand {
  op: "focus";
  profile: FormProfile;
  key: string;
  identity?: { selector: string; expected: string };
}

/**
 * Shows one field to the worker (the review panel's "Show in form"): opens its step,
 * scrolls it to the middle of the view, and focuses it. Changes no value.
 */
export async function focusField(cmd: FocusCommand): Promise<{ focused: string }> {
  if (cmd.identity) checkIdentity(cmd.identity);
  const field = cmd.profile.fields.find((f) => f.key === cmd.key);
  if (!field) throw new Error(`not_found: ${cmd.key}`);
  const step = cmd.profile.steps.find((s) => s.id === field.step);
  if (step) await activate(step);
  const el = resolveField(field)[0];
  if (!el) throw new Error(`not_found: ${cmd.key}`);
  // A field inside an iframe: bring the frame into view first.
  const frame = el.ownerDocument.defaultView?.frameElement;
  frame?.scrollIntoView({ block: "center" });
  el.scrollIntoView({ block: "center" });
  (el as HTMLElement).focus?.({ preventScroll: true });
  return { focused: cmd.key };
}

// ---------------------------------------------------------------------------------- undo

export async function undo(cmd: UndoCommand): Promise<{ results: UndoResult[] }> {
  if (cmd.identity) checkIdentity(cmd.identity);
  const byKey = new Map(cmd.profile.fields.map((f) => [f.key, f]));
  const results: UndoResult[] = [];
  const work: (Work & { result: UndoResult })[] = [];
  for (const r of cmd.reports) {
    // Only fields we wrote. A reverted field is already back, and restoring is a no-op.
    if (r.outcome !== "ok" && r.outcome !== "reverted") continue;
    const result: UndoResult = { key: r.key, outcome: "not_found", read_back: null };
    results.push(result);
    const field = byKey.get(r.key);
    if (!field || r.prior_value === null) continue;
    work.push({ field, value: r.prior_value, report: r, result });
  }

  await forEachByStep(cmd.profile, work, async (w) => {
    const els = resolveField(w.field);
    if (!els.length) return;
    mark(els, false);
    const now = readValue(w.field, els);
    if (sameValue(now, w.value)) {
      w.els = els;
      return;
    }
    // Only undo our own write: if the field has moved on since, leave it (and say so).
    if (!sameValue(now, w.report.read_back ?? "")) {
      w.result.outcome = "changed_since";
      w.result.read_back = now;
      return;
    }
    w.els = els;
    if ((await write(w.field, els, w.value, false)) === "unsupported") w.result.outcome = "unrestorable";
  });

  await sleep(Math.max(0, cmd.settle_ms ?? DEFAULT_SETTLE_MS));
  for (const w of work) {
    if (!w.els) continue;
    w.result.read_back = readValue(w.field, w.els);
    if (w.result.outcome !== "unrestorable") w.result.outcome = sameValue(w.result.read_back, w.value) ? "restored" : "failed";
  }
  return { results };
}

// --------------------------------------------------------------------------- read_values

/** Every field's current value (null when it can't be found). Host-side use only. */
export function readValues(profile: FormProfile): Record<string, FieldValue | null> {
  const out: Record<string, FieldValue | null> = {};
  for (const f of profile.fields) {
    const els = resolveField(f);
    out[f.key] = els.length ? readValue(f, els) : null;
  }
  return out;
}

// --------------------------------------------------------------------------------- steps

/**
 * Runs fn for each item, activating each item's step first (in profile order), then returns
 * to the first step. Items on a step the profile doesn't list run first, without activation.
 */
async function forEachByStep<T extends { field: Field }>(profile: FormProfile, items: T[], fn: (item: T) => Promise<void>): Promise<void> {
  const known = new Set(profile.steps.map((s) => s.id));
  for (const item of items) if (!known.has(item.field.step)) await fn(item);
  let activated = false;
  for (const step of profile.steps) {
    const mine = items.filter((i) => i.field.step === step.id);
    if (!mine.length) continue;
    activated = (await activate(step)) || activated;
    for (const item of mine) await fn(item);
  }
  if (activated && profile.steps[0]) await activate(profile.steps[0]);
}

async function activate(step: Step): Promise<boolean> {
  if (!step.activate.click.length) return false;
  for (const sel of step.activate.click) {
    const el = queryAll(document, sel)[0];
    if (!el) continue;
    try {
      guardedClick(el);
    } catch (e) {
      // A step control that looks like a submit is never clicked; its fields are still
      // written in place (hidden panels accept writes) and read back like any other.
      if (!(e instanceof SubmitGuardError)) throw e;
    }
  }
  await sleep(STEP_SETTLE_MS);
  return true;
}

// -------------------------------------------------------------------------------- writes

async function write(f: Field, els: Element[], value: FieldValue, naive: boolean): Promise<WriteResult> {
  const el = els[0]!;
  switch (f.write) {
    case "native_setter":
      if (Array.isArray(value)) return "no_target";
      if (naive) {
        (el as HTMLInputElement).value = value;
        fire(el, "input");
      } else {
        (el as HTMLElement).focus();
        setValue(el, value);
        fire(el, "input");
        fire(el, "change");
        (el as HTMLElement).blur();
      }
      return "written";
    case "select":
      if (Array.isArray(value) || ![...(el as HTMLSelectElement).options].some((o) => o.value === value)) return "no_target";
      setValue(el, value);
      fire(el, "input");
      fire(el, "change");
      return "written";
    case "click_toggle":
      return f.kind === "radio_group" ? writeRadio(els, value) : writeCheckboxes(els, value);
    case "combobox_click":
      return Array.isArray(value) ? "no_target" : pickComboOption(el, value);
    default:
      return "unsupported";
  }
}

/** Clicks the intended radio only if it isn't already checked (React-safe, idempotent). */
function writeRadio(els: Element[], value: FieldValue): WriteResult {
  if (Array.isArray(value)) return "no_target";
  const inputs = els as HTMLInputElement[];
  if (value === "") {
    // Only undo asks for this: no click can uncheck a radio, so use the checked setter.
    const checked = inputs.find((i) => i.checked);
    if (checked) {
      Object.getOwnPropertyDescriptor(view(checked).HTMLInputElement.prototype, "checked")!.set!.call(checked, false);
      fire(checked, "input");
      fire(checked, "change");
    }
    return "written";
  }
  const target = inputs.find((i) => i.value === value);
  if (!target) return "no_target";
  if (!target.checked) guardedClick(target);
  return "written";
}

/** Makes the checked set equal the intended set, clicking only the boxes that differ. */
function writeCheckboxes(els: Element[], value: FieldValue): WriteResult {
  const want = new Set(Array.isArray(value) ? value : [value]);
  const inputs = els as HTMLInputElement[];
  if ([...want].some((v) => !inputs.some((i) => i.value === v))) return "no_target";
  for (const input of inputs) if (input.checked !== want.has(input.value)) guardedClick(input);
  return "written";
}

/** Click trigger → wait for the listbox → click the option → wait for the trigger to reflect it. */
async function pickComboOption(trigger: Element, value: string): Promise<WriteResult> {
  if (value === "") return "unsupported"; // a listbox has no "nothing" option to click
  const listbox = trigger.ownerDocument.getElementById(idList(trigger, "aria-controls")[0] ?? "");
  if (!listbox) return "no_target";
  const option = [...listbox.querySelectorAll("[role=option]")].find(
    (o) => (o.getAttribute("data-value") ?? norm(o.textContent ?? "")) === value,
  );
  if (!option) return "no_target";
  if (!visible(listbox)) guardedClick(trigger);
  // If it never opens, we return "written" and read-back reports the field as reverted.
  if (!(await until(() => visible(listbox), COMBO_OPEN_TIMEOUT_MS))) return "written";
  guardedClick(option);
  await until(() => comboValue(trigger) === value, 500);
  return "written";
}

function setValue(el: Element, value: string): void {
  const w = view(el);
  const t = tag(el);
  const proto = t === "textarea" ? w.HTMLTextAreaElement.prototype : t === "select" ? w.HTMLSelectElement.prototype : w.HTMLInputElement.prototype;
  // The prototype setter bypasses instance-level overrides (React's value tracker).
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(el, value);
}

function fire(el: Element, type: string): void {
  el.dispatchEvent(new (view(el).Event)(type, { bubbles: true }));
}

function visible(el: Element): boolean {
  return !(el as HTMLElement).hidden && el.getClientRects().length > 0;
}

async function until(cond: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) return false;
    await sleep(20);
  }
  return true;
}

// ----------------------------------------------------------------------------- highlight

const HIGHLIGHT_CSS = '[data-scribeski="filled"]{outline:2px solid #1a73e8 !important;outline-offset:1px !important}';
const styled = new WeakMap<Document, boolean>();

/** Sets or clears data-scribeski="filled". Returns whether the highlight stylesheet is in place. */
function mark(els: Element[], on: boolean): boolean {
  for (const el of els) {
    if (on) el.setAttribute("data-scribeski", "filled");
    else el.removeAttribute("data-scribeski");
  }
  return on ? ensureStylesheet(els[0]!.ownerDocument) : false;
}

/**
 * Adopts a constructable stylesheet: no <style> element, so nothing a style-src CSP would
 * block. It must be constructed in the document's own realm, hence the frame's constructor.
 */
function ensureStylesheet(doc: Document): boolean {
  const known = styled.get(doc);
  if (known !== undefined) return known;
  let ok = false;
  try {
    const w = doc.defaultView as Window & typeof globalThis;
    const sheet = new w.CSSStyleSheet();
    sheet.replaceSync(HIGHLIGHT_CSS);
    doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
    ok = true;
  } catch {
    /* attribute only */
  }
  styled.set(doc, ok);
  return ok;
}
