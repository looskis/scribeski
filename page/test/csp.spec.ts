import { expect, test } from "@playwright/test";
import type { FillReport, FormProfile } from "../src/types";
import { ok, openMockEhr } from "./helpers";

// Profile + fill on the strict-CSP page (no unsafe-inline, no unsafe-eval). Caveat as in
// fixture.spec.ts: Playwright's evaluate isn't subject to page CSP, so this proves the bundle
// needs nothing CSP forbids (eval, <style>, inline script), not that Safari's injection works.

test("profile, fill, highlight and read-back work under a strict CSP", async ({ page }) => {
  const violations: string[] = [];
  page.on("console", (m) => /Content Security Policy|Refused/i.test(m.text()) && !/frame-ancestors/.test(m.text()) && violations.push(m.text()));

  await openMockEhr(page, "/csp.html");
  const profile: FormProfile = await ok(page, { op: "profile" });
  expect(profile.fields.map((f) => [f.key, f.kind])).toEqual([
    ["case_number", "text"],
    ["client_last_name", "text"],
    ["session_type", "select"],
    ["session_date", "date"],
    ["presenting_problem", "textarea"],
  ]);
  expect(profile.steps).toEqual([{ id: "step-main", activate: { click: [] } }]);
  expect(profile.fields.every((f) => f.step === "step-main")).toBe(true);

  const res = await ok(page, {
    op: "fill",
    profile,
    results: [
      { key: "case_number", status: "filled", value: "AB-114322" },
      { key: "client_last_name", status: "filled", value: "Reyes" },
      { key: "session_type", status: "filled", value: "INTAKE" },
      { key: "session_date", status: "filled", value: "2026-09-17" },
      { key: "presenting_problem", status: "filled", value: "Low mood and poor sleep." },
    ],
  });
  expect(res.reports.map((r: FillReport) => r.outcome)).toEqual(["ok", "ok", "ok", "ok", "ok"]);

  // The constructable stylesheet is not blocked by style-src 'self'.
  expect(res.highlight).toBe("stylesheet");
  expect(await page.$eval("#case_number", (e) => getComputedStyle(e).outlineStyle)).toBe("solid");
  expect(violations).toEqual([]);
});
