import { expect, test } from "@playwright/test";
import { inject, run } from "./helpers";

// Uses its own markup so each submit-shaped construct is tested in isolation.
const markup = `
  <form id="f" action="/submitted">
    <input id="name" name="name">
    <button id="typeless">Save</button>
    <button id="explicit" type="submit">Submit</button>
    <input id="img" type="image" alt="go">
    <input id="submit_input" type="submit" value="Go">
    <button id="safe" type="button">Add row</button>
    <div class="form-actions"><button id="draft" type="button">Save draft</button></div>
  </form>
  <a id="link" href="/elsewhere">Leave</a>
  <button id="outside">Outside form</button>`;

test.describe("submit guard", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/index.html");
    await page.setContent(markup);
    await page.evaluate(() => {
      (window as any).__submits = 0;
      document.getElementById("f")!.addEventListener("submit", (e) => { e.preventDefault(); (window as any).__submits++; });
    });
    await inject(page);
  });

  for (const id of ["typeless", "explicit", "img", "submit_input", "draft", "link"]) {
    test(`refuses #${id}`, async ({ page }) => {
      const state = await run(page, { op: "click", selector: `#${id}` });
      expect(state).toMatchObject({ ok: false, error: expect.stringContaining("submit_guard") });
      expect(await page.evaluate(() => (window as any).__submits)).toBe(0);
    });
  }

  for (const id of ["safe", "outside"]) {
    test(`allows #${id}`, async ({ page }) => {
      expect(await run(page, { op: "click", selector: `#${id}` })).toMatchObject({ ok: true });
    });
  }
});
