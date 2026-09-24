import { expect, test, type Page } from "@playwright/test";

// Guards the mock EHR itself (fixtures/mock-ehr/FIELDS.md), independent of the profiler.
// If one of these fails, the fixture changed, and every downstream test is suspect.

/** Counts profiler "fields": one per control, one per radio/checkbox group. */
async function fieldCounts(page: Page) {
  return page.evaluate(() => {
    const count = (doc: Document) => {
      const groups = new Set<string>();
      let n = 0;
      for (const el of doc.querySelectorAll("input, select, textarea, [role=combobox]")) {
        const type = (el as HTMLInputElement).type;
        if (el.tagName === "INPUT" && (type === "radio" || type === "checkbox")) {
          groups.add((el as HTMLInputElement).name);
        } else if (!(el.tagName === "INPUT" && el.closest("[role=combobox]"))) {
          n++;
        }
      }
      return n + groups.size;
    };
    const frame = (document.getElementById("risk_frame") as HTMLIFrameElement).contentDocument!;
    return { top: count(document), frame: count(frame) };
  });
}

test.describe("mock EHR fixture", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/index.html");
    await page.frameLocator("#risk_frame").locator("#si_ideation").waitFor({ state: "attached" });
  });

  test("107 fields, 10 of them in the iframe", async ({ page }) => {
    const { top, frame } = await fieldCounts(page);
    expect(frame).toBe(10);
    expect(top + frame).toBe(107);
  });

  test("64 radios in steps 2–4, hidden on load", async ({ page }) => {
    const radios = await page.evaluate(() =>
      ["panel-screening", "panel-risk", "panel-plan"]
        .map((id) => document.getElementById(id)!)
        .map((p) => ({ hidden: p.hidden, n: p.querySelectorAll("input[type=radio]").length })),
    );
    expect(radios.reduce((a, r) => a + r.n, 0)).toBe(64);
    expect(radios.every((r) => r.hidden)).toBe(true);
  });

  test("65 controls labelled only by aria-labelledby", async ({ page }) => {
    const n = await page.evaluate(
      () => document.querySelectorAll("input[aria-labelledby], select[aria-labelledby], textarea[aria-labelledby], [role=combobox][aria-labelledby]").length,
    );
    expect(n).toBe(65);
  });

  test("combobox has 7 options in the DOM before opening", async ({ page }) => {
    const values = await page.evaluate(() =>
      [...document.querySelectorAll("#language_listbox [role=option]")].map((o) => (o as HTMLElement).dataset.value),
    );
    expect(values).toEqual(["ENGLISH", "SPANISH", "VIETNAMESE", "TAGALOG", "MANDARIN", "ARABIC", "OTHER"]);
  });

  test("duration input has no id and no name", async ({ page }) => {
    const n = await page.evaluate(
      () => [...document.querySelectorAll("input[type=number]")].filter((e) => !e.id && !e.getAttribute("name")).length,
    );
    expect(n).toBe(1);
  });

  test("naive write to #case_number reverts; native setter persists", async ({ page }) => {
    const naive = await page.evaluate(async () => {
      const el = document.getElementById("case_number") as HTMLInputElement;
      el.value = "AB-114322";
      el.dispatchEvent(new Event("input", { bubbles: true }));
      const immediately = el.value;
      await new Promise((r) => setTimeout(r, 900));
      return { immediately, later: el.value };
    });
    expect(naive).toEqual({ immediately: "AB-114322", later: "" });

    const native = await page.evaluate(async () => {
      const el = document.getElementById("case_number") as HTMLInputElement;
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(el, "AB-114322");
      el.dispatchEvent(new Event("input", { bubbles: true }));
      await new Promise((r) => setTimeout(r, 900));
      return el.value;
    });
    expect(native).toBe("AB-114322");
  });

  test("page computes PHQ-9 = 18, moderately severe", async ({ page }) => {
    await page.click("#tab-screening");
    const answers = [2, 3, 3, 2, 1, 2, 2, 2, 1];
    for (const [i, v] of answers.entries()) {
      await page.check(`input[name=phq9_${i + 1}][value="${v}"]`);
    }
    expect(await page.inputValue("#phq9_score")).toBe("18");
    expect(await page.inputValue("#phq9_severity")).toBe("MODERATELY_SEVERE");
    expect(await page.inputValue("#gad7_score")).toBe("");
  });

  test("submit is guarded and logs", async ({ page }) => {
    const errors: string[] = [];
    page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
    const url = page.url();
    await page.click("#btn_submit");
    await page.waitForTimeout(100);
    expect(page.url()).toBe(url);
    expect(errors.some((e) => e.includes("[mock-ehr] SUBMIT"))).toBe(true);
  });

  test("the header's worker name and session id exist (profiler must not collect them)", async ({ page }) => {
    const text = await page.evaluate(() => document.body.innerText);
    expect(text).toContain("K. Loo");
    expect(text).toContain("2026-0917");
  });
});

test("bundle runs on the strict-CSP page", async ({ page }) => {
  await page.goto("/csp.html");
  const { inject, run } = await import("./helpers");
  await inject(page);
  expect(await run(page, { op: "ping" })).toMatchObject({ ok: true, result: { pong: true } });
  // Note: Playwright's evaluate bypasses page CSP. This proves the bundle has no CSP-hostile
  // code paths (no eval, no inline style/script injection), NOT that Safari's
  // `do JavaScript` bypasses CSP. Only the P1.1 spike can answer that.
});
