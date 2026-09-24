// Profiler (P1.2): walks the document and same-origin iframes and emits a FormProfile.
// Structure only. Never reads a control's value or checked state, or any page text not
// attached to a control (headers, banners, headings, footers).
import {
  CONTROLS,
  SKIPPED_INPUT_TYPES,
  cssAttr,
  cssId,
  idList,
  idrefText,
  inputType,
  norm,
  ownText,
  queryAll,
  rememberComboDefaults,
  tag,
  xpathLiteral,
  xpathOf,
} from "./dom";
import { sha256Hex } from "./sha256";
import type { Field, FormProfile, Kind, LabelSource, Option, Step, WriteStrategy } from "./types";

interface Label {
  text: string;
  source: LabelSource;
}

/** A field before key assignment: one control, or one radio/checkbox group. */
interface Item {
  els: Element[];
  kind: Kind;
  step: string;
  frame: string[];
}

const WRITE: Record<Kind, WriteStrategy> = {
  text: "native_setter",
  textarea: "native_setter",
  date: "native_setter",
  select: "select",
  radio_group: "click_toggle",
  checkbox_group: "click_toggle",
  combobox: "combobox_click",
  hidden: "never",
};

export function profile(): FormProfile {
  rememberComboDefaults();
  const { steps, stepOf } = collectSteps(document);
  const items: Item[] = [];
  const unreachable: FormProfile["unreachable"] = [];
  walk(document, [], stepOf, items, unreachable);

  if (items.some((i) => i.step === "step-main")) steps.push({ id: "step-main", activate: { click: [] } });

  const used = new Set<string>();
  const fields = items.map((item) => toField(item, used));
  return {
    schema: "scribeski.form-profile/1",
    origin: location.origin,
    path_pattern: location.pathname,
    fingerprint: fingerprint(fields),
    steps,
    fields,
    unreachable,
  };
}

/**
 * Ids that frameworks generate per render: React `:r3:`, MUI `mui-12345`, Angular Material
 * `mat-input-7`, Ember `ember123`, Ext `ext-gen42`, react-select, Headless UI, Radix, UUIDs,
 * long hex or digit runs. A false positive only costs a less readable key.
 */
export function isGeneratedId(id: string): boolean {
  return /^:r[0-9a-z]+:$/i.test(id)
    || /^(mui|ember|ext-gen|react-select|headlessui|radix|downshift|rc_select|cdk|mat-[a-z-]+|p-[a-z]+)[-_:]?\w*\d+/i.test(id)
    || /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/i.test(id)
    || /[0-9a-f]{12,}/i.test(id)
    || /\d{5,}/.test(id);
}

export function fingerprint(fields: Field[]): string {
  const canonical = fields
    .map((f) => [f.key, f.kind, f.options.map((o) => o.value)] as const)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return "sha256:" + sha256Hex(JSON.stringify(canonical));
}

// -------------------------------------------------------------------------------- steps

/** Steps from role=tablist/role=tab → aria-controls → tabpanel, in tab order (top document). */
function collectSteps(doc: Document): { steps: Step[]; stepOf: (el: Element) => string } {
  const steps: Step[] = [];
  const panels: { panel: Element; id: string }[] = [];
  for (const tab of doc.querySelectorAll("[role=tablist] [role=tab][aria-controls]")) {
    const panel = doc.getElementById(idList(tab, "aria-controls")[0] ?? "");
    if (!panel) continue;
    const id = `step-${panel.id.replace(/^panel-/, "")}`;
    steps.push({ id, activate: { click: [tab.id ? cssId(tab.id) : `xpath=${xpathOf(tab)}`] } });
    panels.push({ panel, id });
  }
  const stepOf = (el: Element): string => {
    const inside = panels.find((p) => p.panel.contains(el));
    if (inside) return inside.id;
    // Outside every panel: the nearest preceding panel, else the first step.
    const before = panels.filter((p) => p.panel.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING);
    return before.pop()?.id ?? panels[0]?.id ?? "step-main";
  };
  return { steps, stepOf };
}

// --------------------------------------------------------------------------------- walk

function walk(
  doc: Document,
  frame: string[],
  stepOf: (el: Element) => string,
  items: Item[],
  unreachable: FormProfile["unreachable"],
): void {
  const groups = new Map<string, Item>();
  for (const el of doc.querySelectorAll(`${CONTROLS}, iframe`)) {
    if (tag(el) === "iframe") {
      const step = stepOf(el);
      let child: Document | null = null;
      try {
        child = (el as HTMLIFrameElement).contentDocument;
      } catch {
        /* cross-origin */
      }
      if (child) walk(child, [...frame, frameSelector(el)], () => step, items, unreachable);
      else unreachable.push({ frame: safeUrl((el as HTMLIFrameElement).src), reason: "cross-origin" });
      continue;
    }
    const kind = kindOf(el);
    if (!kind) continue;
    if (kind === "radio_group" || kind === "checkbox_group") {
      const name = el.getAttribute("name");
      const groupKey = name ? `${kind}:${name}` : null;
      const existing = groupKey ? groups.get(groupKey) : undefined;
      if (existing) {
        existing.els.push(el);
        continue;
      }
      const item: Item = { els: [el], kind, step: stepOf(el), frame };
      if (groupKey) groups.set(groupKey, item);
      items.push(item);
    } else {
      items.push({ els: [el], kind, step: stepOf(el), frame });
    }
  }
}

function kindOf(el: Element): Kind | null {
  const t = tag(el);
  if (el.getAttribute("role") === "combobox") {
    if (el.ownerDocument.getElementById(idList(el, "aria-controls")[0] ?? "")) return "combobox";
    if (t !== "input") return null;
  }
  // An input inside an ARIA combobox widget is part of that widget, not its own field.
  if (t === "input" && el.parentElement?.closest("[role=combobox]")) return null;
  if (t === "select") return "select";
  if (t === "textarea") return "textarea";
  if (t !== "input") return null;
  const type = inputType(el);
  if (SKIPPED_INPUT_TYPES.has(type)) return null;
  if (type === "hidden") return "hidden";
  if (type === "radio") return "radio_group";
  if (type === "checkbox") return "checkbox_group";
  if (type === "date") return "date";
  return "text";
}

function frameSelector(iframe: Element): string {
  if (iframe.id) return cssId(iframe.id);
  const name = iframe.getAttribute("name");
  if (name && iframe.ownerDocument.querySelectorAll(cssAttr("name", name)).length === 1) return cssAttr("name", name);
  return `xpath=${xpathOf(iframe)}`;
}

/** Origin + path only: a frame URL's query string may carry record identifiers. */
function safeUrl(src: string): string {
  try {
    const u = new URL(src);
    return u.origin + u.pathname;
  } catch {
    return "";
  }
}

// ------------------------------------------------------------------------------ fields

function toField(item: Item, used: Set<string>): Field {
  const { els, kind, step, frame } = item;
  const el = els[0]!;
  const group = kind === "radio_group" || kind === "checkbox_group";
  const label = kind === "hidden" ? null : group ? groupLabel(els) : labelOf(el);
  const labelText = label?.text ?? "";

  // Framework-generated ids and names change between page loads, so they'd make the same
  // form look new every visit. Skip them for the next stable source.
  const stable = (v: string | null): string | null => (v && !isGeneratedId(v) ? v : null);
  const name = stable(el.getAttribute("name"));
  const testid = stable(el.getAttribute("data-testid"));
  let key = (group ? name : stable(el.id) || name) || testid || `f_${sha256Hex(`${labelText}|${kind}|${step}`).slice(0, 10)}`;
  if (used.has(key)) {
    let n = 2;
    while (used.has(`${key}_${n}`)) n++;
    key = `${key}_${n}`;
  }
  used.add(key);

  const help = idrefText(el.ownerDocument, idList(el, "aria-describedby"));
  // Key order follows the contract; absent optionals are omitted (Swift decodes them as nil).
  return {
    key,
    step,
    frame,
    kind,
    label: labelText,
    ...(label ? { label_source: label.source } : {}),
    ...(help ? { help } : {}),
    required: els.some((e) => (e as HTMLInputElement).required || e.getAttribute("aria-required") === "true"),
    options: optionsOf(kind, els),
    selectors: group ? groupSelectors(els) : selectors(el),
    write: WRITE[kind],
    computed: kind === "hidden",
  };
}

/** label[for] → wrapping label → aria-labelledby → aria-label → placeholder → preceding text. */
function labelOf(el: Element): Label | null {
  const doc = el.ownerDocument;
  const found = (text: string, source: LabelSource): Label | null => (text ? { text, source } : null);
  if (el.id) {
    const forLabel = [...doc.querySelectorAll("label")].find((l) => l.htmlFor === el.id);
    const r = forLabel && found(ownText(forLabel), "label_for");
    if (r) return r;
  }
  const wrap = el.closest("label");
  return (
    (wrap && found(ownText(wrap), "label_wrap")) ||
    found(idrefText(doc, idList(el, "aria-labelledby")), "aria_labelledby") ||
    found(norm(el.getAttribute("aria-label") ?? ""), "aria_label") ||
    found(norm(el.getAttribute("placeholder") ?? ""), "placeholder") ||
    found(precedingText(el), "preceding_text")
  );
}

/** The nearest non-empty text before the control inside its fieldset, if it has one. */
function precedingText(el: Element): string {
  const fieldset = el.closest("fieldset");
  if (!fieldset) return "";
  const walker = el.ownerDocument.createTreeWalker(fieldset, 4 /* SHOW_TEXT */);
  let last = "";
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (!(el.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_PRECEDING)) break;
    const p = n.parentElement;
    if (p && p !== fieldset && p.closest("select, textarea, option, button, [role=listbox], [role=combobox], script, style")) continue;
    const t = norm(n.nodeValue ?? "");
    if (t) last = t;
  }
  return last;
}

/** A group's question: its legend, else the first aria-labelledby id (row question), else a label. */
function groupLabel(els: Element[]): Label | null {
  const first = els[0]!;
  const fieldset = first.closest("fieldset");
  const legend = fieldset?.querySelector(":scope > legend");
  if (legend && els.every((e) => fieldset!.contains(e))) {
    const text = ownText(legend);
    if (text) return { text, source: "legend" };
  }
  const ids = idList(first, "aria-labelledby");
  if (ids.length) {
    const text = idrefText(first.ownerDocument, ids.slice(0, 1));
    if (text) return { text, source: "aria_labelledby" };
  }
  return labelOf(first);
}

function optionsOf(kind: Kind, els: Element[]): Option[] {
  const el = els[0]!;
  if (kind === "select") {
    return [...(el as HTMLSelectElement).options]
      .filter((o) => o.getAttribute("value") !== "" && !(o.getAttribute("value") === null && norm(o.text) === ""))
      .map((o) => ({ value: o.value, label: norm(o.text) }));
  }
  if (kind === "combobox") {
    const listbox = el.ownerDocument.getElementById(idList(el, "aria-controls")[0] ?? "");
    return [...(listbox?.querySelectorAll("[role=option]") ?? [])].map((o) => {
      const text = norm(o.textContent ?? "");
      return { value: o.getAttribute("data-value") ?? text, label: text };
    });
  }
  if (kind === "radio_group" || kind === "checkbox_group") {
    return els.map((e) => ({ value: (e as HTMLInputElement).value, label: optionLabel(e) }));
  }
  return [];
}

/** An option's own label: the remaining aria-labelledby ids (column header), else its label. */
function optionLabel(input: Element): string {
  const ids = idList(input, "aria-labelledby");
  if (ids.length > 1) {
    const text = idrefText(input.ownerDocument, ids.slice(1));
    if (text) return text;
  }
  const doc = input.ownerDocument;
  const forLabel = input.id ? [...doc.querySelectorAll("label")].find((l) => l.htmlFor === input.id) : undefined;
  const wrap = input.closest("label");
  return (forLabel && ownText(forLabel)) || (wrap && ownText(wrap)) || norm(input.getAttribute("aria-label") ?? "") || (input as HTMLInputElement).value;
}

/** #id, [name], [data-testid] where each resolves uniquely to el, then a structural XPath. */
function selectors(el: Element): string[] {
  const doc = el.ownerDocument;
  const out: string[] = [];
  const unique = (sel: string) => {
    const all = queryAll(doc, sel);
    if (all.length === 1 && all[0] === el) out.push(sel);
  };
  if (el.id) unique(cssId(el.id));
  const name = el.getAttribute("name");
  if (name) unique(cssAttr("name", name));
  const testid = el.getAttribute("data-testid");
  if (testid) unique(cssAttr("data-testid", testid));
  out.push(`xpath=${xpathOf(el)}`);
  return out;
}

/** [name], then an XPath from the group's common ancestor. Both resolve to all the inputs. */
function groupSelectors(els: Element[]): string[] {
  const first = els[0]!;
  const name = first.getAttribute("name");
  if (!name) return [`xpath=${xpathOf(first)}`];
  let ancestor: Element = first.parentElement ?? first;
  while (!els.every((e) => ancestor.contains(e)) && ancestor.parentElement) ancestor = ancestor.parentElement;
  return [cssAttr("name", name), `xpath=${xpathOf(ancestor)}//input[@name=${xpathLiteral(name)}]`];
}
