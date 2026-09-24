// The blind teacher: extracts every choice field from a finished transcript without seeing
// any sheet. Shared by generate.mjs (synthetic, checked against the sheet) and
// label_public.mjs (public transcripts, checked against a second teacher).

import { FIELDS, ITEM_TEXT } from "./fields.mjs";

export const TEACHER_SYSTEM = `You fill a behavioural-health intake form from a session transcript. Answer ONLY from the transcript.

Rules:
- An answer describes the CLIENT's own current situation (or, for referrals, crisis resources and safety plans, what the worker actually did in this session).
- Leave it blank (null; [] for multi-select) when the topic never comes up, is only hypothetical/conditional/future, is about someone else, stays unresolved, or the client declines — except use DECLINED where DECLINED is an option and they declined.
- If something is corrected, use the final version.
- A passing mention counts. A fact doesn't have to be the answer to a question: an aside or a detail inside a story ("my wife gets on me about the drinking", "after my shift at the warehouse") establishes it when it clearly describes the client's current situation.
- The WORKER may be a doctor or a social worker. Lines starting with "[family member]" or "[another clinician]" are said by someone other than the client: they count only as information about the client if the client confirms it.
- PHQ-9/GAD-7 items, past two weeks: 0 = not at all; 1 = several days (about 2–6 of 14); 2 = more than half the days (about 8–11); 3 = nearly every day (12–14). Blank if the item wasn't asked.
- Multi-select: include only options clearly established.
- PHQ-9/GAD-7 items only if the worker administers that questionnaire; a similar question asked elsewhere doesn't count.
- Pronouns, gender identity and preferred language only if explicitly discussed — never inferred from names, family roles or the language being spoken.
- Past situations that are no longer true, benefits applied for but not yet received, and referrals made at an earlier visit do not count as current / made today.
- Don't infer one field from another: a tobacco answer says nothing about other substances, denying homicidal thoughts doesn't answer whether there's a plan, mentioning a pet or a friend isn't a protective factor unless named as a reason to keep going.
Return JSON: {"<field>": {"a": <option code | null | [codes]>, "l": [line numbers of evidence]}, ...} with every field listed.`;

export function teacherUser(lines, fields) {
  const spec = fields.map((k) => {
    if (/^(phq9|gad7)_\d$/.test(k)) return `${k}: "${ITEM_TEXT[k]}" — one of 0,1,2,3 or null`;
    const s = FIELDS[k];
    const opts = s.options.map((o) => (s.desc[o] ? `${o} (${s.desc[o]})` : o)).join(" | ");
    return `${k} [${s.kind === "checkbox" ? "multi-select" : "single"}] ${s.topic}: ${opts}`;
  });
  return `TRANSCRIPT:\n${lines.map((l, i) => `L${i + 1} ${l}`).join("\n")}\n\nFIELDS:\n${spec.join("\n")}`;
}


// ---- comparing teacher answers --------------------------------------------------------

export const ITEMS = [...Array(9)].map((_, i) => `phq9_${i + 1}`).concat([...Array(7)].map((_, i) => `gad7_${i + 1}`));
// session_type is supplied by the app, not extracted (decided 2026-09-23).
export const APP_SUPPLIED = new Set(["session_type"]);
export const SCOPE = [...Object.keys(FIELDS).filter((f) => !APP_SUPPLIED.has(f)), ...ITEMS];
// Answers that mean "not established" for a field, so teachers that differ only here agree.
export const BLANKISH = { pronouns: ["NOT_ASKED"], si_plan: ["NOT_ASSESSED"], si_intent: ["NOT_ASSESSED"], si_means: ["NOT_ASSESSED"], hi_plan: ["NOT_ASSESSED"],
  ...Object.fromEntries(["adl_bathing", "adl_dressing", "adl_eating", "adl_mobility", "iadl_finances", "iadl_transport", "iadl_medications"].map((k) => [k, ["NOT_ASSESSED"]])) };

export function norm(field, a) {
  if (a == null || a === "" || (Array.isArray(a) && a.length === 0)) return null;
  if (FIELDS[field]?.kind === "checkbox") {
    const v = (Array.isArray(a) ? a : [a]).map(String).filter((x) => FIELDS[field].options.includes(x)).sort();
    return v.length ? v : null;
  }
  const v = String(a);
  if (BLANKISH[field]?.includes(v)) return null;
  const opts = /^(phq9|gad7)_\d$/.test(field) ? ["0", "1", "2", "3"] : FIELDS[field].options;
  return opts.includes(v) ? v : null;
}

