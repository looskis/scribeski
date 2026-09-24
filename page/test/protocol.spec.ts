import { expect, test } from "@playwright/test";
import { bundle, inject, run } from "./helpers";

test.describe("job protocol", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/index.html");
    await inject(page);
  });

  test("ping round-trips", async ({ page }) => {
    const state = await run(page, { op: "ping" });
    expect(state).toMatchObject({ done: true, ok: true, result: { pong: true } });
  });

  test("start returns immediately; async work is polled", async ({ page }) => {
    const started = JSON.parse(await page.evaluate(() => window.__scribeski!.start('{"op":"sleep","ms":300}')));
    const first = JSON.parse(await page.evaluate((id) => window.__scribeski!.poll(id), started.job));
    expect(first).toEqual({ done: false });
    const state = await run(page, { op: "sleep", ms: 50 });
    expect(state.result).toEqual({ slept: 50 });
  });

  test("a finished job is forgotten after delivery", async ({ page }) => {
    const started = JSON.parse(await page.evaluate(() => window.__scribeski!.start('{"op":"ping"}')));
    await page.waitForTimeout(50);
    const poll = (id: string) => page.evaluate((i) => JSON.parse(window.__scribeski!.poll(i)), id);
    expect((await poll(started.job)).ok).toBe(true);
    expect((await poll(started.job)).error).toBe("unknown_job");
  });

  test("errors come back as job results, not exceptions", async ({ page }) => {
    expect(await run(page, { op: "nope" })).toMatchObject({ done: true, ok: false, error: "unknown_op: nope" });
    expect(await run(page, { op: "fill", profile: { steps: [], fields: [] } })).toMatchObject({ ok: false, error: expect.stringContaining("bad_command") });
    const bad = await page.evaluate(() => window.__scribeski!.start("{not json"));
    expect(JSON.parse(bad)).toEqual({ error: "bad_json" });
  });

  test("re-injecting is a no-op (version guard)", async ({ page }) => {
    await page.evaluate(() => { (window as any).__before = window.__scribeski; });
    await inject(page);
    expect(await page.evaluate(() => (window as any).__before === window.__scribeski)).toBe(true);
    expect(await page.evaluate(() => Object.isFrozen(window.__scribeski))).toBe(true);
  });

  test("bundle contains no eval or new Function", () => {
    expect(bundle).not.toMatch(/\beval\s*\(|new\s+Function\s*\(/);
  });
});
