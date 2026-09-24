#!/usr/bin/env node
// Restyle labelled transcripts: same narrative, different conversation style.
//
// For each transcript with a truth.json (public data labelled by two teachers, or synthetic),
// DeepSeek rewrites HOW people talk (personalities, register, fillers, turn lengths, pacing,
// sometimes Spanish) and keeps WHAT is said: every fact, number, negation, hypothetical,
// correction and speaker, in order. A blind teacher then labels the rewrite; a label carries
// over only if the teacher reproduces the original's answer. So every training label is
// style-invariant by construction, which is what we want the classifier to be.
//
//   node tools/synth/restyle.mjs --dirs ~/Downloads/scribeski-gp-data/converted/aci --k 3 --out ~/Downloads/scribeski-gp-data/restyled
//   node tools/synth/restyle.mjs --dirs data/clinic/public/mts --k 1 --only-labelled --out data/clinic/restyled

import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "node:fs";
import { resolve, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { rng } from "./sample.mjs";
import { CLIENT_STYLE, WORKER_STYLE, SURFACE, applySurface } from "./scenarios.mjs";
import { TEACHER_SYSTEM, teacherUser, SCOPE, norm } from "./teacher.mjs";
import { FIELDS } from "./fields.mjs";
import { loadKey, makeClient, parseJSON } from "./gateway.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, xs) => {
  if (a.startsWith("--")) acc.push([a.slice(2), xs[i + 1] && !xs[i + 1].startsWith("--") ? xs[i + 1] : true]);
  return acc;
}, []));
const DIRS = String(args.dirs).split(",").map((d) => resolve(ROOT, d.replace(/^~/, process.env.HOME)));
if (!args.out) throw new Error("--out required (e.g. ~/Downloads/scribeski-gp-data/restyled for GP data)");
const OUT = resolve(ROOT, String(args.out).replace(/^~/, process.env.HOME));
const K = Number(args.k ?? 2);
const WRITER = args.writer ?? "deepseek/deepseek-v4-flash";
const TEACHER = args.teacher ?? "deepseek/deepseek-v4-flash";
const CONCURRENCY = Number(args.concurrency ?? 8);
const LIMIT = Number(args.limit ?? Infinity);
const ONLY_LABELLED = Boolean(args["only-labelled"]); // skip transcripts with no agreed non-blank label
if (OUT.startsWith(resolve(ROOT, "fixtures"))) throw new Error("refusing to write under fixtures/ (eval corpus)");

const REGISTER = ["casual and chatty", "formal and polite", "clipped and hurried", "warm and unhurried", "plain-spoken, working-class slang", "younger speakers, very informal"];

const SYSTEM = `You rewrite clinical conversations for training data. Everyone is fictional or anonymised.

KEEP THE NARRATIVE IDENTICAL:
- Every fact, number, date, time span, frequency, dose, name and place stays exactly as it is.
- Every negation, uncertainty, hypothetical ("if", "might", "thinking about"), past-vs-now distinction, correction, and "that's my sister, not me" stays exactly as it is.
- Who says what stays the same: WORKER lines stay WORKER, CLIENT lines stay CLIENT, and prefixes like "[family member]" or "[another clinician]" are kept on the lines that have them.
- Topics stay in the same order. Nothing is added, dropped, merged into a different fact, or resolved that was left unresolved.

CHANGE ONLY HOW IT'S SAID:
- Wording, sentence structure, fillers ("um", "you know", "I mean"), false starts, politeness, slang, turn length.
- You may split one turn into several lines by the same speaker, merge short consecutive lines by the same speaker, and add short backchannels that carry no information ("Mm-hm." "Okay." "Right.").

OUTPUT: only the conversation, one line per turn, "WORKER: ..." or "CLIENT: ...". No commentary, no markdown.`;

function styleFor(r, source) {
  return {
    client_style: r.pick(CLIENT_STYLE),
    worker_style: r.pick(WORKER_STYLE),
    register: r.pick(REGISTER),
    surface: r.weighted(SURFACE, [0.4, 0.35, 0.25]),
    wpm: r.int(70, 170),
    language: source === "mts" ? "en" : r.weighted(["en", "es"], [0.85, 0.15]),
  };
}

function stamp(lines, wpm, r) {
  let t = 4;
  return lines.map((l) => {
    const s = `[${String(Math.floor(t / 60)).padStart(2, "0")}:${String(Math.floor(t % 60)).padStart(2, "0")}] ${l}`;
    t += (l.split(/\s+/).length / wpm) * 60 + 0.3 + r.next() * 1.4;
    return s;
  });
}

async function restyle(client, dir, v) {
  const truth = JSON.parse(readFileSync(resolve(dir, "truth.json"), "utf8"));
  const source = truth.source ?? basename(dirname(dir));
  const origin = truth.origin ?? truth.id;
  const id = `${origin}-v${v}`;
  const out = resolve(OUT, source, id);
  if (existsSync(resolve(out, "truth.json"))) return null;
  const src = readFileSync(resolve(dir, "transcript.txt"), "utf8").split("\n").filter((l) => l && !l.startsWith("#"))
    .map((l) => l.replace(/^\[\d+:\d+\]\s*/, ""));
  const r = rng([...id].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7));
  const style = styleFor(r, source);
  const lang = style.language === "es"
    ? "Translate into Spanish as spoken by Mexican and Central American Californians, keeping the speaker labels WORKER/CLIENT in English. Names, numbers and medication names stay as they are."
    : "Keep it in English.";
  const user = `TARGET STYLE: the client is ${style.client_style}; the worker is ${style.worker_style}; overall register: ${style.register}. ${lang}\n\nCONVERSATION:\n${src.join("\n")}`;

  let lines;
  for (let attempt = 0; attempt < 2; attempt++) {
    const res = await client.chat({ model: WRITER, temperature: 0.9, max_tokens: 24000, messages: [{ role: "system", content: SYSTEM }, { role: "user", content: user }] });
    lines = res.content.split("\n").map((l) => l.trim()).filter((l) => /^(WORKER|CLIENT):\s*\S/.test(l));
    const ratio = lines.join(" ").split(/\s+/).length / src.join(" ").split(/\s+/).length;
    if (lines.length >= Math.min(4, src.length) && ratio > 0.5 && ratio < 1.9) break;
    lines = null;
  }
  if (!lines) throw new Error("rewrite length out of range twice");
  const shown = stamp(applySurface(lines, style.surface, r), style.wpm, r);

  // Blind teacher on the rewrite; keep only labels it reproduces.
  const t = await client.chat({ model: TEACHER, json: true, temperature: 0, max_tokens: 64000, reasoning: true,
    messages: [{ role: "system", content: TEACHER_SYSTEM }, { role: "user", content: teacherUser(shown, SCOPE) }] });
  const ans = parseJSON(t.content);
  const wantOf = (o) => (o.label == null || (Array.isArray(o.label) && !o.label.length) ? null : Array.isArray(o.label) ? [...o.label].sort() : String(o.label));
  const labels = {};
  const missed = [];
  for (const f of SCOPE) {
    const o = truth.labels?.[f];
    if (!o) continue;
    const got = norm(f, ans[f]?.a);
    const want = wantOf(o);
    const same = JSON.stringify(got) === JSON.stringify(want);
    labels[f] = { label: o.label, ...(o.acceptable && { acceptable: o.acceptable }), mode: "RESTYLED", origin_mode: o.mode, teacher: got, agree: Boolean(o.agree) && same };
    // The blind pass answering blank for a fact the original establishes is usually a teacher
    // miss, not a lost fact (checked by hand on the pilot). Verify those directly.
    if (o.agree && want != null && got == null) missed.push(f);
  }
  if (missed.length) {
    const facts = missed.map((f, i) => `${i + 1}. ${FIELDS[f] ? `${FIELDS[f].topic}: the client ${[].concat(wantOf(truth.labels[f])).map((v) => FIELDS[f].desc[v] ?? v).join("; ")}` : `${f} = ${wantOf(truth.labels[f])}`}`);
    const v2 = await client.chat({ model: TEACHER, json: true, temperature: 0, max_tokens: 16000, reasoning: true, messages: [{ role: "user", content:
      `Conversation:\n${shown.map((l, i) => `L${i + 1} ${l}`).join("\n")}\n\nFor each numbered statement, does the conversation clearly establish it as the client's current situation (or, for referrals/resources, what the worker did today)? Hypothetical, past, someone else's, or unresolved = no. Return JSON {"1": {"yes": true|false, "line": <line number or null>}, ...}.\n\n${facts.join("\n")}` }] });
    const chk = parseJSON(v2.content);
    missed.forEach((f, i) => {
      const c = chk[String(i + 1)] ?? {};
      if (c.yes === true && Number.isInteger(c.line) && c.line >= 1 && c.line <= shown.length) {
        labels[f].agree = true;
        labels[f].verified = `targeted L${c.line}`;
      }
    });
  }
  let kept = 0, candidates = 0;
  for (const f of Object.keys(labels)) {
    if (truth.labels[f].agree) candidates++;
    kept += labels[f].agree;
  }
  mkdirSync(out, { recursive: true });
  const header = ["# scribeski transcript fixture v1", "# session_date: 2026-01-01", "# started_at: 2026-01-01T10:00:00-08:00", "# modality: in_person",
    `# duration_minutes: ${Math.max(1, Math.round(shown.length ? (lines.join(" ").split(/\s+/).length / style.wpm) : 1))}`,
    `# note: RESTYLED from ${origin} (${source}${source === "synthetic" ? "" : ", see data/clinic/public/ATTRIBUTION.md"}); narrative kept, style changed`];
  writeFileSync(resolve(out, "transcript.txt"), [...header, ...shown].join("\n") + "\n");
  writeFileSync(resolve(out, "truth.json"), JSON.stringify({ schema: "scribeski.synth-truth/1", id, origin, source, variant: v, style, writer: WRITER, teacher: TEACHER,
    lines: shown.length, agreement: +(kept / Math.max(1, candidates)).toFixed(3), labels }, null, 1));
  console.log(`[${id}] ${style.language} ${style.surface} · kept ${kept}/${candidates} agreed labels`);
  return { kept, candidates };
}

const jobs = [];
for (const d of DIRS) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const dir = resolve(d, e.name);
    if (!existsSync(resolve(dir, "truth.json"))) continue;
    if (ONLY_LABELLED) {
      const t = JSON.parse(readFileSync(resolve(dir, "truth.json"), "utf8"));
      if (!Object.values(t.labels).some((v) => v.agree && v.label != null && !(Array.isArray(v.label) && !v.label.length))) continue;
    }
    for (let v = 1; v <= K; v++) jobs.push([dir, v]);
  }
}
jobs.splice(LIMIT);
console.log(`${jobs.length} variants to write (${WRITER}, teacher ${TEACHER}) → ${OUT}`);
const client = makeClient(loadKey(ROOT), { log: console.log });
let kept = 0, cand = 0, failed = 0;
await Promise.all(Array.from({ length: Math.min(CONCURRENCY, jobs.length) }, async () => {
  while (jobs.length) {
    const [d, v] = jobs.shift();
    try {
      const r = await restyle(client, d, v);
      if (r) { kept += r.kept; cand += r.candidates; }
    } catch (e) { failed++; console.error(`[${d} v${v}] FAILED: ${e.message}`); }
  }
}));
const u = client.usage;
console.log(`done: kept ${kept}/${cand} labels (${(100 * kept / Math.max(1, cand)).toFixed(1)}%), ${failed} failed; ${u.calls} calls${u.cost ? `, $${u.cost.toFixed(3)}` : ""}`);
