// Learn-form helper (P3.4): elements that probably name whose record is open, so the worker
// can pick the client banner instead of writing a selector. Runs only when the worker asks to
// learn this tab. Returns text to the worker's own screen; it never leaves the Mac.

import { cssId, xpathOf } from "./dom";
import { isGeneratedId } from "./profile";

export interface BannerCommand {
  op: "banner_candidates";
}

export interface BannerCandidate {
  selector: string;
  text: string;
}

/** Record-ID-looking tokens: AB-114322, MRN 00123456, 1234567. */
const ID_TOKEN = /\b[A-Z]{1,4}[- ]?\d{4,}\b|\bMRN\b|\b\d{6,}\b/i;
const HINT = /banner|header|patient|client|record|chart|demograph/i;

export function bannerCandidates(): BannerCandidate[] {
  const out: { el: Element; text: string; score: number }[] = [];
  for (const el of Array.from(document.body.querySelectorAll("*"))) {
    if (el.closest("form, [role=form], input, select, textarea, script, style, option, label")) continue;
    const text = (el.textContent ?? "").replace(/\s+/g, " ").trim();
    if (!text || text.length > 160 || !ID_TOKEN.test(text)) continue;
    // Keep the smallest element carrying the ID: skip one whose child already carries it.
    if (Array.from(el.children).some((c) => ID_TOKEN.test(c.textContent ?? ""))) continue;
    const rect = el.getBoundingClientRect();
    const hinted = HINT.test(`${el.id} ${el.className} ${el.getAttribute("role") ?? ""}`);
    // Near the top and marked like a banner scores higher; hidden elements don't count.
    if (rect.width === 0 && rect.height === 0) continue;
    const score = (hinted ? 2 : 0) + (rect.top < 200 ? 1 : 0) + (el.id ? 1 : 0);
    out.push({ el, text, score });
  }
  return out
    .sort((a, b) => b.score - a.score)
    .slice(0, 8)
    .map(({ el, text }) => ({ selector: selectorFor(el), text }));
}

function selectorFor(el: Element): string {
  if (el.id && !isGeneratedId(el.id)) return cssId(el.id);
  const testid = el.getAttribute("data-testid");
  if (testid) return `[data-testid="${testid.replace(/"/g, '\\"')}"]`;
  return `xpath=${xpathOf(el)}`;
}
