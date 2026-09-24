// Entry point. Installs window.__scribeski once per document. Re-injecting the same or an
// older version is a no-op, so the host can inject unconditionally before each command.
import { bannerCandidates } from "./banner";
import { rememberComboDefaults } from "./dom";
import { fill, focusField, readValues, undo } from "./fill";
import { guardedClick } from "./guard";
import { profile } from "./profile";
import { JobTable, type Command } from "./protocol";

declare const __SCRIBESKI_VERSION__: string;

export interface ScribeskiPage {
  version: string;
  start(cmdJSON: string): string;
  poll(id: string): string;
}

declare global {
  interface Window {
    __scribeski?: ScribeskiPage;
  }
}

function handle(cmd: Command): unknown {
  switch (cmd.op) {
    case "ping":
      return { pong: true, version: __SCRIBESKI_VERSION__, url: location.origin + location.pathname };
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
      throw new Error(`unknown_op: ${(cmd as { op: string }).op}`);
  }
}

function newer(a: string, b: string): boolean {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d > 0;
  }
  return false;
}

const existing = window.__scribeski;
if (!existing || newer(__SCRIBESKI_VERSION__, existing.version)) {
  const jobs = new JobTable(handle);
  const api: ScribeskiPage = {
    version: __SCRIBESKI_VERSION__,
    start: (cmdJSON) => jobs.start(cmdJSON),
    poll: (id) => jobs.poll(id),
  };
  Object.defineProperty(window, "__scribeski", { value: Object.freeze(api), configurable: true });
  // Comboboxes have no defaultValue; what they hold when we first arrive stands in for it.
  rememberComboDefaults();
}
