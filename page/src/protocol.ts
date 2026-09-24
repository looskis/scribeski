// Job protocol. AppleScript `do JavaScript` returns synchronously and won't await a
// Promise, so every command returns a job id at once and the caller polls.
// All inputs and outputs are JSON strings: that's what survives the AppleScript bridge.

import type { BannerCommand } from "./banner";
import type { FillCommand, FocusCommand, UndoCommand } from "./fill";
import type { FormProfile } from "./types";

export type Command =
  | { op: "ping" }
  | { op: "sleep"; ms: number }
  | { op: "profile" }
  | FillCommand
  | UndoCommand
  | FocusCommand
  | BannerCommand
  | { op: "read_values"; profile: FormProfile }
  | { op: "click"; selector: string };

export type JobState =
  | { done: false }
  | { done: true; ok: true; result: unknown }
  | { done: true; ok: false; error: string };

export type Handler = (cmd: Command) => unknown | Promise<unknown>;

export class JobTable {
  private next = 1;
  private jobs = new Map<string, JobState>();

  constructor(private readonly handle: Handler) {}

  start(cmdJSON: string): string {
    let cmd: Command;
    try {
      cmd = JSON.parse(cmdJSON) as Command;
    } catch {
      return JSON.stringify({ error: "bad_json" });
    }
    const id = `j${this.next++}`;
    this.jobs.set(id, { done: false });
    Promise.resolve()
      .then(() => this.handle(cmd))
      .then(
        (result) => this.jobs.set(id, { done: true, ok: true, result }),
        (err: unknown) => this.jobs.set(id, { done: true, ok: false, error: errorMessage(err) }),
      );
    return JSON.stringify({ job: id });
  }

  /** Returns the job state. A finished job is forgotten once its result is delivered. */
  poll(id: string): string {
    const state = this.jobs.get(id);
    if (!state) return JSON.stringify({ done: true, ok: false, error: "unknown_job" });
    if (state.done) this.jobs.delete(id);
    return JSON.stringify(state);
  }

  get pending(): number {
    return [...this.jobs.values()].filter((j) => !j.done).length;
  }
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
