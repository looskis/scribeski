import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import type { Field, FormProfile } from "../src/types";
import { generalizePath } from "../src/profile";
import { inject, ok, openMockEhr } from "./helpers";

// The profiler against the mock EHR. FIELDS.md is the ground truth and is parsed here, so
// the fixture spec and the profiler can't drift apart silently.
// Regenerate the golden file with: UPDATE_GOLDEN=1 npx playwright test profile

const FIELDS_MD = readFileSync(new URL("../../fixtures/mock-ehr/FIELDS.md", import.meta.url), "utf8");
const GOLDEN = new URL("./golden/mock-ehr.profile.json", import.meta.url);

interface Expected {
  key: string;
  kind: string;
  source: string | null;
  label?: string;
  options?: string[];
}

/** Every field row of every FIELDS.md table, with key ranges and lists expanded. */
function parseFieldsMd(md: string): Expected[] {
  const out: Expected[] = [];
  let header: string[] | null = null;
  for (const line of md.split("\n")) {
    if (!line.startsWith("|")) {
      header = null;
      continue;
    }
    const cells = line.split("|").slice(1, -1).map((c) => c.trim());
    if (cells[0] === "#") {
      header = cells;
      continue;
    }
    if (!header || !/^\d/.test(cells[0]!)) continue;
    const col = (name: string) => {
      // Exact header first ("label" vs "label source"), then prefix ("options (value)").
      let i = header!.indexOf(name);
      if (i < 0) i = header!.findIndex((h) => h.startsWith(name));
      return i >= 0 ? cells[i]! : undefined;
    };
    const keys = expandKeys(col("key")!);
    const kind = col("kind")!;
    // Tables without a label-source column are the iframe's, all label[for] (FIELDS.md step 3).
    const rawSource = col("label source") ?? "label_for";
    const source = rawSource === "—" ? null : rawSource;
    let label = col("label")?.replace(/^"(.*)"$/, "$1");
    if (keys.length > 1 || kind === "hidden" || !label || label.includes("…") || label.includes(" — ")) label = undefined;
    const opts = col("options");
    const options = opts ? opts.split(",").map((s) => s.trim()) : undefined;
    for (const key of keys) out.push({ key, kind, source, label, options });
  }
  return out;
}

function expandKeys(cell: string): string[] {
  const range = cell.match(/^(\w+?)(\d+) … \1(\d+)$/);
  if (range) {
    const [, prefix, from, to] = range;
    return Array.from({ length: Number(to) - Number(from) + 1 }, (_, i) => `${prefix}${Number(from) + i}`);
  }
  return cell.replace("*(none)*", "").split(",").map((s) => s.trim());
}

async function profileOf(page: Page): Promise<FormProfile> {
  return ok(page, { op: "profile" });
}

/** FIELDS.md calls the id-less, name-less duration input "duration"; the profile hashes it. */
function byFieldsKey(profile: FormProfile): Map<string, Field> {
  const map = new Map(profile.fields.map((f) => [f.key, f]));
  const duration = profile.fields.find((f) => f.label === "Duration (minutes)");
  if (duration) map.set("duration", duration);
  return map;
}

test.describe("profiler", () => {
  test.beforeEach(async ({ page }) => {
    await openMockEhr(page);
  });

  test("matches FIELDS.md: 107 fields, kinds, label sources, labels, options", async ({ page }) => {
    const profile = await profileOf(page);
    const expected = parseFieldsMd(FIELDS_MD);
    expect(expected).toHaveLength(107);
    expect(profile.fields).toHaveLength(107);

    const fields = byFieldsKey(profile);
    for (const e of expected) {
      const f = fields.get(e.key);
      expect(f, e.key).toBeDefined();
      expect({ key: e.key, kind: f!.kind }).toEqual({ key: e.key, kind: e.kind });
      expect({ key: e.key, source: f!.label_source ?? null }).toEqual({ key: e.key, source: e.source });
      if (e.label) expect({ key: e.key, label: f!.label }).toEqual({ key: e.key, label: e.label });
      if (e.options) expect({ key: e.key, options: f!.options.map((o) => o.value) }).toEqual({ key: e.key, options: e.options });
    }
  });

  test("steps, frames, combobox, hidden, hashed key", async ({ page }) => {
    const profile = await profileOf(page);
    expect(profile.schema).toBe("scribeski.form-profile/1");
    expect(profile.path_pattern).toBe("/index.html");
    expect(profile.unreachable).toEqual([]);
    expect(profile.steps).toEqual(
      ["client", "screening", "risk", "plan"].map((s) => ({ id: `step-${s}`, activate: { click: [`#tab-${s}`] } })),
    );

    const inFrame = profile.fields.filter((f) => f.frame.length);
    expect(inFrame).toHaveLength(10);
    for (const f of inFrame) {
      expect(f.frame).toEqual(["#risk_frame"]);
      expect(f.step).toBe("step-risk");
    }

    const combo = profile.fields.find((f) => f.key === "language_combo")!;
    expect(combo).toMatchObject({ kind: "combobox", write: "combobox_click", label: "Preferred language" });
    expect(combo.options).toHaveLength(7);
    expect(combo.options[0]).toEqual({ value: "ENGLISH", label: "English" });

    const hidden = profile.fields.filter((f) => f.kind === "hidden");
    expect(hidden.map((f) => f.key)).toEqual(["phq9_score", "phq9_severity", "gad7_score", "gad7_severity"]);
    for (const f of hidden) {
      expect(f).toMatchObject({ write: "never", computed: true });
      expect(f.label_source).toBeUndefined();
    }
    expect(profile.fields.filter((f) => f.computed)).toHaveLength(4);

    const sources = new Set(profile.fields.map((f) => f.label_source).filter(Boolean));
    expect([...sources].sort()).toEqual(
      ["aria_label", "aria_labelledby", "label_for", "label_wrap", "legend", "placeholder", "preceding_text"],
    );

    const duration = byFieldsKey(profile).get("duration")!;
    expect(duration.key).toMatch(/^f_[0-9a-f]{10}$/);
    expect(duration.selectors).toHaveLength(1);
    expect(duration.selectors[0]).toMatch(/^xpath=\/html\/body\//);

    // Every field's selectors end with a structural XPath; groups resolve by name first.
    for (const f of profile.fields) expect(f.selectors.at(-1)).toMatch(/^xpath=\//);
    const phq1 = profile.fields.find((f) => f.key === "phq9_1")!;
    expect(phq1.label).toBe("Little interest or pleasure in doing things");
    expect(phq1.options[1]).toEqual({ value: "1", label: "Several days" });
    expect(phq1.selectors[0]).toBe('[name="phq9_1"]');

    const caseNumber = profile.fields.find((f) => f.key === "case_number")!;
    expect(caseNumber).toMatchObject({ help: "Format: AB-000000", step: "step-client", write: "native_setter" });
    expect(caseNumber.selectors.slice(0, 2)).toEqual(["#case_number", '[name="case_number"]']);
    expect(profile.fields.filter((f) => f.required).map((f) => f.key)).toEqual(["client_first_name", "client_last_name", "client_dob"]);
  });

  test("golden snapshot", async ({ page }) => {
    const profile = await profileOf(page);
    const json = JSON.stringify(profile, null, 2) + "\n";
    if (process.env.UPDATE_GOLDEN) {
      mkdirSync(new URL(".", GOLDEN), { recursive: true });
      writeFileSync(GOLDEN, json);
    }
    expect(existsSync(GOLDEN), "no golden file: run with UPDATE_GOLDEN=1").toBe(true);
    expect(json).toBe(readFileSync(GOLDEN, "utf8"));
  });

  test("no PHI: page chrome and control values never enter the profile", async ({ page }) => {
    // Put record data into the controls first, so a profiler that read values would leak it.
    await page.fill("#case_number", "AB-114322");
    await page.fill("#client_last_name", "REYES");
    await page.click("#language_combo");
    await page.click('#language_listbox [data-value="SPANISH"]');
    await page.click("#tab-plan");
    await page.fill("#presenting_problem", "Referred after M. Okonkwo closed");
    await page.check('input[name="substances"][value="ALCOHOL"]');
    const json = JSON.stringify(await profileOf(page));
    for (const phi of ["K. Loo", "2026-0917", "M. Okonkwo", "Okonkwo", "REYES", "Reyes", "Daniela", "AB-114322"]) {
      expect(json, phi).not.toContain(phi);
    }
    expect(json).not.toMatch(/reyes|daniela|okonkwo/i);
  });

  test("fingerprint is stable, and changes when an option is added", async ({ page }) => {
    const a = await profileOf(page);
    await page.reload();
    await openMockEhr(page);
    const b = await profileOf(page);
    expect(a.fingerprint).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(b.fingerprint).toBe(a.fingerprint);

    await page.evaluate(() => {
      const opt = document.createElement("option");
      opt.value = "XE_XEM";
      opt.textContent = "xe/xem";
      document.getElementById("pronouns")!.append(opt);
    });
    const c = await profileOf(page);
    expect(c.fingerprint).not.toBe(a.fingerprint);
  });

  test("framework-generated ids don't become keys, so the same form keeps its keys across loads", async ({ page }) => {
    const html = (n: number) => `
      <label for=":r${n}:">First name</label><input id=":r${n}:" name="first_name">
      <label for="mui-${10000 + n}">Last name</label><input id="mui-${10000 + n}">
      <label for="mat-input-${n}">Phone</label><input id="mat-input-${n}" data-testid="phone">
      <label for="case_number">Case</label><input id="case_number">`;
    const keysFor = async (n: number) => {
      await page.setContent(html(n));
      await inject(page);
      const profile = await ok(page, { op: "profile" });
      return profile.fields.map((f: { key: string }) => f.key);
    };
    const first = await keysFor(3);
    const second = await keysFor(7);
    expect(first).toEqual(second);
    expect(first).toContain("first_name");
    expect(first).toContain("phone");
    expect(first).toContain("case_number");
    expect(first.some((k: string) => k.startsWith(":r") || k.startsWith("mui-") || k.startsWith("mat-"))).toBe(false);
  });

  test("banner candidates put the client banner first, and never read form controls", async ({ page }) => {
    await openMockEhr(page);
    const found = await ok(page, { op: "banner_candidates" });
    expect(found[0]).toEqual({ selector: "#record_banner", text: "Record AB-114322 · REYES, Daniela" });
    for (const c of found) expect(c.selector).not.toMatch(/case_number|input|select/);
  });
});

test("record numbers in the URL path aren't kept in the profile", () => {
  expect(generalizePath("/index.html")).toBe("/index.html");
  expect(generalizePath("/clients/114322/notes/new")).toBe("/clients/*/notes/new");
  expect(generalizePath("/chart/AB-114322/intake")).toBe("/chart/*/intake");
  expect(generalizePath("/v2/forms/progress-note")).toBe("/v2/forms/progress-note");
  expect(generalizePath("/r/3f2b8c1a-9d4e-4c1b-8a7f-2e6d5c4b3a21/edit")).toBe("/r/*/edit");
});
