#!/usr/bin/env node
// Teacher labels for public transcripts (~/Downloads/scribeski-gp-data/converted/<source>/<id>/transcript.txt).
//
// No sheet exists for real data, so the check is two blind teachers from different model
// families. A label is trusted for training only where they agree (same rule as synthetic:
// two independent sources). Writes truth.json in the synthetic schema, mode "REAL".
//
//   node tools/synth/label_public.mjs --dirs ~/Downloads/scribeski-gp-data/converted/primock57,... [--limit 20]

import { readFileSync, writeFileSync, existsSync, readdirSync, appendFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { FIELDS } from "./fields.mjs";
import { TEACHER_SYSTEM, teacherUser, SCOPE, BLANKISH, norm } from "./teacher.mjs";
import { loadKey, makeClient, parseJSON } from "./gateway.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, xs) => {
  if (a.startsWith("--")) acc.push([a.slice(2), xs[i + 1] && !xs[i + 1].startsWith("--") ? xs[i + 1] : true]);
  return acc;
}, []));
if (!args.dirs) throw new Error("--dirs required: the GP data now lives outside the repo (e.g. ~/Downloads/scribeski-gp-data/converted/aci)");
const DIRS = String(args.dirs).split(",").map((d) => resolve(ROOT, d.replace(/^~/, process.env.HOME)));
const TEACHERS = String(args.teachers ?? "deepseek/deepseek-v4-flash,openai/gpt-oss-120b").split(",");
const CONCURRENCY = Number(args.concurrency ?? 8);
const LIMIT = Number(args.limit ?? Infinity);

async function label(client, dir) {
  const lines = readFileSync(resolve(dir, "transcript.txt"), "utf8").split("\n").filter((l) => l && !l.startsWith("#"));
  const answers = [];
  for (const model of TEACHERS) {
    const r = await client.chat({ model, json: true, temperature: 0, max_tokens: 64000, reasoning: true,
      messages: [{ role: "system", content: TEACHER_SYSTEM }, { role: "user", content: teacherUser(lines, SCOPE) }] });
    answers.push(parseJSON(r.content));
  }
  const labels = {};
  let ok = 0;
  for (const f of SCOPE) {
    const [a, b] = answers.map((x) => norm(f, x[f]?.a));
    const agree = JSON.stringify(a) === JSON.stringify(b);
    ok += agree;
    labels[f] = { label: agree ? a : null, mode: "REAL", teacher_a: a, teacher_b: b, agree,
      ...(agree && a == null && BLANKISH[f] && { acceptable: [null, BLANKISH[f][0]] }) };
  }
  const id = dir.split("/").slice(-2).join("/");
  const truth = { schema: "scribeski.synth-truth/1", id: id.replace("/", "-"), source: id.split("/")[0], teachers: TEACHERS,
    lines: lines.length, agreement: +(ok / SCOPE.length).toFixed(3), labels };
  writeFileSync(resolve(dir, "truth.json"), JSON.stringify(truth, null, 1));
  const filled = Object.values(labels).filter((v) => v.agree && v.label != null).length;
  console.log(`[${id}] agreement ${truth.agreement}, ${filled} agreed non-blank labels`);
  return truth;
}

const todo = DIRS.flatMap((d) => readdirSync(d, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => resolve(d, e.name)))
  .filter((d) => !existsSync(resolve(d, "truth.json"))).slice(0, LIMIT);
console.log(`${todo.length} transcripts to label with ${TEACHERS.join(" + ")}`);
const client = makeClient(loadKey(ROOT), { log: console.log });
const failures = [];
await Promise.all(Array.from({ length: Math.min(CONCURRENCY, todo.length) }, async () => {
  while (todo.length) {
    const d = todo.shift();
    try { await label(client, d); } catch (e) { failures.push(d); console.error(`[${d}] FAILED: ${e.message}`); }
  }
}));
const u = client.usage;
console.log(`done. ${u.calls} calls, ${u.prompt} prompt tok, ${u.completion} completion tok${u.cost ? `, $${u.cost.toFixed(3)}` : ""}; ${failures.length} failed`);
