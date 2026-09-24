// DOM helpers shared by the profiler and the filler: text, selectors, frames, and reading a
// field's current and default value. Elements may live in iframes, i.e. other JS realms, so
// nothing here uses instanceof against top-window constructors.
import type { Field, FieldValue } from "./types";

export const CONTROLS = "input, select, textarea, [role=combobox]";

/** Input types that are never fields (buttons, files, credentials). */
export const SKIPPED_INPUT_TYPES = new Set(["submit", "button", "reset", "image", "file", "password"]);

// Text inside these belongs to a control (its value, options, or popup), never to a label.
const NOT_LABEL_TEXT = "select, textarea, option, button, [role=combobox], [role=listbox], script, style";

export function norm(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

/** Text of a label-like element, minus any text that belongs to a control nested in it. */
export function ownText(root: Element): string {
  const walker = root.ownerDocument.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */);
  let out = "";
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (!insideControl(n.parentElement, root)) out += n.nodeValue ?? "";
  }
  return norm(out);
}

function insideControl(el: Element | null, stop: Element): boolean {
  for (let e = el; e && e !== stop; e = e.parentElement) if (e.matches(NOT_LABEL_TEXT)) return true;
  return false;
}

/** Joined text of the elements referenced by an id-list attribute (aria-labelledby etc.). */
export function idrefText(doc: Document, ids: string[]): string {
  return norm(ids.map((id) => doc.getElementById(id)).filter((e) => e).map((e) => ownText(e!)).join(" "));
}

export function idList(el: Element, attr: string): string[] {
  return (el.getAttribute(attr) ?? "").split(/\s+/).filter(Boolean);
}

export function tag(el: Element): string {
  return el.tagName.toLowerCase();
}

export function inputType(el: Element): string {
  return tag(el) === "input" ? (el as HTMLInputElement).type.toLowerCase() : "";
}

export function view(el: Element): Window & typeof globalThis {
  return el.ownerDocument.defaultView as Window & typeof globalThis;
}

// ---------------------------------------------------------------------------- selectors

export function cssId(id: string): string {
  return `#${CSS.escape(id)}`;
}

export function cssAttr(attr: string, value: string): string {
  return `[${attr}="${value.replace(/["\\]/g, "\\$&")}"]`;
}

export function xpathLiteral(s: string): string {
  if (!s.includes("'")) return `'${s}'`;
  if (!s.includes('"')) return `"${s}"`;
  return `concat('${s.split("'").join(`', "'", '`)}')`;
}

/** Structural XPath from the document root, e.g. /html/body/main/form/section[2]/table/... */
export function xpathOf(el: Element): string {
  const parts: string[] = [];
  for (let n: Element | null = el; n; n = n.parentElement) {
    const name = n.localName;
    let index = 0;
    let count = 0;
    for (const s of n.parentElement?.children ?? []) {
      if (s.localName === name) {
        count++;
        if (s === n) index = count;
      }
    }
    parts.unshift(count > 1 ? `${name}[${index}]` : name);
  }
  return "/" + parts.join("/");
}

/** All elements matched by a CSS selector, or by an `xpath=` selector. Never throws. */
export function queryAll(doc: Document, selector: string): Element[] {
  try {
    if (selector.startsWith("xpath=")) {
      const r = doc.evaluate(selector.slice(6), doc, null, 7 /* ORDERED_NODE_SNAPSHOT_TYPE */, null);
      const out: Element[] = [];
      for (let i = 0; i < r.snapshotLength; i++) {
        const n = r.snapshotItem(i);
        if (n && n.nodeType === 1) out.push(n as Element);
      }
      return out;
    }
    return [...doc.querySelectorAll(selector)];
  } catch {
    return [];
  }
}

/** Follows a frame path (iframe selectors from the top document). Null if unreachable. */
export function frameDocument(path: string[], top: Document = document): Document | null {
  let doc: Document | null = top;
  for (const sel of path) {
    const frame = queryAll(doc, sel)[0] as HTMLIFrameElement | undefined;
    if (!frame || tag(frame) !== "iframe") return null;
    try {
      doc = frame.contentDocument;
    } catch {
      return null;
    }
    if (!doc) return null;
  }
  return doc;
}

export function isGroup(f: Field): boolean {
  return f.kind === "radio_group" || f.kind === "checkbox_group";
}

/**
 * The field's element(s) via the first selector that resolves: all the group's inputs for
 * radio/checkbox groups, else one element. Empty when nothing resolves.
 */
export function resolveField(f: Field, top: Document = document): Element[] {
  const doc = frameDocument(f.frame, top);
  if (!doc) return [];
  const type = f.kind === "radio_group" ? "radio" : "checkbox";
  for (const sel of f.selectors) {
    const found = queryAll(doc, sel);
    if (isGroup(f)) {
      const inputs = found.filter((e) => inputType(e) === type);
      if (inputs.length) return inputs;
    } else if (found[0]) {
      return [found[0]];
    }
  }
  return [];
}

// ------------------------------------------------------------------------------- values

// Value of each combobox when the bundle first saw its document, standing in for the
// defaultValue a native control carries.
const comboDefaults = new WeakMap<Element, string>();

/** Records combobox defaults for a document and its same-origin frames (first sighting wins). */
export function rememberComboDefaults(doc: Document = document): void {
  for (const el of doc.querySelectorAll("[role=combobox]")) {
    if (!comboDefaults.has(el)) comboDefaults.set(el, comboValue(el));
  }
  for (const frame of doc.querySelectorAll("iframe")) {
    let child: Document | null = null;
    try {
      child = (frame as HTMLIFrameElement).contentDocument;
    } catch {
      /* cross-origin */
    }
    if (child) rememberComboDefaults(child);
  }
}

export function comboValue(el: Element): string {
  if (tag(el) === "input") return (el as HTMLInputElement).value;
  const dv = el.getAttribute("data-value");
  if (dv !== null) return dv;
  const listbox = el.ownerDocument.getElementById(idList(el, "aria-controls")[0] ?? "");
  const selected = listbox?.querySelector('[role=option][aria-selected="true"]');
  return selected?.getAttribute("data-value") ?? "";
}

/** The field's current value. Only the filler and the host-only read_values op call this. */
export function readValue(f: Field, els: Element[]): FieldValue {
  const el = els[0]!;
  switch (f.kind) {
    case "radio_group":
      return (els.find((e) => (e as HTMLInputElement).checked) as HTMLInputElement | undefined)?.value ?? "";
    case "checkbox_group":
      return els.filter((e) => (e as HTMLInputElement).checked).map((e) => (e as HTMLInputElement).value);
    case "combobox":
      return comboValue(el);
    default:
      return (el as HTMLInputElement).value;
  }
}

/** What the control held when the page loaded (defaultValue / defaultSelected / defaultChecked). */
export function defaultValue(f: Field, els: Element[]): FieldValue {
  const el = els[0]!;
  switch (f.kind) {
    case "radio_group":
      return (els.find((e) => (e as HTMLInputElement).defaultChecked) as HTMLInputElement | undefined)?.value ?? "";
    case "checkbox_group":
      return els.filter((e) => (e as HTMLInputElement).defaultChecked).map((e) => (e as HTMLInputElement).value);
    case "combobox":
      return comboDefaults.get(el) ?? "";
    case "select": {
      // What a form reset would show: the last defaultSelected option, else the first enabled one.
      const opts = [...(el as HTMLSelectElement).options];
      const chosen = opts.filter((o) => o.defaultSelected).pop() ?? opts.find((o) => !o.disabled);
      return chosen?.value ?? "";
    }
    default:
      return (el as HTMLInputElement).defaultValue;
  }
}

export function sameValue(a: FieldValue | null, b: FieldValue | null): boolean {
  if (Array.isArray(a) && Array.isArray(b)) {
    const sa = [...a].sort();
    const sb = [...b].sort();
    return sa.length === sb.length && sa.every((v, i) => v === sb[i]);
  }
  return a === b;
}

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
