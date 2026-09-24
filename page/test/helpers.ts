import { readFileSync } from "node:fs";
import type { Frame, Page } from "@playwright/test";

export const bundle = readFileSync(new URL("../dist/scribeski-page.js", import.meta.url), "utf8");

/**
 * Injects the bundle the way the Safari transport does: evaluated as a script in the page's
 * main world, not as a <script> tag (which a strict CSP would block).
 */
export async function inject(target: Page | Frame): Promise<void> {
  await target.evaluate(bundle);
}

/** start + poll, as the Swift host will do over AppleScript. */
export async function run(target: Page | Frame, cmd: object, timeoutMs = 5000): Promise<any> {
  const started = JSON.parse(await target.evaluate((c) => window.__scribeski!.start(c), JSON.stringify(cmd)));
  if (started.error) throw new Error(started.error);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state = JSON.parse(await target.evaluate((id) => window.__scribeski!.poll(id), started.job));
    if (state.done) return state;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`job ${started.job} timed out`);
}

/** Loads a mock EHR page, waits for the risk iframe when there is one, and injects the bundle. */
export async function openMockEhr(page: Page, path = "/index.html"): Promise<void> {
  await page.goto(path);
  if (!path.startsWith("/csp.html")) {
    await page.frameLocator("#risk_frame").locator("#si_ideation").waitFor({ state: "attached" });
  }
  await inject(page);
}

/** Runs a command and returns its result, throwing the job's error if it failed. */
export async function ok(target: Page | Frame, cmd: object, timeoutMs = 15000): Promise<any> {
  const state = await run(target, cmd, timeoutMs);
  if (!state.ok) throw new Error(`job failed: ${state.error}`);
  return state.result;
}
