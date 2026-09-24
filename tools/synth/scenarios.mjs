// Variety for synthetic sessions: what the session is about, who talks how, how it's structured,
// what the transcript surface looks like, and concrete details that make the hard fields hard
// (household makeup, drinking patterns, questionnaire answers in everyday words).
//
// Drawn from a separate RNG stream (see sampleScenario) so the ground-truth sheet for a seed
// doesn't shift when this list grows.

export const PRESENTING = [
  "grief after a parent's death", "job loss and money panic", "postpartum low mood", "panic attacks at work",
  "a recent eviction notice", "domestic violence, recently left the relationship", "hearing voices, recently off meds",
  "drinking more since a divorce", "chronic back pain and low mood", "teen conflict at home (client is the parent)",
  "caregiver burnout looking after a parent with dementia", "trauma after a car accident", "anger at work, written up twice",
  "isolation after moving to a new city", "a son's overdose last year", "immigration stress, family separated",
  "gender transition and family rejection", "sleep problems and racing thoughts", "reentry after 3 years in prison",
  "veteran with nightmares and irritability", "a recent psychiatric hospitalization", "gambling debts",
  "a new diabetes diagnosis and depression", "school refusal (client is 17)", "loneliness in retirement",
  "a custody fight", "OCD-type checking rituals", "early recovery from meth use", "burnout as a nurse",
  "perimenopause mood swings", "a friend's suicide last month", "housing instability after a fire",
]

export const SETTINGS = [
  "county outpatient clinic", "school-based program", "hospital discharge follow-up", "jail reentry program",
  "homeless outreach program", "integrated behavioral health in a primary care clinic", "crisis stabilization follow-up",
  "senior services", "veterans' community program", "perinatal mental health program", "community health center",
]

export const CLIENT_STYLE = [
  "talkative, goes on tangents and has to be steered back", "guarded, gives short answers until trust builds",
  "anxious, over-explains and apologizes", "flat and low-energy, long pauses, 'I don't know' a lot",
  "jokes to deflect, then gets serious", "irritable, pushes back on questions", "organized, reads from notes on their phone",
  "a storyteller who answers with anecdotes", "vague with numbers and dates, has to think out loud",
  "blunt and matter-of-fact", "tearful at times, recovers and keeps going",
]

export const WORKER_STYLE = [
  "warm and unhurried, lots of reflections", "efficient and checklist-driven, still polite",
  "new to the job, a bit awkward, occasionally apologizes for the questions", "motivational-interviewing heavy: open questions, summaries",
  "direct and practical, problem-solving", "summarizes back often to check understanding",
]

// sectioned = topics in the usual intake order; interleaved = topics drift and come back;
// client-led = the client raises things early and the worker circles back to confirm.
export const STRUCTURE = ["sectioned", "interleaved", "client-led"]

// Transcript surface, applied in code after writing (words are never changed):
// clean, asr-light (casing/punctuation dropped on some lines), asr-segmented (long turns split,
// short same-speaker turns merged, as streaming ASR does).
export const SURFACE = ["clean", "asr-light", "asr-segmented"]

export function sampleScenario(r, sheet) {
  return {
    presenting: r.pick(PRESENTING),
    setting: r.pick(SETTINGS),
    client_style: r.pick(CLIENT_STYLE),
    worker_style: r.pick(WORKER_STYLE),
    structure: r.weighted(STRUCTURE, [0.4, 0.35, 0.25]),
    surface: r.weighted(SURFACE, [0.4, 0.35, 0.25]),
  }
}

// ---- household makeup (consistent with living_situation / children_in_home / housing) ---------

const RELATIVES = ["their mother", "their father", "their grandmother", "an adult sister", "an adult brother", "an aunt", "an adult cousin", "their adult son (24)", "their adult daughter (27)"]
const MINORS_OWN = ["their 9-year-old daughter", "their 15-year-old son", "their two kids, 6 and 11", "their 3-year-old"]
const MINORS_KIN = ["a 12-year-old niece they have custody of", "their 7-year-old grandson", "their sister's two kids, 4 and 8"]
const PARTNERS = ["their husband", "their wife", "their boyfriend", "their girlfriend", "their partner"]
const PARTNER_KIDS = ["their 3-year-old", "the partner's 10-year-old daughter", "their two kids, 8 and 13"]
const ROOMMATES = ["a coworker", "two friends from school", "a roommate they found online", "an old friend and her cousin"]
const OUTSIDE = [
  "an ex who has their kids every other weekend", "a boyfriend who has his own place and stays over some weekends",
  "an adult son who lives across town", "a sister in another state they talk to daily", "an ex-husband they share custody with",
  "a mother in a nursing home",
]

export function household(r, living, kids, housing) {
  if (!living) return null
  const members = []
  if (living === "ALONE") {
    // nobody
  } else if (living === "WITH_FAMILY") {
    const n = r.int(1, 2)
    for (let i = 0; i < n; i++) members.push(r.pick(RELATIVES.filter((x) => !members.includes(x))))
    if (kids === "YES") members.push(r.pick(r.chance(0.6) ? MINORS_OWN : MINORS_KIN))
  } else if (living === "WITH_PARTNER") {
    members.push(r.pick(PARTNERS))
    if (kids === "YES") members.push(r.pick(PARTNER_KIDS))
  } else if (living === "ROOMMATES") {
    members.push(r.pick(ROOMMATES))
  } else {
    members.push(housing === "SHELTERED" ? "other residents in a shelter dorm" : r.pick(["housemates in a sober-living house", "other residents of a board-and-care home", "other tenants in a rooming house (own room, shared kitchen)"]))
  }
  const outside = r.chance(0.6) ? r.pick(OUTSIDE.filter((o) => !(kids === "NO" && o.includes("kids") && living !== "ALONE"))) : null
  return { members, outside }
}

export function householdText(h) {
  if (!h) return ""
  const lives = h.members.length ? `lives with ${h.members.join(" and ")}` : "lives alone"
  return `household: ${lives}${h.outside ? `; does NOT live with ${h.outside} (mention them so it's clear they live elsewhere)` : ""}`
}

// ---- concrete frequencies ---------------------------------------------------------------------

export const ALCOHOL_PATTERNS = {
  NEVER: ["doesn't drink at all, never liked it", "doesn't drink — grew up around it and stays away"],
  MONTHLY_OR_LESS: ["a glass of wine at family parties, maybe once a month", "a beer at a barbecue a few times a year"],
  TWO_TO_FOUR_PER_MONTH: ["two or three Saturdays a month, a few beers", "every other weekend with friends", "about once a week, sometimes skips a week"],
  TWO_TO_THREE_PER_WEEK: ["Friday and Saturday nights, and sometimes a Wednesday", "two or three nights a week after work"],
  FOUR_PLUS_PER_WEEK: ["most nights, a couple of beers with dinner", "every day after work except Sundays", "a few drinks pretty much daily"],
}

// Questionnaire answers in everyday words (past two weeks). 7 days is never used.
export const ITEM_PHRASES = {
  0: ["no, not really", "not at all", "that's not me", "never, no"],
  1: ["a few days", "two or three times", "maybe four or five days", "once or twice a week"],
  2: ["most days, but not every day", "about ten of the last fourteen", "more days than not"],
  3: ["every single day", "pretty much every day", "all day, every day", "every morning without fail"],
}

// ---- surface noise (words untouched) ----------------------------------------------------------

export function applySurface(lines, surface, r) {
  if (surface === "clean") return lines
  const parsed = lines.map((l) => {
    const i = l.indexOf(":")
    return { who: l.slice(0, i), text: l.slice(i + 1).trim() }
  })
  let out = parsed
  if (surface === "asr-segmented") {
    out = []
    for (const p of parsed) {
      const words = p.text.split(/\s+/)
      if (words.length > 18 && r.chance(0.7)) {
        // split at a clause boundary near the middle
        const mid = Math.floor(words.length / 2)
        let cut = words.findIndex((w, i) => i >= mid - 4 && i <= mid + 4 && /[,.;?!—]$/.test(w))
        if (cut < 0) cut = mid
        out.push({ who: p.who, text: words.slice(0, cut + 1).join(" ") })
        out.push({ who: p.who, text: words.slice(cut + 1).join(" ") })
      } else if (out.length && out.at(-1).who === p.who && words.length < 5 && r.chance(0.5)) {
        out.at(-1).text += " " + p.text
      } else out.push({ ...p })
    }
  }
  // asr-light (and part of asr-segmented): some lines lose casing / punctuation
  out = out.map((p) => {
    let t = p.text
    if (r.chance(0.35)) t = t.replace(/[,;]/g, "")
    if (r.chance(0.3)) t = t.replace(/[.!?]+$/, "")
    if (r.chance(0.25)) t = t.charAt(0).toLowerCase() + t.slice(1)
    return { who: p.who, text: t }
  })
  return out.filter((p) => p.text.trim()).map((p) => `${p.who}: ${p.text}`)
}
