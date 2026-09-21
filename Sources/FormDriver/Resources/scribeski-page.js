/* scribeski-page 0.0.1 */
"use strict";
(() => {
  // src/dom.ts
  var CONTROLS = "input, select, textarea, [role=combobox]";
  var SKIPPED_INPUT_TYPES = /* @__PURE__ */ new Set(["submit", "button", "reset", "image", "file", "password"]);
  var NOT_LABEL_TEXT = "select, textarea, option, button, [role=combobox], [role=listbox], script, style";
  function norm(s) {
    return s.replace(/\s+/g, " ").trim();
  }
  function ownText(root) {
    const walker = root.ownerDocument.createTreeWalker(
      root,
      4
      /* NodeFilter.SHOW_TEXT */
    );
    let out = "";
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!insideControl(n.parentElement, root)) out += n.nodeValue ?? "";
    }
    return norm(out);
  }
  function insideControl(el, stop) {
    for (let e = el; e && e !== stop; e = e.parentElement) if (e.matches(NOT_LABEL_TEXT)) return true;
    return false;
  }
  function idrefText(doc, ids) {
    return norm(ids.map((id) => doc.getElementById(id)).filter((e) => e).map((e) => ownText(e)).join(" "));
  }
  function idList(el, attr) {
    return (el.getAttribute(attr) ?? "").split(/\s+/).filter(Boolean);
  }
  function tag(el) {
    return el.tagName.toLowerCase();
  }
  function inputType(el) {
    return tag(el) === "input" ? el.type.toLowerCase() : "";
  }
  function view(el) {
    return el.ownerDocument.defaultView;
  }
  function cssId(id) {
    return `#${CSS.escape(id)}`;
  }
  function cssAttr(attr, value) {
    return `[${attr}="${value.replace(/["\\]/g, "\\$&")}"]`;
  }
  function xpathLiteral(s) {
    if (!s.includes("'")) return `'${s}'`;
    if (!s.includes('"')) return `"${s}"`;
    return `concat('${s.split("'").join(`', "'", '`)}')`;
  }
  function xpathOf(el) {
    const parts = [];
    for (let n = el; n; n = n.parentElement) {
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
  function queryAll(doc, selector) {
    try {
      if (selector.startsWith("xpath=")) {
        const r = doc.evaluate(selector.slice(6), doc, null, 7, null);
        const out = [];
        for (let i = 0; i < r.snapshotLength; i++) {
          const n = r.snapshotItem(i);
          if (n && n.nodeType === 1) out.push(n);
        }
        return out;
      }
      return [...doc.querySelectorAll(selector)];
    } catch {
      return [];
    }
  }
  function frameDocument(path, top = document) {
    let doc = top;
    for (const sel of path) {
      const frame = queryAll(doc, sel)[0];
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
  function isGroup(f) {
    return f.kind === "radio_group" || f.kind === "checkbox_group";
  }
  function resolveField(f, top = document) {
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
  var comboDefaults = /* @__PURE__ */ new WeakMap();
  function rememberComboDefaults(doc = document) {
    for (const el of doc.querySelectorAll("[role=combobox]")) {
      if (!comboDefaults.has(el)) comboDefaults.set(el, comboValue(el));
    }
    for (const frame of doc.querySelectorAll("iframe")) {
      let child = null;
      try {
        child = frame.contentDocument;
      } catch {
      }
      if (child) rememberComboDefaults(child);
    }
  }
  function comboValue(el) {
    if (tag(el) === "input") return el.value;
    const dv = el.getAttribute("data-value");
    if (dv !== null) return dv;
    const listbox = el.ownerDocument.getElementById(idList(el, "aria-controls")[0] ?? "");
    const selected = listbox?.querySelector('[role=option][aria-selected="true"]');
    return selected?.getAttribute("data-value") ?? "";
  }
  function readValue(f, els) {
    const el = els[0];
    switch (f.kind) {
      case "radio_group":
        return els.find((e) => e.checked)?.value ?? "";
      case "checkbox_group":
        return els.filter((e) => e.checked).map((e) => e.value);
      case "combobox":
        return comboValue(el);
      default:
        return el.value;
    }
  }
  function defaultValue(f, els) {
    const el = els[0];
    switch (f.kind) {
      case "radio_group":
        return els.find((e) => e.defaultChecked)?.value ?? "";
      case "checkbox_group":
        return els.filter((e) => e.defaultChecked).map((e) => e.value);
      case "combobox":
        return comboDefaults.get(el) ?? "";
      case "select": {
        const opts = [...el.options];
        const chosen = opts.filter((o) => o.defaultSelected).pop() ?? opts.find((o) => !o.disabled);
        return chosen?.value ?? "";
      }
      default:
        return el.defaultValue;
    }
  }
  function sameValue(a, b) {
    if (Array.isArray(a) && Array.isArray(b)) {
      const sa = [...a].sort();
      const sb = [...b].sort();
      return sa.length === sb.length && sa.every((v, i) => v === sb[i]);
    }
    return a === b;
  }
  var sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // src/sha256.ts
  var K = new Uint32Array([
    1116352408,
    1899447441,
    3049323471,
    3921009573,
    961987163,
    1508970993,
    2453635748,
    2870763221,
    3624381080,
    310598401,
    607225278,
    1426881987,
    1925078388,
    2162078206,
    2614888103,
    3248222580,
    3835390401,
    4022224774,
    264347078,
    604807628,
    770255983,
    1249150122,
    1555081692,
    1996064986,
    2554220882,
    2821834349,
    2952996808,
    3210313671,
    3336571891,
    3584528711,
    113926993,
    338241895,
    666307205,
    773529912,
    1294757372,
    1396182291,
    1695183700,
    1986661051,
    2177026350,
    2456956037,
    2730485921,
    2820302411,
    3259730800,
    3345764771,
    3516065817,
    3600352804,
    4094571909,
    275423344,
    430227734,
    506948616,
    659060556,
    883997877,
    958139571,
    1322822218,
    1537002063,
    1747873779,
    1955562222,
    2024104815,
    2227730452,
    2361852424,
    2428436474,
    2756734187,
    3204031479,
    3329325298
  ]);
  function sha256(msg) {
    const blocks = Math.ceil((msg.length + 9) / 64);
    const buf = new Uint8Array(blocks * 64);
    buf.set(msg);
    buf[msg.length] = 128;
    const view2 = new DataView(buf.buffer);
    const bits = msg.length * 8;
    view2.setUint32(buf.length - 8, Math.floor(bits / 4294967296));
    view2.setUint32(buf.length - 4, bits >>> 0);
    const h = new Uint32Array([1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225]);
    const w = new Uint32Array(64);
    for (let off = 0; off < buf.length; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = view2.getUint32(off + i * 4);
      for (let i = 16; i < 64; i++) {
        const a2 = w[i - 15], b2 = w[i - 2];
        const s0 = rotr(a2, 7) ^ rotr(a2, 18) ^ a2 >>> 3;
        const s1 = rotr(b2, 17) ^ rotr(b2, 19) ^ b2 >>> 10;
        w[i] = w[i - 16] + s0 + w[i - 7] + s1 >>> 0;
      }
      let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
      for (let i = 0; i < 64; i++) {
        const t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + (e & f ^ ~e & g) + K[i] + w[i] >>> 0;
        const t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + (a & b ^ a & c ^ b & c) >>> 0;
        hh = g;
        g = f;
        f = e;
        e = d + t1 >>> 0;
        d = c;
        c = b;
        b = a;
        a = t1 + t2 >>> 0;
      }
      h[0] = h[0] + a;
      h[1] = h[1] + b;
      h[2] = h[2] + c;
      h[3] = h[3] + d;
      h[4] = h[4] + e;
      h[5] = h[5] + f;
      h[6] = h[6] + g;
      h[7] = h[7] + hh;
    }
    const out = new Uint8Array(32);
    const ov = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) ov.setUint32(i * 4, h[i]);
    return out;
  }
  function sha256Hex(s) {
    let hex = "";
    for (const byte of sha256(new TextEncoder().encode(s))) hex += byte.toString(16).padStart(2, "0");
    return hex;
  }
  function rotr(x, n) {
    return x >>> n | x << 32 - n;
  }

  // src/profile.ts
  var WRITE = {
    text: "native_setter",
    textarea: "native_setter",
    date: "native_setter",
    select: "select",
    radio_group: "click_toggle",
    checkbox_group: "click_toggle",
    combobox: "combobox_click",
    hidden: "never"
  };
  function profile() {
    rememberComboDefaults();
    const { steps, stepOf } = collectSteps(document);
    const items = [];
    const unreachable = [];
    walk(document, [], stepOf, items, unreachable);
    if (items.some((i) => i.step === "step-main")) steps.push({ id: "step-main", activate: { click: [] } });
    const used = /* @__PURE__ */ new Set();
    const fields = items.map((item) => toField(item, used));
    return {
      schema: "scribeski.form-profile/1",
      origin: location.origin,
      path_pattern: generalizePath(location.pathname),
      fingerprint: fingerprint(fields),
      steps,
      fields,
      unreachable
    };
  }
  function generalizePath(path) {
    return path.split("/").map((seg) => {
      let s = seg;
      try {
        s = decodeURIComponent(seg);
      } catch {
      }
      return /\d.*\d.*\d/.test(s) || /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(s) || /^[0-9a-f]{12,}$/i.test(s) ? "*" : seg;
    }).join("/");
  }
  function isGeneratedId(id) {
    return /^:r[0-9a-z]+:$/i.test(id) || /^(mui|ember|ext-gen|react-select|headlessui|radix|downshift|rc_select|cdk|mat-[a-z-]+|p-[a-z]+)[-_:]?\w*\d+/i.test(id) || /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/i.test(id) || /[0-9a-f]{12,}/i.test(id) || /\d{5,}/.test(id);
  }
  function fingerprint(fields) {
    const canonical = fields.map((f) => [f.key, f.kind, f.options.map((o) => o.value)]).sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
    return "sha256:" + sha256Hex(JSON.stringify(canonical));
  }
  function collectSteps(doc) {
    const steps = [];
    const panels = [];
    for (const tab of doc.querySelectorAll("[role=tablist] [role=tab][aria-controls]")) {
      const panel = doc.getElementById(idList(tab, "aria-controls")[0] ?? "");
      if (!panel) continue;
      const id = `step-${panel.id.replace(/^panel-/, "")}`;
      steps.push({ id, activate: { click: [tab.id ? cssId(tab.id) : `xpath=${xpathOf(tab)}`] } });
      panels.push({ panel, id });
    }
    const stepOf = (el) => {
      const inside = panels.find((p) => p.panel.contains(el));
      if (inside) return inside.id;
      const before = panels.filter((p) => p.panel.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING);
      return before.pop()?.id ?? panels[0]?.id ?? "step-main";
    };
    return { steps, stepOf };
  }
  function walk(doc, frame, stepOf, items, unreachable) {
    const groups = /* @__PURE__ */ new Map();
    for (const el of doc.querySelectorAll(`${CONTROLS}, iframe`)) {
      if (tag(el) === "iframe") {
        const step = stepOf(el);
        let child = null;
        try {
          child = el.contentDocument;
        } catch {
        }
        if (child) walk(child, [...frame, frameSelector(el)], () => step, items, unreachable);
        else unreachable.push({ frame: safeUrl(el.src), reason: "cross-origin" });
        continue;
      }
      const kind = kindOf(el);
      if (!kind) continue;
      if (kind === "radio_group" || kind === "checkbox_group") {
        const name = el.getAttribute("name");
        const groupKey = name ? `${kind}:${name}` : null;
        const existing2 = groupKey ? groups.get(groupKey) : void 0;
        if (existing2) {
          existing2.els.push(el);
          continue;
        }
        const item = { els: [el], kind, step: stepOf(el), frame };
        if (groupKey) groups.set(groupKey, item);
        items.push(item);
      } else {
        items.push({ els: [el], kind, step: stepOf(el), frame });
      }
    }
  }
  function kindOf(el) {
    const t = tag(el);
    if (el.getAttribute("role") === "combobox") {
      if (el.ownerDocument.getElementById(idList(el, "aria-controls")[0] ?? "")) return "combobox";
      if (t !== "input") return null;
    }
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
  function frameSelector(iframe) {
    if (iframe.id) return cssId(iframe.id);
    const name = iframe.getAttribute("name");
    if (name && iframe.ownerDocument.querySelectorAll(cssAttr("name", name)).length === 1) return cssAttr("name", name);
    return `xpath=${xpathOf(iframe)}`;
  }
  function safeUrl(src) {
    try {
      const u = new URL(src);
      return u.origin + u.pathname;
    } catch {
      return "";
    }
  }
  function toField(item, used) {
    const { els, kind, step, frame } = item;
    const el = els[0];
    const group = kind === "radio_group" || kind === "checkbox_group";
    const label = kind === "hidden" ? null : group ? groupLabel(els) : labelOf(el);
    const labelText = label?.text ?? "";
    const stable = (v) => v && !isGeneratedId(v) ? v : null;
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
    return {
      key,
      step,
      frame,
      kind,
      label: labelText,
      ...label ? { label_source: label.source } : {},
      ...help ? { help } : {},
      required: els.some((e) => e.required || e.getAttribute("aria-required") === "true"),
      options: optionsOf(kind, els),
      selectors: group ? groupSelectors(els) : selectors(el),
      write: WRITE[kind],
      computed: kind === "hidden"
    };
  }
  function labelOf(el) {
    const doc = el.ownerDocument;
    const found = (text, source) => text ? { text, source } : null;
    if (el.id) {
      const forLabel = [...doc.querySelectorAll("label")].find((l) => l.htmlFor === el.id);
      const r = forLabel && found(ownText(forLabel), "label_for");
      if (r) return r;
    }
    const wrap = el.closest("label");
    return wrap && found(ownText(wrap), "label_wrap") || found(idrefText(doc, idList(el, "aria-labelledby")), "aria_labelledby") || found(norm(el.getAttribute("aria-label") ?? ""), "aria_label") || found(norm(el.getAttribute("placeholder") ?? ""), "placeholder") || found(precedingText(el), "preceding_text");
  }
  function precedingText(el) {
    const fieldset = el.closest("fieldset");
    if (!fieldset) return "";
    const walker = el.ownerDocument.createTreeWalker(
      fieldset,
      4
      /* SHOW_TEXT */
    );
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
  function groupLabel(els) {
    const first = els[0];
    const fieldset = first.closest("fieldset");
    const legend = fieldset?.querySelector(":scope > legend");
    if (legend && els.every((e) => fieldset.contains(e))) {
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
  function optionsOf(kind, els) {
    const el = els[0];
    if (kind === "select") {
      return [...el.options].filter((o) => o.getAttribute("value") !== "" && !(o.getAttribute("value") === null && norm(o.text) === "")).map((o) => ({ value: o.value, label: norm(o.text) }));
    }
    if (kind === "combobox") {
      const listbox = el.ownerDocument.getElementById(idList(el, "aria-controls")[0] ?? "");
      return [...listbox?.querySelectorAll("[role=option]") ?? []].map((o) => {
        const text = norm(o.textContent ?? "");
        return { value: o.getAttribute("data-value") ?? text, label: text };
      });
    }
    if (kind === "radio_group" || kind === "checkbox_group") {
      return els.map((e) => ({ value: e.value, label: optionLabel(e) }));
    }
    return [];
  }
  function optionLabel(input) {
    const ids = idList(input, "aria-labelledby");
    if (ids.length > 1) {
      const text = idrefText(input.ownerDocument, ids.slice(1));
      if (text) return text;
    }
    const doc = input.ownerDocument;
    const forLabel = input.id ? [...doc.querySelectorAll("label")].find((l) => l.htmlFor === input.id) : void 0;
    const wrap = input.closest("label");
    return forLabel && ownText(forLabel) || wrap && ownText(wrap) || norm(input.getAttribute("aria-label") ?? "") || input.value;
  }
  function selectors(el) {
    const doc = el.ownerDocument;
    const out = [];
    const unique = (sel) => {
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
  function groupSelectors(els) {
    const first = els[0];
    const name = first.getAttribute("name");
    if (!name) return [`xpath=${xpathOf(first)}`];
    let ancestor = first.parentElement ?? first;
    while (!els.every((e) => ancestor.contains(e)) && ancestor.parentElement) ancestor = ancestor.parentElement;
    return [cssAttr("name", name), `xpath=${xpathOf(ancestor)}//input[@name=${xpathLiteral(name)}]`];
  }

  // src/banner.ts
  var ID_TOKEN = /\b[A-Z]{1,4}[- ]?\d{4,}\b|\bMRN\b|\b\d{6,}\b/i;
  var HINT = /banner|header|patient|client|record|chart|demograph/i;
  function bannerCandidates() {
    const out = [];
    for (const el of Array.from(document.body.querySelectorAll("*"))) {
      if (el.closest("form, [role=form], input, select, textarea, script, style, option, label")) continue;
      const text = (el.textContent ?? "").replace(/\s+/g, " ").trim();
      if (!text || text.length > 160 || !ID_TOKEN.test(text)) continue;
      if (Array.from(el.children).some((c) => ID_TOKEN.test(c.textContent ?? ""))) continue;
      const rect = el.getBoundingClientRect();
      const hinted = HINT.test(`${el.id} ${el.className} ${el.getAttribute("role") ?? ""}`);
      if (rect.width === 0 && rect.height === 0) continue;
      const score = (hinted ? 2 : 0) + (rect.top < 200 ? 1 : 0) + (el.id ? 1 : 0);
      out.push({ el, text, score });
    }
    return out.sort((a, b) => b.score - a.score).slice(0, 8).map(({ el, text }) => ({ selector: selectorFor(el), text }));
  }
  function selectorFor(el) {
    if (el.id && !isGeneratedId(el.id)) return cssId(el.id);
    const testid = el.getAttribute("data-testid");
    if (testid) return `[data-testid="${testid.replace(/"/g, '\\"')}"]`;
    return `xpath=${xpathOf(el)}`;
  }

  // src/guard.ts
  var SubmitGuardError = class extends Error {
    constructor(what) {
      super(`submit_guard: refused to click ${what}`);
    }
  };
  function isForbidden(el) {
    const tag2 = el.tagName.toLowerCase();
    if (tag2 === "button") {
      const type = (el.getAttribute("type") ?? "").toLowerCase();
      if (type === "submit" || type === "" && el.form) return true;
    }
    if (tag2 === "input") {
      const type = el.type.toLowerCase();
      if (type === "submit" || type === "image") return true;
    }
    if (tag2 === "a" && el.href) return true;
    if (el.closest(".form-actions, [role=toolbar][data-form-actions]")) return true;
    return false;
  }
  function guardedClick(el) {
    if (isForbidden(el)) throw new SubmitGuardError(describe(el));
    el.click();
  }
  function describe(el) {
    const id = el.id ? `#${el.id}` : "";
    return `<${el.tagName.toLowerCase()}${id}>`;
  }

  // src/netwatch.ts
  var NetWatch = class {
    requests = 0;
    urls = [];
    active = true;
    restores = [];
    constructor(windows) {
      for (const w of windows) this.wrap(w);
    }
    stop() {
      this.active = false;
      for (const restore of this.restores.reverse()) restore();
      this.restores = [];
      return { requests: this.requests, urls: this.urls };
    }
    record(w, url) {
      if (!this.active) return;
      this.requests++;
      try {
        const u = new URL(String(url), w.location.href);
        const s = u.origin + u.pathname;
        if (!this.urls.includes(s)) this.urls.push(s);
      } catch {
      }
    }
    wrap(w) {
      const self = this;
      const fetch = w.fetch;
      if (typeof fetch === "function") {
        const wrapped = function(...args) {
          const input = args[0];
          self.record(w, typeof input === "object" && input && "url" in input ? input.url : input);
          return fetch.apply(w, args);
        };
        w.fetch = wrapped;
        this.restores.push(() => {
          if (w.fetch === wrapped) w.fetch = fetch;
        });
      }
      const xhr = w.XMLHttpRequest?.prototype;
      if (xhr) {
        const { open, send } = xhr;
        const targets = /* @__PURE__ */ new WeakMap();
        const wrappedOpen = function(...args) {
          targets.set(this, args[1]);
          return open.apply(this, args);
        };
        const wrappedSend = function(body) {
          self.record(w, targets.get(this) ?? "");
          return send.call(this, body);
        };
        xhr.open = wrappedOpen;
        xhr.send = wrappedSend;
        this.restores.push(() => {
          if (xhr.open === wrappedOpen) xhr.open = open;
          if (xhr.send === wrappedSend) xhr.send = send;
        });
      }
      const nav = w.navigator;
      const beacon = nav?.sendBeacon;
      if (typeof beacon === "function") {
        const own = Object.prototype.hasOwnProperty.call(nav, "sendBeacon");
        const wrapped = function(url, data) {
          self.record(w, url);
          return beacon.call(nav, url, data);
        };
        nav.sendBeacon = wrapped;
        this.restores.push(() => {
          if (nav.sendBeacon !== wrapped) return;
          if (own) nav.sendBeacon = beacon;
          else delete nav.sendBeacon;
        });
      }
    }
  };
  function sameOriginWindows(w = window) {
    const out = [w];
    for (let i = 0; i < w.frames.length; i++) {
      try {
        const child = w.frames[i];
        void child.document;
        out.push(...sameOriginWindows(child));
      } catch {
      }
    }
    return out;
  }

  // src/fill.ts
  var DEFAULT_SETTLE_MS = 1e3;
  var COMBO_OPEN_TIMEOUT_MS = 2e3;
  var STEP_SETTLE_MS = 50;
  async function fill(cmd) {
    stripEvidence(cmd);
    const { profile: profile2 } = cmd;
    const derived = cmd.derived ?? {};
    const naive = new Set(cmd.debug_naive ?? []);
    const overwrite = new Set(cmd.overwrite ?? []);
    const settle = Math.max(0, cmd.settle_ms ?? DEFAULT_SETTLE_MS);
    if (cmd.identity) checkIdentity(cmd.identity);
    rememberComboDefaults();
    const byKey = new Map(profile2.fields.map((f) => [f.key, f]));
    const reports = [];
    const work = [];
    const verify = [];
    for (const r of cmd.results) {
      if (r.status !== "filled" || r.value === void 0 || r.value === null) continue;
      const field = byKey.get(r.key);
      const report = { key: r.key, intended: r.value, read_back: null, outcome: "not_found", prior_value: null };
      if (field?.write === "never") {
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
      const report = { key, intended: expected, read_back: null, outcome: "not_found", prior_value: null };
      reports.push(report);
      if (field) verify.push({ field, expected, report });
    }
    const watch = new NetWatch(sameOriginWindows());
    const marks = { any: false, sheet: false };
    let network;
    try {
      await forEachByStep(profile2, work, async (w) => {
        const els = resolveField(w.field);
        if (!els.length) return;
        const prior = readValue(w.field, els);
        w.report.prior_value = prior;
        w.report.read_back = prior;
        if (!overwrite.has(w.field.key) && !sameValue(prior, defaultValue(w.field, els)) && !sameValue(prior, w.value)) {
          w.report.outcome = "conflict_skipped";
          return;
        }
        const result = sameValue(prior, w.value) ? "written" : await write(w.field, els, w.value, naive.has(w.field.key));
        if (result !== "written") return;
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
  function stripEvidence(cmd) {
    if (!Array.isArray(cmd.results)) throw new Error("bad_command: results must be an array");
    for (const r of cmd.results) {
      for (const k of Object.keys(r)) if (k !== "key" && k !== "status" && k !== "value") delete r[k];
    }
  }
  function checkIdentity(identity) {
    const canon = (s) => s.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
    const el = queryAll(document, identity.selector)[0];
    const want = canon(identity.expected ?? "");
    if (!el || !want || !containsToken(canon(el.textContent ?? ""), want)) throw new Error("identity_mismatch");
  }
  function containsToken(text, want) {
    const word = /[\p{L}\p{N}]/u;
    for (let i = text.indexOf(want); i >= 0; i = text.indexOf(want, i + 1)) {
      const before = i > 0 ? text[i - 1] : "";
      const after = text[i + want.length] ?? "";
      if (!word.test(before) && !word.test(after)) return true;
    }
    return false;
  }
  async function focusField(cmd) {
    if (cmd.identity) checkIdentity(cmd.identity);
    const field = cmd.profile.fields.find((f) => f.key === cmd.key);
    if (!field) throw new Error(`not_found: ${cmd.key}`);
    const step = cmd.profile.steps.find((s) => s.id === field.step);
    if (step) await activate(step);
    const el = resolveField(field)[0];
    if (!el) throw new Error(`not_found: ${cmd.key}`);
    const frame = el.ownerDocument.defaultView?.frameElement;
    frame?.scrollIntoView({ block: "center" });
    el.scrollIntoView({ block: "center" });
    el.focus?.({ preventScroll: true });
    return { focused: cmd.key };
  }
  async function undo(cmd) {
    if (cmd.identity) checkIdentity(cmd.identity);
    const byKey = new Map(cmd.profile.fields.map((f) => [f.key, f]));
    const results = [];
    const work = [];
    for (const r of cmd.reports) {
      if (r.outcome !== "ok" && r.outcome !== "reverted") continue;
      const result = { key: r.key, outcome: "not_found", read_back: null };
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
      if (!sameValue(now, w.report.read_back ?? "")) {
        w.result.outcome = "changed_since";
        w.result.read_back = now;
        return;
      }
      w.els = els;
      if (await write(w.field, els, w.value, false) === "unsupported") w.result.outcome = "unrestorable";
    });
    await sleep(Math.max(0, cmd.settle_ms ?? DEFAULT_SETTLE_MS));
    for (const w of work) {
      if (!w.els) continue;
      w.result.read_back = readValue(w.field, w.els);
      if (w.result.outcome !== "unrestorable") w.result.outcome = sameValue(w.result.read_back, w.value) ? "restored" : "failed";
    }
    return { results };
  }
  function readValues(profile2) {
    const out = {};
    for (const f of profile2.fields) {
      const els = resolveField(f);
      out[f.key] = els.length ? readValue(f, els) : null;
    }
    return out;
  }
  async function forEachByStep(profile2, items, fn) {
    const known = new Set(profile2.steps.map((s) => s.id));
    for (const item of items) if (!known.has(item.field.step)) await fn(item);
    let activated = false;
    for (const step of profile2.steps) {
      const mine = items.filter((i) => i.field.step === step.id);
      if (!mine.length) continue;
      activated = await activate(step) || activated;
      for (const item of mine) await fn(item);
    }
    if (activated && profile2.steps[0]) await activate(profile2.steps[0]);
  }
  async function activate(step) {
    if (!step.activate.click.length) return false;
    for (const sel of step.activate.click) {
      const el = queryAll(document, sel)[0];
      if (!el) continue;
      try {
        guardedClick(el);
      } catch (e) {
        if (!(e instanceof SubmitGuardError)) throw e;
      }
    }
    await sleep(STEP_SETTLE_MS);
    return true;
  }
  async function write(f, els, value, naive) {
    const el = els[0];
    switch (f.write) {
      case "native_setter":
        if (Array.isArray(value)) return "no_target";
        if (naive) {
          el.value = value;
          fire(el, "input");
        } else {
          el.focus();
          setValue(el, value);
          fire(el, "input");
          fire(el, "change");
          el.blur();
        }
        return "written";
      case "select":
        if (Array.isArray(value) || ![...el.options].some((o) => o.value === value)) return "no_target";
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
  function writeRadio(els, value) {
    if (Array.isArray(value)) return "no_target";
    const inputs = els;
    if (value === "") {
      const checked = inputs.find((i) => i.checked);
      if (checked) {
        Object.getOwnPropertyDescriptor(view(checked).HTMLInputElement.prototype, "checked").set.call(checked, false);
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
  function writeCheckboxes(els, value) {
    const want = new Set(Array.isArray(value) ? value : [value]);
    const inputs = els;
    if ([...want].some((v) => !inputs.some((i) => i.value === v))) return "no_target";
    for (const input of inputs) if (input.checked !== want.has(input.value)) guardedClick(input);
    return "written";
  }
  async function pickComboOption(trigger, value) {
    if (value === "") return "unsupported";
    const listbox = trigger.ownerDocument.getElementById(idList(trigger, "aria-controls")[0] ?? "");
    if (!listbox) return "no_target";
    const option = [...listbox.querySelectorAll("[role=option]")].find(
      (o) => (o.getAttribute("data-value") ?? norm(o.textContent ?? "")) === value
    );
    if (!option) return "no_target";
    if (!visible(listbox)) guardedClick(trigger);
    if (!await until(() => visible(listbox), COMBO_OPEN_TIMEOUT_MS)) return "written";
    guardedClick(option);
    await until(() => comboValue(trigger) === value, 500);
    return "written";
  }
  function setValue(el, value) {
    const w = view(el);
    const t = tag(el);
    const proto = t === "textarea" ? w.HTMLTextAreaElement.prototype : t === "select" ? w.HTMLSelectElement.prototype : w.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
  }
  function fire(el, type) {
    el.dispatchEvent(new (view(el)).Event(type, { bubbles: true }));
  }
  function visible(el) {
    return !el.hidden && el.getClientRects().length > 0;
  }
  async function until(cond, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (!cond()) {
      if (Date.now() >= deadline) return false;
      await sleep(20);
    }
    return true;
  }
  var HIGHLIGHT_CSS = '[data-scribeski="filled"]{outline:2px solid #1a73e8 !important;outline-offset:1px !important}';
  var styled = /* @__PURE__ */ new WeakMap();
  function mark(els, on) {
    for (const el of els) {
      if (on) el.setAttribute("data-scribeski", "filled");
      else el.removeAttribute("data-scribeski");
    }
    return on ? ensureStylesheet(els[0].ownerDocument) : false;
  }
  function ensureStylesheet(doc) {
    const known = styled.get(doc);
    if (known !== void 0) return known;
    let ok = false;
    try {
      const w = doc.defaultView;
      const sheet = new w.CSSStyleSheet();
      sheet.replaceSync(HIGHLIGHT_CSS);
      doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
      ok = true;
    } catch {
    }
    styled.set(doc, ok);
    return ok;
  }

  // src/protocol.ts
  var JobTable = class {
    constructor(handle2) {
      this.handle = handle2;
    }
    handle;
    next = 1;
    jobs = /* @__PURE__ */ new Map();
    start(cmdJSON) {
      let cmd;
      try {
        cmd = JSON.parse(cmdJSON);
      } catch {
        return JSON.stringify({ error: "bad_json" });
      }
      const id = `j${this.next++}`;
      this.jobs.set(id, { done: false });
      Promise.resolve().then(() => this.handle(cmd)).then(
        (result) => this.jobs.set(id, { done: true, ok: true, result }),
        (err) => this.jobs.set(id, { done: true, ok: false, error: errorMessage(err) })
      );
      return JSON.stringify({ job: id });
    }
    /** Returns the job state. A finished job is forgotten once its result is delivered. */
    poll(id) {
      const state = this.jobs.get(id);
      if (!state) return JSON.stringify({ done: true, ok: false, error: "unknown_job" });
      if (state.done) this.jobs.delete(id);
      return JSON.stringify(state);
    }
    get pending() {
      return [...this.jobs.values()].filter((j) => !j.done).length;
    }
  };
  function errorMessage(err) {
    return err instanceof Error ? err.message : String(err);
  }

  // src/index.ts
  function handle(cmd) {
    switch (cmd.op) {
      case "ping":
        return { pong: true, version: "0.0.1", url: location.origin + location.pathname };
      case "sleep":
        return new Promise((resolve) => setTimeout(() => resolve({ slept: cmd.ms }), cmd.ms));
      case "profile":
        return profile();
      case "click": {
        const el = document.querySelector(cmd.selector);
        if (!el) throw new Error(`not_found: ${cmd.selector}`);
        guardedClick(el);
        return { clicked: cmd.selector };
      }
      case "fill":
        return fill(cmd);
      case "undo":
        return undo(cmd);
      case "focus":
        return focusField(cmd);
      case "banner_candidates":
        return bannerCandidates();
      case "read_values":
        return readValues(cmd.profile);
      default:
        throw new Error(`unknown_op: ${cmd.op}`);
    }
  }
  function newer(a, b) {
    const pa = a.split(".").map(Number);
    const pb = b.split(".").map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const d = (pa[i] ?? 0) - (pb[i] ?? 0);
      if (d !== 0) return d > 0;
    }
    return false;
  }
  var existing = window.__scribeski;
  if (!existing || newer("0.0.1", existing.version)) {
    const jobs = new JobTable(handle);
    const api = {
      version: "0.0.1",
      start: (cmdJSON) => jobs.start(cmdJSON),
      poll: (id) => jobs.poll(id)
    };
    Object.defineProperty(window, "__scribeski", { value: Object.freeze(api), configurable: true });
    rememberComboDefaults();
  }
})();
