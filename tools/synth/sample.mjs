// Samples a session sheet: the ground truth a synthetic transcript is written to.
// Pure and seeded — the same seed gives the same sheet.
//
// Each fact carries a disclosure mode. The label is decided HERE, by rule, never by a model:
//   STATED        plain answer                              → label = value
//   INDIRECT      concrete detail that implies the answer   → label = value
//   CORRECTED     wrong first, corrected later (maybe much) → label = final value
//   MISREFLECTED  worker reflects it wrong, client corrects → label = value
//   DECLINED      asked, client won't answer                → 'DECLINED' if the field has it, else blank
//   HYPOTHETICAL  decoy value only as a conditional/future  → blank (checkbox: decoy excluded)
//   THIRD_PARTY   decoy value belongs to someone else       → blank (checkbox: decoy excluded)
//   AMBIGUOUS     comes up, stays unresolved                → blank
//   PAST          a different value used to be true         → current value if stated, else blank (checkbox: past one excluded)
//   PENDING       applied for / only followed up            → checkbox: that option excluded
//   PASSING       only an aside / a detail in a story       → label = value (a passing mention counts)
//   UNFIT         said, but fits none of the options        → blank, for a person to review
//   NOT_DISCUSSED never comes up at all                     → blank

import { FIELDS, SECTIONS, CLINICIAN_TEMPTATIONS } from "./fields.mjs";
import { sampleScenario, household, ALCOHOL_PATTERNS, ITEM_PHRASES } from "./scenarios.mjs";

export function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const r = {
    next,
    chance: (p) => next() < p,
    int: (lo, hi) => lo + Math.floor(next() * (hi - lo + 1)),
    pick: (xs) => xs[Math.floor(next() * xs.length)],
    weighted(xs, ws) {
      const total = ws.reduce((s, w) => s + w, 0);
      let x = next() * total;
      for (let i = 0; i < xs.length; i++) if ((x -= ws[i]) < 0) return xs[i];
      return xs[xs.length - 1];
    },
    normal: () => Math.sqrt(-2 * Math.log(1 - next())) * Math.cos(2 * Math.PI * next()),
  };
  return r;
}

const EXCLUSIVE = new Set(["NONE", "NONE_REPORTED"]);
const SECTION_WEIGHT = [0.06, 0.12, 0.2, 0.14, 0.16, 0.12, 0.08, 0.12];
const MODE_P = { INDIRECT: 0.2, CORRECTED: 0.07, MISREFLECTED: 0.06, HYPOTHETICAL: 0.06, THIRD_PARTY: 0.06, AMBIGUOUS: 0.05, DECLINED: 0.03, PAST: 0.06, PENDING: 0.06, PASSING: 0.15 };
const TRAP = ["HYPOTHETICAL", "THIRD_PARTY", "AMBIGUOUS", "PAST", "PENDING"];

// Mix the realistic prior toward uniform so rare options (ACTIVE_WITH_PLAN, UNSHELTERED,
// MAT…) appear often enough to learn. balance=0 → prior only; 1 → uniform.
function choose(r, spec, balance, exclude = []) {
  const opts = spec.options.filter((o, i) => spec.prior[i] > 0 && !exclude.includes(o));
  const ws = opts.map((o) => {
    const p = spec.prior[spec.options.indexOf(o)];
    return (1 - balance) * p + balance / opts.length;
  });
  return r.weighted(opts, ws);
}

function chooseSet(r, spec, balance) {
  const idx = spec.options.map((_, i) => i).filter((i) => !EXCLUSIVE.has(spec.options[i]));
  const set = idx.filter((i) => r.chance((1 - balance) * spec.prior[i] + balance * 0.3)).map((i) => spec.options[i]);
  if (set.length) return set.slice(0, 4);
  const none = spec.options.find((o) => EXCLUSIVE.has(o));
  return none ? [none] : [spec.options[idx[0]]];
}

// --hard N multiplies the trap modes that teach "leave it blank" (hypothetical, third party, ambiguous).
let HARD = 1;
function pickMode(r, allowed, extra = {}) {
  const p = { ...MODE_P, ...Object.fromEntries(TRAP.map((m) => [m, MODE_P[m] * HARD])), ...extra };
  const candidates = ["INDIRECT", ...allowed].filter((m) => p[m] > 0);
  let x = r.next();
  for (const m of candidates) if ((x -= p[m]) < 0) return m;
  return "STATED";
}

export function segmentOf(section, n) {
  const start = SECTION_WEIGHT.slice(0, section).reduce((s, w) => s + w, 0);
  const mid = start + SECTION_WEIGHT[section] / 2;
  return Math.min(n - 1, Math.floor(mid * n));
}

export function sampleSheet(seed, opts = {}) {
  const r = rng(seed);
  const rv = rng(seed ^ 0x7a71e7); // variety stream: scenario and concrete details
  const balance = opts.balance ?? 0.5;
  HARD = opts.hard ?? 1;
  const facts = [];
  const text = {};

  // --- session frame -------------------------------------------------------------------
  const session_type = opts.sessionType ?? choose(r, FIELDS.session_type, balance * 0.4);
  const duration_min = opts.minutes ?? (session_type === "CRISIS" ? r.int(15, 45)
    : r.weighted([[10, 20], [20, 40], [40, 70]], [0.2, 0.35, 0.45]).reduce((lo, hi) => r.int(lo, hi)));
  const modality = r.weighted(["VIDEO", "PHONE", "IN_PERSON"], [0.5, 0.4, 0.1]);
  // 70–170 wpm: the corpus runs 72–98, real sessions 130–160 (R15).
  const wpm = r.int(70, 170);
  const segments = Math.max(2, Math.round(duration_min / 7));
  const lang = opts.language ?? r.weighted(["en", "es"], [0.8, 0.2]);
  const preferred = lang === "es" ? "SPANISH"
    : r.weighted(["ENGLISH", "VIETNAMESE", "TAGALOG", "MANDARIN", "ARABIC", "OTHER"], [0.9, 0.02, 0.02, 0.02, 0.02, 0.02]);

  // Probability a field comes up at all: intakes cover most of the form, follow-ups
  // and crisis contacts much less, short sessions less again.
  const baseP = { INTAKE: 0.85, FOLLOW_UP: 0.45, CRISIS: 0.4 }[session_type] * Math.min(1, 0.35 + duration_min / 60);
  const sectionP = (s) => {
    if (s === 1 && session_type !== "INTAKE") return 0.12;
    if (s === 0) return 0.9;
    return baseP;
  };

  const add = (f) => facts.push({ section: FIELDS[f.field]?.section ?? f.section, ...f });

  const blankFact = (field, extra = {}) => add({ field, mode: "NOT_DISCUSSED", value: null, label: null, ...extra });

  function sampleField(field, { value, forceMode, p } = {}) {
    const spec = FIELDS[field];
    if (!r.chance(p ?? sectionP(spec.section)) && !forceMode) return blankFact(field);
    const mode = forceMode ?? pickMode(r, spec.modes);
    if (spec.kind === "checkbox") {
      const set = value ?? chooseSet(r, spec, balance);
      const f = { field, mode: "STATED", value: set.slice().sort(), label: set.slice().sort() };
      if (["HYPOTHETICAL", "THIRD_PARTY", "CORRECTED", "PAST", "PENDING"].includes(mode)) {
        const BENEFITS = ["UNEMPLOYMENT_INSURANCE", "SNAP", "TANF", "SSI", "SSDI", "CHILD_SUPPORT"];
        const pool = spec.options.filter((o) => !set.includes(o) && !EXCLUSIVE.has(o) && (mode !== "PENDING" || field !== "income_sources" || BENEFITS.includes(o)));
        if (pool.length) {
          f.mode = mode;
          f.decoy = r.pick(pool);
          f.must_exclude = [f.decoy];
          if (mode === "CORRECTED") f.initial = [...set, f.decoy].sort();
        }
      } else if (mode === "INDIRECT" || mode === "PASSING") f.mode = mode;
      return add(f);
    }
    const v = value ?? choose(r, spec, balance);
    const f = { field, mode, value: v, label: v };
    if (mode === "CORRECTED" || mode === "MISREFLECTED") {
      f.initial = choose(r, spec, 1, [v, "DECLINED", "UNKNOWN", "NOT_ASSESSED"]);
    } else if (mode === "HYPOTHETICAL" || mode === "THIRD_PARTY") {
      f.decoy = choose(r, spec, 1, ["DECLINED", "UNKNOWN", "NOT_ASSESSED", "NONE", "NEVER"]);
      f.value = null;
      f.label = null;
    } else if (mode === "PAST") {
      f.decoy = choose(r, spec, 1, [v, "DECLINED", "UNKNOWN", "NOT_ASSESSED"]);
      f.current_stated = r.chance(0.6);
      if (!f.current_stated) { f.value = null; f.label = null; }
    } else if (mode === "AMBIGUOUS") {
      f.between = [v, choose(r, spec, 1, [v, "DECLINED", "UNKNOWN", "NOT_ASSESSED"])];
      f.value = null;
      f.label = null;
    } else if (mode === "DECLINED") {
      f.value = null;
      f.label = spec.options.includes("DECLINED") ? "DECLINED" : null;
    }
    return add(f);
  }

  // --- opening ---------------------------------------------------------------------------
  add({ field: "session_type", mode: "STATED", value: session_type, label: session_type });
  add({ field: "language_combo", mode: preferred === "ENGLISH" && lang === "en" ? r.weighted(["STATED", "NOT_DISCUSSED"], [0.4, 0.6]) : "STATED", value: preferred, label: null });
  facts.at(-1).label = facts.at(-1).mode === "NOT_DISCUSSED" ? null : preferred;
  if (facts.at(-1).mode === "NOT_DISCUSSED") facts.at(-1).value = null;
  sampleField("interpreter_needed", { value: "NO", forceMode: lang === "es" || preferred !== "ENGLISH" ? "STATED" : undefined, p: 0.3 });
  sampleField("referral_source", { p: session_type === "INTAKE" ? 0.9 : 0.2 });
  if (modality === "IN_PERSON") blankFact("consent_telehealth");
  else sampleField("consent_telehealth", { p: session_type === "INTAKE" ? 0.9 : 0.3 });

  // --- identity --------------------------------------------------------------------------
  const identityP = sectionP(1);
  const gender = choose(r, FIELDS.gender_identity, balance, ["DECLINED"]);
  const pron = r.chance(0.9) ? ({ WOMAN: "SHE_HER", TRANSGENDER_WOMAN: "SHE_HER", MAN: "HE_HIM", TRANSGENDER_MAN: "HE_HIM", NONBINARY: "THEY_THEM" }[gender]) : undefined;
  sampleField("pronouns", { p: identityP, value: pron });
  sampleField("gender_identity", { p: identityP, value: r.chance(0.04) ? undefined : gender });
  for (const f of ["contact_ok_voicemail", "insurance_type", "emergency_contact_relationship", "release_of_info"]) {
    sampleField(f, { p: identityP });
  }
  const ageYears = r.int(19, 78);
  const dobYear = 2026 - ageYears;
  text.case_number = { value: `AB-${r.int(100000, 999999)}`, discussed: r.chance(Math.max(identityP, 0.3)) };
  text.client_dob = { value: `${dobYear}-${String(r.int(1, 12)).padStart(2, "0")}-${String(r.int(1, 28)).padStart(2, "0")}`, discussed: r.chance(identityP) };
  text.contact_phone = { value: `${r.pick(["707", "916", "510", "209", "559"])}55501${r.int(0, 9)}${r.int(0, 9)}`, discussed: r.chance(identityP) };
  text.address_zip = { value: `95${r.int(100, 999)}`, discussed: r.chance(identityP) };
  text.insurance_member_id = { value: String(r.int(10000000, 99999999)), discussed: r.chance(identityP * 0.6) };
  text.emergency_contact_phone = { value: `${r.pick(["707", "916", "510"])}55501${r.int(0, 9)}${r.int(0, 9)}`, discussed: r.chance(identityP * 0.8) };
  for (const t of ["client_dob", "contact_phone", "address_zip", "case_number"]) {
    if (text[t].discussed && r.chance(0.12)) text[t].corrected = true;
  }

  // --- psychosocial ----------------------------------------------------------------------
  const housing = choose(r, FIELDS.housing_status, balance);
  sampleField("housing_status", { value: housing });
  const living = housing === "UNSHELTERED" ? r.pick(["ALONE", "WITH_PARTNER", "OTHER"])
    : housing === "SHELTERED" ? "OTHER" : choose(r, FIELDS.living_situation, balance);
  sampleField("living_situation", { value: living });
  const kids = living === "ALONE" || living === "ROOMMATES" ? "NO" : choose(r, FIELDS.children_in_home, balance);
  sampleField("children_in_home", { value: kids });
  const employment = ageYears > 66 && r.chance(0.7) ? "NOT_IN_LABOR_FORCE" : choose(r, FIELDS.employment_status, balance);
  sampleField("employment_status", { value: employment });
  {
    const inc = new Set(chooseSet(r, FIELDS.income_sources, balance).filter((o) => o !== "WAGES" && o !== "NONE"));
    if (employment.startsWith("EMPLOYED")) inc.add("WAGES");
    if (employment === "UNEMPLOYED" && r.chance(0.5)) inc.add("UNEMPLOYMENT_INSURANCE");
    if (employment !== "UNEMPLOYED") inc.delete("UNEMPLOYMENT_INSURANCE");
    if (employment === "DISABLED" && !inc.has("SSI") && !inc.has("SSDI")) inc.add(r.pick(["SSI", "SSDI"]));
    sampleField("income_sources", { value: inc.size ? [...inc] : ["NONE"] });
  }
  for (const f of ["food_security", "transportation", "legal_involvement", "support_system"]) sampleField(f);

  // --- health ----------------------------------------------------------------------------
  const subs = chooseSet(r, FIELDS.substances, balance);
  sampleField("substances", { value: subs });
  const drinks = subs.includes("ALCOHOL");
  sampleField("alcohol_frequency", {
    value: drinks ? choose(r, FIELDS.alcohol_frequency, balance, ["NEVER"]) : r.pick(["NEVER", "NEVER", "MONTHLY_OR_LESS"]),
  });
  // "MONTHLY_OR_LESS" but no ALCOHOL in the past 30 days is coherent (last drink > 30 days ago).
  for (const f of ["tobacco_use", "substance_tx_history", "medication_adherence"]) sampleField(f);

  // --- screening -------------------------------------------------------------------------
  const phqMode = r.weighted(["FULL", "PARTIAL", "PHQ2", "NONE"],
    session_type === "INTAKE" ? [0.6, 0.1, 0.1, 0.2] : session_type === "CRISIS" ? [0.25, 0.1, 0.25, 0.4] : [0.35, 0.1, 0.15, 0.4]);
  const phqCount = { FULL: 9, PARTIAL: r.int(3, 8), PHQ2: 2, NONE: 0 }[phqMode];
  const severity = Math.max(0, Math.min(3, r.weighted([0.3, 1, 1.8, 2.5], [0.25, 0.35, 0.25, 0.15]) + r.normal() * 0.2));
  const item = () => Math.max(0, Math.min(3, Math.round(severity + r.normal() * 0.8)));
  const itemMode = () => r.weighted(["STATED", "INDIRECT", "CORRECTED", "MISREFLECTED"], [0.55, 0.33, 0.06, 0.06]);

  // --- risk (decided before PHQ-9 item 9 so the two agree) --------------------------------
  const riskAsked = session_type === "CRISIS" || r.chance(session_type === "INTAKE" ? 0.8 : 0.5);
  const si = riskAsked ? choose(r, FIELDS.si_ideation, balance) : null;
  const siFreq = si == null ? null : si === "NONE" ? "NONE" : r.pick(["SEVERAL_DAYS", "MORE_THAN_HALF", "NEARLY_EVERY_DAY"]);
  const phq9_9 = si == null ? 0 : { NONE: 0, SEVERAL_DAYS: 1, MORE_THAN_HALF: 2, NEARLY_EVERY_DAY: 3 }[siFreq];

  for (let i = 1; i <= 9; i++) {
    const field = `phq9_${i}`;
    if (i > phqCount) { add({ field, section: 4, mode: "NOT_DISCUSSED", value: null, label: null }); continue; }
    const v = String(i === 9 ? phq9_9 : item());
    const mode = itemMode();
    const f = { field, section: 4, mode, value: v, label: v };
    if (mode === "CORRECTED" || mode === "MISREFLECTED") f.initial = String(r.pick([0, 1, 2, 3].filter((x) => String(x) !== v)));
    add(f);
  }
  if (phqMode === "FULL" && r.chance(0.7)) sampleField("phq9_difficulty", { forceMode: "STATED", value: severity < 0.7 ? "NOT_DIFFICULT" : choose(r, FIELDS.phq9_difficulty, balance, ["NOT_DIFFICULT"]) });
  else blankFact("phq9_difficulty");

  const gadStatus = r.chance(phqMode === "NONE" ? 0.3 : 0.85) ? choose(r, FIELDS.gad7_status, balance) : null;
  if (gadStatus) add({ field: "gad7_status", mode: "STATED", value: gadStatus, label: gadStatus });
  else blankFact("gad7_status");
  const anx = Math.max(0, Math.min(3, severity + r.normal() * 0.7));
  for (let i = 1; i <= 7; i++) {
    const field = `gad7_${i}`;
    if (gadStatus !== "COMPLETED") { add({ field, section: 4, mode: "NOT_DISCUSSED", value: null, label: null }); continue; }
    const v = String(Math.max(0, Math.min(3, Math.round(anx + r.normal() * 0.8))));
    const mode = itemMode();
    const f = { field, section: 4, mode, value: v, label: v };
    if (mode === "CORRECTED" || mode === "MISREFLECTED") f.initial = String(r.pick([0, 1, 2, 3].filter((x) => String(x) !== v)));
    add(f);
  }

  // --- risk fields -----------------------------------------------------------------------
  const riskField = (field, value, extra = {}) => add({ field, section: 5, mode: "STATED", value, label: value, ...extra });
  const notAssessed = (field) => add({ field, section: 5, mode: "NOT_DISCUSSED", value: null, label: null, acceptable: [null, "NOT_ASSESSED"] });
  if (!riskAsked) {
    for (const f of ["si_ideation", "si_frequency", "si_prior_attempts", "hi_ideation", "safety_plan"]) blankFact(f, { section: 5 });
    // PHQ-9 item 9 answered "not at all" is not a risk assessment, but reading it as NONE isn't unsafe.
    if (phqCount === 9) for (const f of facts.filter((x) => x.field === "si_ideation" || x.field === "si_frequency")) f.acceptable = [null, "NONE"];
    for (const f of ["si_plan", "si_intent", "si_means", "hi_plan"]) notAssessed(f);
    blankFact("protective_factors", { section: 5 });
  } else {
    // Form gap (2026-09-23): active ideation with the plan never asked about fits none of the
    // si_ideation options (they force a plan answer), so the right answer is blank, for review.
    const planUnasked = si.startsWith("ACTIVE") && r.chance(0.3);
    const siMode = planUnasked ? "UNFIT" : r.weighted(["STATED", "INDIRECT", "MISREFLECTED"], [0.6, 0.3, 0.1]);
    const siFact = { field: "si_ideation", section: 5, mode: siMode, value: planUnasked ? null : si, label: planUnasked ? null : si };
    if (siMode === "MISREFLECTED") siFact.initial = choose(r, FIELDS.si_ideation, 1, [si]);
    add(siFact);
    riskField("si_frequency", siFreq, { derived_from: "si_ideation" });
    if (si === "NONE") {
      if (r.chance(0.5)) { riskField("si_plan", "NO"); riskField("si_intent", "NO"); }
      else { notAssessed("si_plan"); notAssessed("si_intent"); }
    } else if (planUnasked) {
      notAssessed("si_plan");
      notAssessed("si_intent");
    } else {
      riskField("si_plan", si === "ACTIVE_WITH_PLAN" ? "YES" : "NO");
      riskField("si_intent", si === "ACTIVE_WITH_PLAN" && r.chance(0.4) ? "YES" : "NO");
    }
    const meansAsked = si !== "NONE" || r.chance(0.35);
    if (meansAsked) sampleField("si_means", { p: 1, forceMode: r.weighted(["STATED", "INDIRECT", "THIRD_PARTY", "CORRECTED"], [0.55, 0.25, 0.1, 0.1]) });
    else notAssessed("si_means");
    // THIRD_PARTY/HYPOTHETICAL on a field with NOT_ASSESSED: blank or NOT_ASSESSED both pass.
    const means = facts.at(-1);
    if (means.field === "si_means" && means.label == null) means.acceptable = [null, "NOT_ASSESSED"];
    sampleField("si_prior_attempts", { p: si === "NONE" ? 0.6 : 0.95 });
    if (r.chance(0.6)) {
      const hi = choose(r, FIELDS.hi_ideation, balance);
      riskField("hi_ideation", hi);
      if (hi === "NONE") notAssessed("hi_plan");
      else riskField("hi_plan", hi === "ACTIVE" && r.chance(0.5) ? "YES" : "NO");
    } else { blankFact("hi_ideation", { section: 5 }); notAssessed("hi_plan"); }
    if (si === "NONE") {
      if (r.chance(0.4)) riskField("safety_plan", "NOT_INDICATED"); else blankFact("safety_plan", { section: 5 });
    } else sampleField("safety_plan", { p: 0.9, forceMode: "STATED", value: choose(r, FIELDS.safety_plan, balance, ["NOT_INDICATED"]) });
    const pf = chooseSet(r, FIELDS.protective_factors, balance).filter((o) => o !== "CHILDREN_IN_HOME" || kids === "YES");
    if (pf.length) sampleField("protective_factors", { p: si === "NONE" ? 0.4 : 0.85, value: pf });
    else blankFact("protective_factors", { section: 5 });
  }

  // --- functioning -----------------------------------------------------------------------
  const adlAsked = r.chance(ageYears > 60 ? 0.7 : 0.2) && session_type !== "CRISIS";
  for (const f of ["adl_bathing", "adl_dressing", "adl_eating", "adl_mobility", "iadl_finances", "iadl_transport", "iadl_medications"]) {
    if (adlAsked) sampleField(f, { p: 0.85 });
    else add({ field: f, mode: "NOT_DISCUSSED", value: null, label: null, acceptable: [null, "NOT_ASSESSED"] });
  }

  // --- plan ------------------------------------------------------------------------------
  const riskHigh = si && si !== "NONE";
  if (!riskAsked) blankFact("crisis_resources");
  else sampleField("crisis_resources", { p: riskHigh ? 0.95 : 0.35, forceMode: "STATED", value: riskHigh ? chooseSet(r, FIELDS.crisis_resources, balance).filter((o) => o !== "NONE") : undefined });
  const cr = facts.at(-1);
  if (cr.field === "crisis_resources" && Array.isArray(cr.label) && cr.label.length === 0) Object.assign(cr, { value: ["LINE_988"], label: ["LINE_988"] });
  if (r.chance(0.7)) sampleField("referrals_made", { p: 1, forceMode: r.weighted(["STATED", "HYPOTHETICAL", "PENDING"], [0.7, 0.12, 0.18]) });
  else blankFact("referrals_made");
  sampleField("follow_up_interval", { p: 0.75 });
  text.next_appointment = { value: null, discussed: r.chance(0.7) };

  // --- concrete details (variety stream) -------------------------------------------------
  const scenario = sampleScenario(rv);
  const byField = Object.fromEntries(facts.map((f) => [f.field, f]));
  const disclosed = (f) => f && !["NOT_DISCUSSED", "HYPOTHETICAL", "THIRD_PARTY", "AMBIGUOUS"].includes(f.mode) && f.label != null;
  const home = household(rv, living, kids, housing);
  for (const k of ["living_situation", "children_in_home"]) if (disclosed(byField[k])) byField[k].household = home;
  const alc = byField.alcohol_frequency;
  if (alc) {
    if (alc.label) alc.detail = rv.pick(ALCOHOL_PATTERNS[alc.label]);
    if (alc.initial) alc.initial_detail = rv.pick(ALCOHOL_PATTERNS[alc.initial]);
    if (alc.decoy) alc.decoy_detail = rv.pick(ALCOHOL_PATTERNS[alc.decoy]);
  }
  for (const f of facts) if (/^(phq9|gad7)_\d$/.test(f.field) && f.mode === "INDIRECT") f.phrase = rv.pick(ITEM_PHRASES[f.value]);

  // Readings of a not-discussed field that are harmless and arguably correct.
  const alt = { pronouns: "NOT_ASKED", ...(lang === "en" && preferred === "ENGLISH" && { language_combo: "ENGLISH", interpreter_needed: "NO" }) };
  for (const f of facts) if (f.mode === "NOT_DISCUSSED" && alt[f.field]) f.acceptable = [null, alt[f.field]];

  // --- segment placement -----------------------------------------------------------------
  for (const f of facts) {
    f.segment = segmentOf(f.section, segments);
    // interleaved: topics drift ±1 segment; client-led: some psychosocial/health facts surface early.
    // Instruments and risk stay put (they're administered as blocks).
    if (![4, 5].includes(f.section) && f.mode !== "NOT_DISCUSSED") {
      if (scenario.structure === "interleaved") f.segment = Math.max(0, Math.min(segments - 1, f.segment + rv.int(-1, 1)));
      if (scenario.structure === "client-led" && [2, 3].includes(f.section) && rv.chance(0.35)) f.segment = Math.min(f.segment, rv.int(0, 1));
    }
    if (!["NOT_DISCUSSED", "CORRECTED"].includes(f.mode) && f.segment < segments - 2 && rv.chance(0.08)) {
      f.revisit_segment = rv.int(f.segment + 1, segments - 1); // mentioned again later, consistently
    }
    if (f.mode === "CORRECTED" && f.segment < segments - 1 && r.chance(0.5)) {
      f.correction_segment = r.int(f.segment + 1, segments - 1); // long-range correction
    }
  }
  for (const t of Object.values(text)) {
    if (t.corrected && r.chance(0.5)) t.correction_segment = r.int(1, segments - 1);
  }

  const temptations = CLINICIAN_TEMPTATIONS.filter(() => r.chance(0.25));

  return {
    schema: "scribeski.synth-sheet/1",
    seed, session_type, modality, duration_min, wpm, segments, language: lang,
    age_years: ageYears,
    scenario,
    instruments: { phq9: phqMode, phq9_items: phqCount, gad7: gadStatus },
    risk_asked: riskAsked,
    facts, text, temptations,
    sections: SECTIONS,
  };
}
