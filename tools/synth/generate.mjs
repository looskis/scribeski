#!/usr/bin/env node
// Synthetic session generator for the classifier tier (BUILD_PLAN P1.9 step 2).
//
//   node tools/synth/generate.mjs --n 4 --out data/synth/pilot            # generate
//   node tools/synth/generate.mjs --n 4 --dry                             # sheets + briefs only, no API
//   node tools/synth/generate.mjs --check                                 # fields.mjs vs FIELDS.md
//
// Pipeline per session:
//   1. sample.mjs draws the ground truth (values + disclosure modes). Labels come from here.
//   2. DeepSeek writes a persona consistent with the established facts.
//   3. DeepSeek writes the dialogue one ~7-minute segment at a time, from a brief that says
//      what to establish, how, and what must never come up.
//   4. A blind DeepSeek pass re-extracts every field from the finished transcript. A label is
//      trusted for training only when the sampled truth and the blind read agree.
//
// Synthetic text only. Output never goes under fixtures/ — that corpus is for eval.

import { mkdirSync, writeFileSync, readFileSync, existsSync, appendFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { FIELDS, ITEM_TEXT, ITEM_ANCHORS, SECTIONS } from "./fields.mjs";
import { sampleSheet, rng, segmentOf } from "./sample.mjs";
import { householdText, applySurface } from "./scenarios.mjs";
import { TEACHER_SYSTEM, teacherUser } from "./teacher.mjs";
import { loadKey, makeClient, parseJSON } from "./gateway.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// ---- CLI ---------------------------------------------------------------------------------
const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, xs) => {
    if (a.startsWith("--")) acc.push([a.slice(2), xs[i + 1] && !xs[i + 1].startsWith("--") ? xs[i + 1] : true]);
    return acc;
  }, []),
);
const N = Number(args.n ?? 1);
const SEED = Number(args.seed ?? Date.now() % 1e6);
const OUT = resolve(ROOT, args.out ?? `data/synth/run-${SEED}`);
// v4-flash: works on the gateway free tier and is ~5× cheaper; try v4-pro once on paid credits.
const WRITERS = String(args.writers ?? args.writer ?? "deepseek/deepseek-v4-flash").split(",");
const TEACHER = args.teacher ?? "deepseek/deepseek-v4-flash";
const CONCURRENCY = Number(args.concurrency ?? 4);
const BALANCE = Number(args.balance ?? 0.5);
const HARD = Number(args.hard ?? 1);
const FALLBACK = args.fallback ?? "deepseek/deepseek-v4-flash";
const ENDPOINT = args.endpoint ?? "https://ai-gateway.vercel.sh/v1/chat/completions";
const PROVIDER = args.provider ?? (ENDPOINT.includes("vercel") ? "gateway" : "vllm");
const KEY_ENV = args["key-env"] ?? (PROVIDER === "gateway" ? "AI_GATEWAY_API_KEY" : "NONE");

if (OUT.startsWith(resolve(ROOT, "fixtures"))) throw new Error("refusing to write training data under fixtures/ (eval corpus)");

// ---- plain-language descriptions ---------------------------------------------------------
const thirdParty = (d) => `someone in the client's life (a named family member, partner or friend) — not the client — is the one this is true of: "${d}"; make clear it's about them`;
const descOf = (field, v) => (Array.isArray(v) ? v.map((x) => FIELDS[field].desc[x]).join("; ") : FIELDS[field].desc[v]);

function itemLine(f) {
  const [inst, n] = f.field.split("_");
  const name = `${inst === "phq9" ? "PHQ-9" : "GAD-7"} item ${n} ("${ITEM_TEXT[f.field]}")`;
  const a = ITEM_ANCHORS[f.value];
  switch (f.mode) {
    case "STATED": return `${name}: client answers "${a.words}" (or its number, ${f.value}, after the worker reads the 0–3 scale).`;
    case "INDIRECT": return `${name}: client answers in their own words — e.g. "${f.phrase ?? a.days}" (that means ${a.days}) — not the scale wording; the worker accepts it without restating a category.`;
    case "CORRECTED": return `${name}: client first says "${ITEM_ANCHORS[f.initial].words}", then corrects themselves to "${a.words}".`;
    case "MISREFLECTED": return `${name}: client answers "${a.words}"; the worker repeats it back as "${ITEM_ANCHORS[f.initial].words}"; the client corrects the worker to "${a.words}".`;
  }
}

function factLine(f, phase) {
  if (/^(phq9|gad7)_\d$/.test(f.field)) return itemLine(f);
  const spec = FIELDS[f.field];
  const topic = spec.topic;
  if (spec.kind === "checkbox") {
    const truth = `"${descOf(f.field, f.value)}"`;
    const base = `${topic} — truth: ${truth}. Establish it plainly.`;
    switch (f.mode) {
      case "INDIRECT": return `${topic} — truth: ${truth}. Convey it only through concrete details, never the category names.`;
      case "PASSING": return `${topic} — truth: ${truth}. Let it come out ONLY in passing (an aside, or a detail inside a story about something else). The worker never asks about it, never confirms it, and never summarizes it.`;
      case "HYPOTHETICAL": return `${base} Separately, "${spec.desc[f.decoy]}" comes up ONLY as a possibility or conditional ("if…", "might", "thinking about") — it is not true now.`;
      case "THIRD_PARTY": return `${base} Separately, ${thirdParty(spec.desc[f.decoy])}.`;
      case "PAST": return `${base} Separately, "${spec.desc[f.decoy]}" was true in the past but isn't anymore ("used to…", "ran out", "stopped", "not since…").`;
      case "PENDING":
        if (f.field === "referrals_made") return `${base} Separately, the worker follows up on a referral from an EARLIER visit ("${spec.desc[f.decoy]}" — already made before, just checking how it went); it is not a new referral today.`;
        return `${base} Separately, the client has applied for / is still waiting on this, not receiving it yet: "${spec.desc[f.decoy]}".`;
      case "CORRECTED":
        if (phase === "first") return `${topic} — the client first says: "${descOf(f.field, f.initial)}". (A slip, corrected later in the session — don't correct it now.)`;
        if (phase === "second") return `${topic} — the client corrects something said earlier: "${spec.desc[f.decoy]}" is not actually true. The truth is ${truth}.`;
        return `${topic} — the client first says: "${descOf(f.field, f.initial)}", then corrects it: "${spec.desc[f.decoy]}" isn't actually true. The truth is ${truth}.`;
      default: return base;
    }
  }
  const d = (v) => `"${spec.desc[v]}"`;
  const extra = [f.household && householdText(f.household), f.detail && `concretely: ${f.detail}`].filter(Boolean).join("; ");
  const t = (v) => `${d(v)}${extra ? ` (${extra})` : ""}`;
  const dd = (v, det) => `${d(v)}${det ? ` (concretely: ${det})` : ""}`;
  switch (f.mode) {
    case "STATED": return `${topic} — truth: ${t(f.value)}. Establish it plainly.`;
    case "INDIRECT": return `${topic} — truth: ${t(f.value)}. Convey it only indirectly, through concrete details a listener must interpret; never use the category words.`;
    case "PASSING": return `${topic} — truth: ${t(f.value)}. Let it come out ONLY in passing: an aside, or a detail inside a story about something else ("my wife gets on me about it", "after my shift"). The worker never asks about it, never confirms it, and never summarizes it.`;
    case "UNFIT": return `${topic} — the client describes current thoughts of killing themselves (active suicidal ideation). The worker does NOT ask about a plan or a method, and nothing said settles whether there is one.`;
    case "PAST": return `${topic} — in the past: ${dd(f.decoy, f.decoy_detail)}; that is no longer true ("used to…", "not since…"). ${f.current_stated ? `Now, the truth is ${t(f.value)} — establish it.` : "What's true NOW is never established."}`;
    case "CORRECTED":
      if (phase === "first") return `${topic} — the client says something that means ${dd(f.initial, f.initial_detail)}. (A slip, corrected later in the session — don't correct it now.)`;
      if (phase === "second") return `${topic} — the client corrects what they said earlier; the truth is ${t(f.value)}.`;
      return `${topic} — the client first says something that means ${dd(f.initial, f.initial_detail)}, then corrects it; the truth is ${t(f.value)}.`;
    case "MISREFLECTED": return `${topic} — truth: ${t(f.value)}. The client says so; the worker reflects it back wrongly as ${dd(f.initial, f.initial_detail)}; the client corrects the worker.`;
    case "HYPOTHETICAL": return `${topic} — ${dd(f.decoy, f.decoy_detail)} comes up ONLY as a hypothetical, conditional or future possibility. The actual current situation on this is never established.`;
    case "THIRD_PARTY": return `${topic} — ${thirdParty(spec.desc[f.decoy] + (f.decoy_detail ? ` — ${f.decoy_detail}` : ""))}. The client's own situation on this is never established.`;
    case "AMBIGUOUS": return `${topic} — it comes up, but it stays genuinely unresolved between ${d(f.between[0])} and ${d(f.between[1])}. Nobody settles it.`;
    case "DECLINED": return `${topic} — the worker asks; the client declines to answer, and the worker respects that and moves on.`;
  }
}

function mutateDigits(r, s) {
  const idx = [...s].map((c, i) => (/\d/.test(c) ? i : -1)).filter((i) => i >= 0);
  const i = r.pick(idx.slice(-4));
  const c = String((Number(s[i]) + r.int(1, 8)) % 10);
  return s.slice(0, i) + c + s.slice(i + 1);
}

const fmtPhone = (p) => `(${p.slice(0, 3)}) ${p.slice(3, 6)}-${p.slice(6)}`;

// ---- briefs ------------------------------------------------------------------------------
function neverTopics(sheet) {
  const T = sheet.text;
  const never = [];
  for (const f of sheet.facts) {
    if (f.mode !== "NOT_DISCUSSED" || /^(phq9|gad7)_\d$/.test(f.field)) continue;
    never.push(FIELDS[f.field].topic);
  }
  if (sheet.instruments.phq9 === "NONE") never.push("the PHQ-9 depression questionnaire");
  if (sheet.instruments.gad7 !== "COMPLETED") never.push("asking the GAD-7 anxiety questions (the worker may only say what the brief says about it)");
  if (!sheet.risk_asked) never.push("suicide, self-harm, wanting to die, harming others, safety plans, crisis lines");
  const labels = { case_number: "the case number", client_dob: "the client's date of birth or exact age", contact_phone: "the client's phone number", address_zip: "the client's address or ZIP code", insurance_member_id: "an insurance member ID", emergency_contact_phone: "an emergency contact's phone number" };
  for (const k of Object.keys(labels)) if (!T[k].discussed) never.push(labels[k]);
  return [...new Set(never)];
}

function buildBriefs(sheet, persona) {
  const r = rng(sheet.seed ^ 0x5eed);
  const n = sheet.segments;
  const briefs = Array.from({ length: n }, () => ({ facts: [], identity: [], extra: [] }));

  for (const f of sheet.facts) {
    if (f.mode === "NOT_DISCUSSED") continue;
    if (f.mode === "CORRECTED" && f.correction_segment != null) {
      briefs[f.segment].facts.push(factLine(f, "first"));
      briefs[f.correction_segment].facts.push(factLine(f, "second"));
    } else briefs[f.segment].facts.push(factLine(f));
    if (f.revisit_segment != null && f.revisit_segment !== f.segment && FIELDS[f.field]) {
      briefs[f.revisit_segment].facts.push(`${FIELDS[f.field].topic} — comes up again in passing, consistent with what was already said; add nothing new.`);
    }
  }

  // Instruments: say how they're administered, once, where they start.
  const phq = sheet.facts.filter((f) => f.field.startsWith("phq9_") && /\d$/.test(f.field) && f.mode !== "NOT_DISCUSSED");
  if (phq.length) {
    const seg = phq[0].segment;
    const how = { FULL: "all nine PHQ-9 items", PARTIAL: `PHQ-9 items 1–${sheet.instruments.phq9_items} only — then stops (give a natural reason: time, client getting upset, a phone interruption) and does NOT ask the rest`, PHQ2: "only the first two PHQ-9 items (the PHQ-2) and no others" }[sheet.instruments.phq9];
    briefs[seg].extra.push(`The worker administers ${how}, in order, reading each item for the past two weeks. Answers below.`);
  }
  if (sheet.instruments.gad7 === "COMPLETED") briefs[sheet.facts.find((f) => f.field === "gad7_1").segment].extra.push("The worker then administers all seven GAD-7 items, in order, for the past two weeks. Answers below.");

  // Identity details (text fields; exact values so they can be checked later).
  const idSeg = segmentOf(1, n);
  const T = sheet.text;
  const say = (key, label, value) => {
    const t = T[key];
    if (!t?.discussed) return;
    if (t.corrected) {
      const wrong = key === "case_number" ? t.value.slice(0, 3) + mutateDigits(r, t.value.slice(3))
        : key === "client_dob" ? `${Number(value.slice(0, 4)) + r.pick([-2, -1, 1, 2])}${value.slice(4)}`
        : mutateDigits(r, value);
      t.said_first = wrong;
      if (t.correction_segment != null && t.correction_segment !== idSeg) {
        briefs[idSeg].identity.push(`${label}: the client gives it as ${wrong} (a slip — corrected later, not now).`);
        briefs[t.correction_segment].identity.push(`${label}: the client realises they gave it wrong earlier; the correct one is ${value}.`);
      } else briefs[idSeg].identity.push(`${label}: the client first gives ${wrong}, then corrects it to ${value}.`);
    } else briefs[idSeg].identity.push(`${label}: ${value}.`);
  };
  if (sheet.session_type === "INTAKE") briefs[idSeg].identity.push(`Legal name: ${persona.client_first_name} ${persona.client_last_name}${persona.preferred_name ? `; goes by ${persona.preferred_name}` : ""}.`);
  say("client_dob", "Date of birth", T.client_dob.value);
  say("contact_phone", "Phone", fmtPhone(T.contact_phone.value));
  say("address_zip", "Home ZIP code", T.address_zip.value);
  if (T.address_zip.discussed) briefs[idSeg].identity.push(`Street and city: ${persona.street_address}, ${persona.city}.`);
  say("insurance_member_id", "Insurance member ID", T.insurance_member_id.value);
  if (T.emergency_contact_phone.discussed) briefs[idSeg].identity.push(`Emergency contact: ${persona.emergency_contact_name}, phone ${fmtPhone(T.emergency_contact_phone.value)}.`);
  say("case_number", "Case number (on the client's referral letter; the worker confirms it)", T.case_number.value);

  const segOf = (s) => segmentOf(s, n);
  briefs[segOf(3)].extra.push(`Health details to mention: primary care doctor ${persona.pcp_name}; medications: ${persona.medications.length ? persona.medications.join(", ") : "none"}; medical conditions: ${persona.medical_conditions || "none"}; usually sleeps about ${persona.sleep_hours} hours a night.`);
  briefs[segOf(0)].extra.push(`At some point the client describes their mood in their own words, e.g. "${persona.mood_words}".`);
  briefs[n - 1].extra.push(`Near the end the client states a goal in their own words: "${persona.client_goal}".`);
  if (T.next_appointment.discussed) briefs[n - 1].extra.push(`They set the next appointment for ${T.next_appointment.value}.`);
  briefs[n - 1].extra.push("This is the final segment: close the session naturally.");
  for (const t of sheet.temptations) briefs[r.int(0, n - 1)].extra.push(`Include this moment: ${t}.`);

  const never = neverTopics(sheet);

  // Topics reserved for later segments must not come up early.
  const later = (i) => [...new Set(sheet.facts.filter((f) => f.mode !== "NOT_DISCUSSED" && f.segment > i && !/^(phq9|gad7)_/.test(f.field)).map((f) => FIELDS[f.field].topic))];

  return briefs.map((b, i) => ({ ...b, never: [...new Set(never)], later: later(i) }));
}

// ---- prompts -----------------------------------------------------------------------------
const WRITER_SYSTEM = `You write realistic dialogue for synthetic training data: a behavioural-health session between a county social worker (WORKER) and a client (CLIENT), as captured by streaming speech recognition. Everyone and everything is fictional. Phone numbers use 555-01xx.

OUTPUT FORMAT — exactly this, nothing else:
WORKER: <utterance>
CLIENT: <utterance>
…one utterance per line, speaker label first. No stage directions, no timestamps, no markdown.
Then one line "=== SUMMARY ===" followed by at most 120 words: the facts established so far in the whole session and where the conversation stands.

REALISM
- Real speech, measured on real counselling transcripts — aim for these proportions:
  · about 1 line in 3 is a very short turn of 1–3 words ("Mm-hm." "Yeah." "Okay." "Right, right." "No.")
  · about 4 lines in 10 contain a filler or false start ("um", "uh", "like", "you know", "I mean", "it's — it's")
  · turn length is uneven: most lines are short, but some client turns run 40–60 words when they get into a story
- Also: self-interruptions, tangents, small talk, occasional mishearing or "sorry, say that again".
- The worker sounds like a real clinician: open questions, reflections, validation, summaries — not a form being read out (except questionnaire items, which are read).
- The worker never says field names or form codes. The client never talks in form categories unless the brief says to.
- Most of each segment is ordinary conversation around the facts: feelings, stories, context. Facts are woven in, not listed.

TRUTH DISCIPLINE — this is labelled data; these rules outrank realism:
1. Establish every item in the brief exactly as specified, including its manner (indirect, corrected later, hypothetical, about someone else, unresolved, declined).
2. NEVER establish or imply anything on the "never mention" list, not even in passing. If the conversation drifts there, steer away.
3. Don't raise topics listed for later segments.
4. Don't add facts about form topics beyond the brief. Colour unrelated to the form (weather, TV, a neighbour's noise) is fine.
5. The worker never states a risk level, diagnosis, mental-status findings or level of care, and never says a supervisor was consulted — unless the brief includes that moment.
6. Continue seamlessly from the previous lines. Don't re-greet. Only the final segment closes the session.`;

const STRUCTURE_NOTE = {
  sectioned: "Topics follow a fairly normal intake order.",
  interleaved: "Conversation drifts: topics come up out of order and get picked back up later.",
  "client-led": "The client drives: they bring things up before the worker asks, and the worker circles back to confirm.",
};

function writerUser(sheet, persona, brief, i, prevTail, summary) {
  const lang = sheet.language === "es"
    ? "Write the dialogue in Spanish as spoken by Mexican and Central American Californians (the worker is bilingual). Keep the speaker labels WORKER/CLIENT and the summary in English."
    : "Write the dialogue in English.";
  const words = Math.round((sheet.duration_min * sheet.wpm) / sheet.segments);
  return [
    `SESSION: ${sheet.session_type.toLowerCase().replace("_", "-")} by ${sheet.modality.toLowerCase().replace("_", " ")}, ${sheet.duration_min} minutes total. ${lang}`,
    sheet.scenario ? `STYLE: setting — ${sheet.scenario.setting}. The client is ${sheet.scenario.client_style}. The worker is ${sheet.scenario.worker_style}. ${STRUCTURE_NOTE[sheet.scenario.structure]}` : "",
    `PERSONA:\n${JSON.stringify({ worker: persona.worker_name, client: `${persona.client_first_name} ${persona.client_last_name}`, age: sheet.age_years, preferred_name: persona.preferred_name, backstory: persona.backstory, people: persona.people, texture: persona.texture }, null, 1)}`,
    summary ? `STORY SO FAR:\n${summary}` : "",
    prevTail ? `LAST LINES:\n${prevTail}` : "This is the start of the session.",
    `THIS IS SEGMENT ${i + 1} OF ${sheet.segments}. Length: ${Math.round(words * 0.9)}–${Math.round(words * 1.1)} words of dialogue (about ${Math.round(sheet.duration_min / sheet.segments)} minutes of real talk). Stay inside that range.`,
    `ESTABLISH IN THIS SEGMENT:\n${[...brief.extra, ...brief.identity, ...brief.facts].map((x) => `- ${x}`).join("\n") || "- (nothing specific: deepen rapport and context around what's already been said)"}`,
    brief.later.length ? `LATER SEGMENTS WILL COVER (don't raise yet): ${brief.later.join("; ")}.` : "",
    `FILLER, when you need more talk: the presenting problem, feelings, how the week went emotionally, relationships' emotional side (not who lives where), coping skills, therapy homework, small talk. Never use a never-mention topic as filler.`,
    `NEVER MENTION OR IMPLY (whole session — check every line against this before you write it): ${brief.never.join("; ") || "(none)"}.`,
  ].filter(Boolean).join("\n\n");
}

function personaPrompt(sheet, never) {
  const established = sheet.facts
    .filter((f) => f.label != null && FIELDS[f.field] && !/^(phq9|gad7)_/.test(f.field) && f.mode !== "DECLINED")
    .map((f) => `- ${FIELDS[f.field].topic}: the client ${descOf(f.field, f.label)}`)
    .join("\n");
  const adherence = sheet.facts.find((f) => f.field === "medication_adherence")?.label;
  const home = sheet.facts.find((f) => f.household)?.household;
  const sc = sheet.scenario;
  return `Invent a fictional client and worker for a synthetic behavioural-health session. Session: ${sheet.session_type}, client age ${sheet.age_years}, ${sheet.language === "es" ? "Spanish-speaking Latino/a client" : "English-speaking client of any background"}, California. PHQ-9 severity is roughly ${sheet.instruments.phq9 === "NONE" ? "unknown" : "consistent with the answers the session will give"}.
${sc ? `Why they're here: ${sc.presenting}. Setting: ${sc.setting}. The client is ${sc.client_style}.` : ""}
${home ? `Household (use exactly this; these people go in "people"): ${householdText(home)}.` : "Where and with whom the client lives is NOT established: \"people\" notes must not say who lives with the client."}

Facts that WILL be established (the backstory must be consistent with them):
${established || "- (few)"}

The backstory, people notes and texture must NOT mention or imply anything about: ${never.join("; ")}. Also don't settle anything else about housing, household, work, income, food, transport, legal matters, children at home, substances, medication-taking, supports or suicidal thoughts beyond the facts above. Build the story from other material: the presenting problem, feelings, relationships' emotional content, recent events, personality.
${adherence === "NONE_PRESCRIBED" ? "The client takes no prescribed medications." : ""}

Return JSON:
{"worker_name": "first name + last initial, with a title like ASW or LCSW",
 "client_first_name": "", "client_last_name": "", "preferred_name": null or "a nickname",
 "street_address": "number + street + optional unit", "city": "fictional or small real CA city",
 "emergency_contact_name": "full name",
 "pcp_name": "Dr. + surname",
 "medications": ["name dose frequency", ...] (empty list if none prescribed),
 "medical_conditions": "comma-separated or empty",
 "sleep_hours": "a number like 5 or 6-7",
 "mood_words": "how the client would describe their mood, in their own vivid words",
 "client_goal": "a goal in the client's own words",
 "backstory": "120-180 words: why they're here now, recent events, personality, how they talk",
 "people": [{"name": "", "relation": "", "note": ""}] (3-5 people in their life, useful for third-party mentions),
 "texture": ["3 incidental details: a pet, a hobby, a TV show, a noisy neighbour..."]}`;
}

// ---- assembly ----------------------------------------------------------------------------
function parseSegment(text) {
  const [body, summary = ""] = text.split(/^=== ?SUMMARY ?===\s*$/m);
  const lines = body.split("\n").map((l) => l.trim()).filter((l) => /^(WORKER|CLIENT):\s*\S/.test(l));
  return { lines, summary: summary.trim() };
}

function stamp(lines, wpm, r) {
  let t = 4;
  const out = [];
  for (const l of lines) {
    const mm = String(Math.floor(t / 60)).padStart(2, "0");
    const ss = String(Math.floor(t % 60)).padStart(2, "0");
    out.push(`[${mm}:${ss}] ${l}`);
    const words = l.split(/\s+/).length - 1;
    t += (words / wpm) * 60 + 0.3 + r.next() * 1.6;
  }
  return { lines: out, seconds: t };
}

function agree(f, answer) {
  const accept = f.acceptable ?? [f.label];
  if (FIELDS[f.field]?.kind === "checkbox") {
    const got = Array.isArray(answer) ? [...answer].sort() : answer == null ? [] : [answer];
    const want = f.label ?? [];
    return got.length === want.length && got.every((x, i) => x === want[i]);
  }
  const a = answer == null || answer === "" ? null : String(answer);
  return accept.some((x) => (x == null ? a == null : a === String(x)));
}

// ---- one session -------------------------------------------------------------------------
async function runSession(client, seed, idx) {
  const id = `s${String(idx).padStart(4, "0")}-${seed}`;
  const dir = resolve(OUT, id);
  if (existsSync(resolve(dir, "truth.json"))) return { id, skipped: true };
  mkdirSync(dir, { recursive: true });
  const r = rng(seed ^ 0xda7e);
  const sheet = sampleSheet(seed, { balance: BALANCE, hard: HARD, minutes: args.minutes ? Number(args.minutes) : undefined, language: args.lang });
  const start = new Date(Date.UTC(2026, 9, 1) + r.int(0, 150) * 86400e3);
  const session_date = start.toISOString().slice(0, 10);
  const fu = sheet.facts.find((f) => f.field === "follow_up_interval")?.label;
  const days = { WEEKLY: 7, BIWEEKLY: 14, MONTHLY: 28 }[fu] ?? r.pick([7, 14, 21]);
  sheet.text.next_appointment.value = new Date(start.getTime() + days * 86400e3).toISOString().slice(0, 10);
  writeFileSync(resolve(dir, "sheet.json"), JSON.stringify(sheet, null, 1));

  const log = (m) => console.log(`[${id}] ${m}`);
  let WRITER = WRITERS[idx % WRITERS.length]; // round-robin: every writer gets every kind of session
  const writersUsed = [WRITER];
  // Some providers hard-reject (HTTP 400) particular mid-session requests (seen with Hy4-preview's
  // content filter). Finish that session with the fallback writer instead of losing it.
  const write = async (opts) => {
    try { return await client.chat({ model: WRITER, ...opts }); }
    catch (e) {
      if (!String(e.message).startsWith("HTTP 400") || WRITER === FALLBACK) throw e;
      log(`${WRITER} rejected a request (${String(e.message).slice(0, 60)}…); continuing with ${FALLBACK}`);
      WRITER = FALLBACK;
      writersUsed.push(WRITER);
      return await client.chat({ model: WRITER, ...opts });
    }
  };
  log(`${sheet.session_type} ${sheet.modality} ${sheet.duration_min}min ${sheet.language} ${sheet.segments} segments · ${WRITER} · ${sheet.scenario?.structure}/${sheet.scenario?.surface}`);

  const persona = parseJSON((await write({ json: true, temperature: 1.0, max_tokens: 16000, messages: [{ role: "user", content: personaPrompt(sheet, neverTopics(sheet)) }] })).content);
  persona.people ??= [];
  persona.medications ??= [];
  writeFileSync(resolve(dir, "persona.json"), JSON.stringify(persona, null, 1));

  const briefs = buildBriefs(sheet, persona);
  writeFileSync(resolve(dir, "briefs.json"), JSON.stringify(briefs, null, 1));

  const all = [];
  let summary = "";
  for (let i = 0; i < sheet.segments; i++) {
    const messages = [
      { role: "system", content: WRITER_SYSTEM },
      { role: "user", content: writerUser(sheet, persona, briefs[i], i, all.slice(-30).join("\n"), summary) },
    ];
    const { content, finish } = await write({ messages, temperature: 0.9, max_tokens: 12000 });
    const seg = parseSegment(content);
    if (seg.lines.length < 10) throw new Error(`segment ${i + 1}: only ${seg.lines.length} lines (finish=${finish})`);
    all.push(...seg.lines);
    summary = seg.summary || summary;
    log(`segment ${i + 1}/${sheet.segments}: ${seg.lines.length} lines`);
  }

  const surfaced = sheet.scenario ? applySurface(all, sheet.scenario.surface, rng(seed ^ 0x5af)) : all;
  const { lines, seconds } = stamp(surfaced, sheet.wpm, r);
  const header = [
    "# scribeski transcript fixture v1",
    `# session_date: ${session_date}`,
    `# started_at: ${session_date}T10:00:00-07:00`,
    `# modality: ${sheet.modality.toLowerCase().replace("_", "-")}`,
    `# duration_minutes: ${Math.round(seconds / 60)}`,
    `# note: SYNTHETIC TRAINING DATA (${writersUsed.join(" → ")}); all people fictional; never use for eval`,
  ];
  writeFileSync(resolve(dir, "transcript.txt"), [...header, ...lines].join("\n") + "\n");

  // Blind teacher pass.
  const fields = sheet.facts.map((f) => f.field);
  const tRes = await client.chat({ model: TEACHER, json: true, temperature: 0, max_tokens: 64000, reasoning: true, messages: [{ role: "system", content: TEACHER_SYSTEM }, { role: "user", content: teacherUser(lines, fields) }] });
  const teacher = parseJSON(tRes.content);

  const labels = {};
  let ok = 0;
  for (const f of sheet.facts) {
    const t = teacher[f.field] ?? {};
    const a = agree(f, t.a);
    ok += a;
    labels[f.field] = { label: f.label, ...(f.acceptable && { acceptable: f.acceptable }), mode: f.mode, ...(f.initial && { initial: f.initial }), ...(f.decoy && { decoy: f.decoy }), teacher: t.a ?? null, evidence: t.l ?? [], agree: a };
  }
  const words = all.join(" ").split(/\s+/).length;
  const truth = {
    schema: "scribeski.synth-truth/1", id, seed, writer: writersUsed.join(" → "), teacher: TEACHER,
    session_type: sheet.session_type, modality: sheet.modality, language: sheet.language,
    minutes: Math.round(seconds / 60), words, lines: lines.length,
    agreement: +(ok / sheet.facts.length).toFixed(3),
    labels,
    text: Object.fromEntries(Object.entries(sheet.text).map(([k, v]) => [k, v])),
    persona_text: { client_first_name: persona.client_first_name, client_last_name: persona.client_last_name, preferred_name: persona.preferred_name, pcp_name: persona.pcp_name, medications: persona.medications, medical_conditions: persona.medical_conditions, sleep_hours: persona.sleep_hours, mse_mood: persona.mood_words, client_goal: persona.client_goal, street_address: persona.street_address, city: persona.city, emergency_contact_name: persona.emergency_contact_name },
  };
  writeFileSync(resolve(dir, "truth.json"), JSON.stringify(truth, null, 1));
  const bad = Object.entries(labels).filter(([, v]) => !v.agree).map(([k, v]) => `${k}(${v.mode}: want ${JSON.stringify(v.label)} got ${JSON.stringify(v.teacher)})`);
  log(`done: ${truth.minutes} min, ${words} words, agreement ${truth.agreement}${bad.length ? `\n    disagree: ${bad.join("; ")}` : ""}`);
  appendFileSync(resolve(OUT, "index.jsonl"), JSON.stringify({ id, minutes: truth.minutes, words, language: sheet.language, session_type: sheet.session_type, agreement: truth.agreement, disagree: bad }) + "\n");
  return truth;
}

// ---- check -------------------------------------------------------------------------------
function check() {
  const md = readFileSync(resolve(ROOT, "fixtures/mock-ehr/FIELDS.md"), "utf8").split("\n");
  let bad = 0;
  for (const [k, s] of Object.entries(FIELDS)) {
    const row = md.find((l) => l.includes(`| ${k} |`) || (l.includes(k) && l.includes(", ") && l.startsWith("| 9")));
    if (!row) { console.log(`missing in FIELDS.md: ${k}`); bad++; continue; }
    for (const o of s.options) if (!row.includes(o)) { console.log(`${k}: option ${o} not in FIELDS.md row`); bad++; }
    if (s.prior.length !== s.options.length) { console.log(`${k}: prior/options length mismatch`); bad++; }
  }
  console.log(bad ? `${bad} problem(s)` : `ok: ${Object.keys(FIELDS).length} fields match FIELDS.md`);
  process.exit(bad ? 1 : 0);
}

// ---- main --------------------------------------------------------------------------------
if (args.check) check();

const seeds = Array.from({ length: N }, (_, i) => SEED + i);
if (args.dry) {
  for (const s of seeds) {
    const sheet = sampleSheet(s, { balance: BALANCE, hard: HARD, minutes: args.minutes ? Number(args.minutes) : undefined, language: args.lang });
    const persona = { client_first_name: "Ana", client_last_name: "Example", preferred_name: null, street_address: "1 Main St", city: "Town", emergency_contact_name: "X Y", pcp_name: "Dr. Z", medications: [], medical_conditions: "", sleep_hours: "6", mood_words: "tired", client_goal: "feel better" };
    sheet.text.next_appointment.value = "2026-11-01";
    const briefs = buildBriefs(sheet, persona);
    console.log(`\n=== seed ${s}: ${sheet.session_type} ${sheet.duration_min}min ${sheet.language}, ${sheet.segments} segments`);
    briefs.forEach((b, i) => console.log(`--- segment ${i + 1}\n` + [...b.extra, ...b.identity, ...b.facts].map((x) => `  - ${x}`).join("\n") + `\n  later: ${b.later.join("; ")}`));
    console.log(`  never: ${briefs[0].never.join("; ")}`);
  }
  process.exit(0);
}

mkdirSync(OUT, { recursive: true });
const client = makeClient(loadKey(ROOT, KEY_ENV), { log: console.log, endpoint: ENDPOINT, provider: PROVIDER });
console.log(`writing ${N} session(s) to ${OUT} (writers ${WRITERS.join(", ")}, teacher ${TEACHER}, ${PROVIDER}, seed ${SEED})`);
const queue = seeds.map((s, i) => [s, i]);
const failures = [];
await Promise.all(Array.from({ length: Math.min(CONCURRENCY, N) }, async () => {
  while (queue.length) {
    const [s, i] = queue.shift();
    try { await runSession(client, s, i); } catch (e) { failures.push(s); console.error(`[seed ${s}] FAILED: ${e.message}`); }
  }
}));
const u = client.usage;
console.log(`\n${N - failures.length}/${N} ok. ${u.calls} calls, ${u.prompt} prompt tok (${u.cached} cached), ${u.completion} completion tok${u.cost ? `, $${u.cost.toFixed(3)}` : ""}`);
if (failures.length) console.log(`failed seeds: ${failures.join(", ")}`);
