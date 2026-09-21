import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import type { FieldResult, FillReport, FormProfile } from "../src/types";
import { inject, ok, openMockEhr, run } from "./helpers";

// The filler against the mock EHR: every write strategy, read-back, conflict policy, undo,
// identity guard, autosave detection, and the rules that nothing submits and no evidence
// reaches the DOM.

const expected = JSON.parse(readFileSync(new URL("../../fixtures/expected-extraction.json", import.meta.url), "utf8"));
const RECORD = { selector: "#record_banner", expected: "AB-114322" };
const QUOTE = "EVIDENCE-QUOTE"; // every evidence quote below contains this marker

/** must_fill + checkbox must_include sets + a few text/date/textarea/iframe values. */
function sessionResults(profile: FormProfile): FieldResult[] {
  const values: Record<string, string | string[]> = { ...expected.must_fill };
  for (const [key, c] of Object.entries<any>(expected.checkbox_constraints)) values[key] = [...c.must_include].sort();
  Object.assign(values, {
    client_first_name: "Daniela",
    client_dob: "1989-03-03",
    address_city: "Fairhaven",
    next_appointment: "2026-09-24",
    risk_narrative: "Passive SI several days, mostly at night. Denies plan and intent.",
    [profile.fields.find((f) => f.label === "Duration (minutes)")!.key]: "50",
  });
  const results: any[] = Object.entries(values).map(([key, value]) => ({
    key,
    status: "filled",
    value,
    evidence: [{ segment: "s0001", quote: `${QUOTE} for ${key}: I haven't really been sleeping` }],
    model: "test",
  }));
  // Not "filled": never written.
  results.push({ key: "risk_level", status: "clinician_only", value: "LOW", evidence: [] });
  results.push({ key: "gender_identity", status: "insufficient_evidence", value: null, evidence: [] });
  return results;
}

async function profileOf(page: Page): Promise<FormProfile> {
  return ok(page, { op: "profile" });
}

const byKey = (reports: FillReport[]) => new Map(reports.map((r) => [r.key, r]));

async function allHtml(page: Page): Promise<string> {
  return page.evaluate(() => {
    const frame = (document.getElementById("risk_frame") as HTMLIFrameElement).contentDocument!;
    return document.documentElement.outerHTML + frame.documentElement.outerHTML;
  });
}

test.describe("filler", () => {
  let submits: string[];

  test.beforeEach(async ({ page }) => {
    submits = [];
    page.on("console", (m) => m.text().includes("[mock-ehr] SUBMIT") && submits.push(m.text()));
  });

  test.afterEach(async ({ page }) => {
    expect(submits).toEqual([]);
    expect(await page.getAttribute("html", "data-mock-ehr-submitted")).toBeNull();
  });

  test("fills the session: every report ok, computed fields verified, no evidence in the DOM", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const results = sessionResults(profile);
    const res = await ok(page, { op: "fill", profile, results, derived: expected.derived, identity: RECORD });

    const reports = byKey(res.reports);
    const filled = results.filter((r) => r.status === "filled");
    expect(res.reports).toHaveLength(filled.length + 4);
    for (const r of filled) expect({ key: r.key, outcome: reports.get(r.key)!.outcome }).toEqual({ key: r.key, outcome: "ok" });
    expect(reports.has("risk_level")).toBe(false);
    expect(reports.has("gender_identity")).toBe(false);

    expect(reports.get("case_number")).toEqual({ key: "case_number", intended: "AB-114322", read_back: "AB-114322", outcome: "ok", prior_value: "" });
    expect(reports.get("language_combo")).toMatchObject({ read_back: "ENGLISH", outcome: "ok", prior_value: "" });
    expect(reports.get("protective_factors")).toMatchObject({ read_back: ["FAMILY_CONNECTION", "CHILDREN_IN_HOME"], outcome: "ok", prior_value: [] });
    expect(reports.get("phq9_score")).toEqual({ key: "phq9_score", intended: "18", read_back: "18", outcome: "computed_verified", prior_value: null });
    expect(reports.get("phq9_severity")).toMatchObject({ read_back: "MODERATELY_SEVERE", outcome: "computed_verified" });
    expect(reports.get("gad7_score")).toMatchObject({ intended: null, read_back: "", outcome: "computed_verified" });
    expect(reports.get("gad7_severity")).toMatchObject({ outcome: "computed_verified" });

    expect(res.identity).toBe("verified");
    expect(res.network).toEqual({ requests: 0, urls: [] });
    expect(res.highlight).toBe("stylesheet");

    // Values persisted in the page (case_number is the controlled input that reverts naive writes).
    await page.waitForTimeout(500);
    expect(await page.inputValue("#case_number")).toBe("AB-114322");
    expect(await page.getAttribute("#language_combo", "data-value")).toBe("ENGLISH");
    expect(await page.frameLocator("#risk_frame").locator("#si_ideation").inputValue()).toBe("PASSIVE");
    // Back on step 1, highlighted, and highlighted fields are visibly outlined.
    expect(await page.getAttribute("#tab-client", "aria-selected")).toBe("true");
    expect(await page.getAttribute("#case_number", "data-scribeski")).toBe("filled");
    expect(await page.$eval("#case_number", (e) => getComputedStyle(e).outlineStyle)).toBe("solid");
    expect(await page.frameLocator("#risk_frame").locator("#si_ideation").getAttribute("data-scribeski")).toBe("filled");
    expect(await page.getAttribute("#gender_identity", "data-scribeski")).toBeNull();

    const html = await allHtml(page);
    expect(html).not.toContain(QUOTE);
    expect(html).not.toContain("haven't really been sleeping");
    expect(html).not.toContain("s0001");
  });

  test("read-back catches a naive write that the page reverts", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const results = [{ key: "case_number", status: "filled", value: "AB-114322" }];
    const res = await ok(page, { op: "fill", profile, results, debug_naive: ["case_number"] });
    expect(res.reports).toEqual([{ key: "case_number", intended: "AB-114322", read_back: "", outcome: "reverted", prior_value: "" }]);
    expect(await page.getAttribute("#case_number", "data-scribeski")).toBeNull();
  });

  test("conflict policy compares to the page-load default", async ({ page }) => {
    await page.goto("/index.html");
    await page.frameLocator("#risk_frame").locator("#si_ideation").waitFor({ state: "attached" });
    // A select with no empty option: its default is its first option, which is not a conflict.
    await page.evaluate(() => document.querySelector('#interpreter_needed option[value=""]')!.remove());
    // Language chosen before the bundle arrived: that's the combobox's default, not a conflict.
    await page.click("#language_combo");
    await page.click('#language_listbox [data-value="SPANISH"]');
    await inject(page);
    // The worker types after the bundle arrived: these are conflicts.
    await page.fill("#client_first_name", "Dana");
    await page.selectOption("#pronouns", "THEY_THEM");

    const profile = await profileOf(page);
    const results = [
      { key: "client_first_name", status: "filled", value: "Daniela" },
      { key: "pronouns", status: "filled", value: "SHE_HER" },
      { key: "interpreter_needed", status: "filled", value: "NO" },
      { key: "language_combo", status: "filled", value: "ENGLISH" },
      { key: "client_last_name", status: "filled", value: "Reyes" },
    ];
    const res = await ok(page, { op: "fill", profile, results });
    const reports = byKey(res.reports);
    expect(reports.get("client_first_name")).toMatchObject({ outcome: "conflict_skipped", read_back: "Dana", prior_value: "Dana" });
    expect(reports.get("pronouns")).toMatchObject({ outcome: "conflict_skipped", read_back: "THEY_THEM" });
    expect(reports.get("interpreter_needed")).toMatchObject({ outcome: "ok", prior_value: "YES", read_back: "NO" });
    expect(reports.get("language_combo")).toMatchObject({ outcome: "ok", prior_value: "SPANISH", read_back: "ENGLISH" });
    expect(reports.get("client_last_name")).toMatchObject({ outcome: "ok" });
    expect(await page.inputValue("#client_first_name")).toBe("Dana");
    expect(await page.inputValue("#pronouns")).toBe("THEY_THEM");
    expect(await page.getAttribute("#client_first_name", "data-scribeski")).toBeNull();

    // Undo puts the pre-bundle combobox choice back through the widget.
    const undone = await ok(page, { op: "undo", profile, reports: res.reports });
    expect(byKey(undone.results).get("language_combo")).toMatchObject({ outcome: "restored", read_back: "SPANISH" });
    expect(byKey(undone.results).has("client_first_name")).toBe(false);
  });

  test("a combobox changed after the bundle arrived is a conflict", async ({ page }) => {
    await openMockEhr(page);
    await page.click("#language_combo");
    await page.click('#language_listbox [data-value="TAGALOG"]');
    const profile = await profileOf(page);
    const res = await ok(page, { op: "fill", profile, results: [{ key: "language_combo", status: "filled", value: "ENGLISH" }] });
    expect(res.reports[0]).toMatchObject({ outcome: "conflict_skipped", read_back: "TAGALOG", prior_value: "TAGALOG" });
    expect(await page.getAttribute("#language_combo", "data-value")).toBe("TAGALOG");
  });

  test("a worker's edit from the review panel overwrites the machine's value", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    await ok(page, { op: "fill", profile, results: [{ key: "client_first_name", status: "filled", value: "Daniela" }] });
    // Without `overwrite`, our own earlier value now looks like someone else's: skipped.
    const plain = await ok(page, { op: "fill", profile, results: [{ key: "client_first_name", status: "filled", value: "Dani" }] });
    expect(plain.reports[0]).toMatchObject({ outcome: "conflict_skipped", read_back: "Daniela" });
    // The worker's explicit edit wins.
    const edited = await ok(page, {
      op: "fill", profile, overwrite: ["client_first_name"],
      results: [{ key: "client_first_name", status: "filled", value: "Dani" }],
    });
    expect(edited.reports[0]).toMatchObject({ outcome: "ok", prior_value: "Daniela", read_back: "Dani" });
    expect(await page.inputValue("#client_first_name")).toBe("Dani");
  });

  test("focus opens the field's step, scrolls to it, and changes nothing", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const first = profile.steps[0]!.id;
    const target = profile.fields.find((f: { step: string }) => f.step !== first)!;
    expect(target).toBeTruthy();
    const before = await ok(page, { op: "read_values", profile });
    const res = await ok(page, { op: "focus", profile, key: target.key });
    expect(res).toEqual({ focused: target.key });
    const after = await ok(page, { op: "read_values", profile });
    expect(after).toEqual(before);
    const missing = await run(page, { op: "focus", profile, key: "no_such_field" });
    expect(missing).toMatchObject({ done: true, ok: false });
  });

  test("undo restores the snapshot", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const before = await ok(page, { op: "read_values", profile });
    expect(Object.keys(before)).toHaveLength(107);

    const res = await ok(page, { op: "fill", profile, results: sessionResults(profile), derived: expected.derived });
    const during = await ok(page, { op: "read_values", profile });
    expect(during.phq9_score).toBe("18");

    const undone = await ok(page, { op: "undo", profile, reports: res.reports });
    const after = await ok(page, { op: "read_values", profile });

    // A listbox has no "nothing" option, so a combobox that started blank can't be cleared
    // through the widget. Undo says so rather than poking the widget's DOM.
    const outcomes = byKey(undone.results);
    expect(outcomes.get("language_combo")!.outcome).toBe("unrestorable");
    for (const r of undone.results) if (r.key !== "language_combo") expect({ key: r.key, outcome: r.outcome }).toEqual({ key: r.key, outcome: "restored" });
    expect({ ...after, language_combo: "" }).toEqual(before);

    const marked = await page.evaluate(() => {
      const frame = (document.getElementById("risk_frame") as HTMLIFrameElement).contentDocument!;
      return document.querySelectorAll("[data-scribeski]").length + frame.querySelectorAll("[data-scribeski]").length;
    });
    expect(marked).toBe(0);
  });

  test("undo checks the client and leaves fields changed since alone", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const before = await ok(page, { op: "read_values", profile });
    const results = [
      { key: "pronouns", status: "filled", value: "SHE_HER" },
      { key: "client_preferred_name", status: "filled", value: "Dani" },
    ];
    const res = await ok(page, { op: "fill", profile, results, identity: RECORD });

    // Another client's chart: nothing is restored.
    const wrong = await run(page, { op: "undo", profile, reports: res.reports, identity: { ...RECORD, expected: "AB-999999" } });
    expect(wrong).toMatchObject({ ok: false, error: "identity_mismatch" });

    // The worker retyped one field after the fill: undo leaves their value.
    await page.fill("#client_preferred_name", "Daniela R.");
    const undone = await ok(page, { op: "undo", profile, reports: res.reports, identity: RECORD });
    const outcomes = byKey(undone.results);
    expect(outcomes.get("pronouns")!.outcome).toBe("restored");
    expect(outcomes.get("client_preferred_name")).toMatchObject({ outcome: "changed_since", read_back: "Daniela R." });
    const after = await ok(page, { op: "read_values", profile });
    expect(after.pronouns).toEqual(before.pronouns);
    expect(after.client_preferred_name).toBe("Daniela R.");
  });

  test("identity mismatch writes nothing", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const before = await ok(page, { op: "read_values", profile });
    for (const identity of [
      { selector: "#record_banner", expected: "AB-999999" },
      { selector: "#no_such_banner", expected: "AB-114322" },
      // A prefix of the shown record isn't that record.
      { selector: "#record_banner", expected: "AB-11432" },
    ]) {
      const state = await run(page, { op: "fill", profile, results: sessionResults(profile), identity }, 15000);
      expect(state).toMatchObject({ ok: false, error: "identity_mismatch" });
    }
    expect(await ok(page, { op: "read_values", profile })).toEqual(before);
    // Case and whitespace don't matter.
    const res = await ok(page, {
      op: "fill",
      profile,
      results: [{ key: "pronouns", status: "filled", value: "SHE_HER" }],
      identity: { selector: "#record_banner", expected: "  reyes,   DANIELA " },
    });
    expect(res.reports[0].outcome).toBe("ok");
  });

  test("reports page traffic while filling (autosave)", async ({ page }) => {
    await openMockEhr(page, "/index.html?autosave=1");
    const profile = await profileOf(page);
    expect(profile.path_pattern).toBe("/index.html");
    const results = [
      { key: "case_number", status: "filled", value: "AB-114322" },
      { key: "pronouns", status: "filled", value: "SHE_HER" },
      { key: "phq9_1", status: "filled", value: "2" },
    ];
    const res = await ok(page, { op: "fill", profile, results });
    expect(res.reports.every((r: FillReport) => r.outcome === "ok")).toBe(true);
    expect(res.network.requests).toBeGreaterThanOrEqual(3);
    expect(res.network.urls).toEqual(["http://127.0.0.1:8787/autosave"]);
    // Our wrappers are gone afterwards.
    expect(await page.evaluate(() => window.fetch.toString())).toContain("[native code]");
    expect(await page.evaluate(() => XMLHttpRequest.prototype.send.toString())).toContain("[native code]");
  });

  test("results for unknown keys and options are not_found; nothing else is touched", async ({ page }) => {
    await openMockEhr(page);
    const profile = await profileOf(page);
    const res = await ok(page, {
      op: "fill",
      profile,
      results: [
        { key: "no_such_field", status: "filled", value: "X" },
        { key: "pronouns", status: "filled", value: "XE_XEM" },
        { key: "substances", status: "filled", value: ["ALCOHOL", "KAVA"] },
      ],
    });
    expect(res.reports.map((r: FillReport) => r.outcome)).toEqual(["not_found", "not_found", "not_found"]);
    expect(await page.inputValue("#pronouns")).toBe("");
    expect(await page.isChecked('input[name="substances"][value="ALCOHOL"]')).toBe(false);
  });
});
