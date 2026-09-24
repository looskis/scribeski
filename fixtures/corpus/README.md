# Extraction eval corpus (BUILD_PLAN §5 P1.6)

Synthetic sessions for `scribeski eval`. Each one targets a failure class that
`../sample-session.txt` alone would let prompts overfit past. Every transcript has an
`expected-*.json` in the same shape as `../expected-extraction.json`. All 107 FIELDS.md keys
sit in exactly one bucket, and PHQ-9/GAD-7 totals live in `derived` and are asserted after
fill, never extracted. The `$comment` at the top of each file states its assumptions, and
each trap there has an id, a description, the fields it affects, and a rule.

All people, places, clinics and numbers are fictional, and phone numbers are 555-01xx.
Timestamps come from word counts plus natural gaps, scaled to the stated duration.

| transcript | expected | trap class | modality | duration | PHQ-9 | GAD-7 | lethal means |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `session-03-correction.txt` | `expected-03-correction.json` | Client self-corrects: layoff month, DOB year, phone digits, unit, emergency contact, sleep, mood, alcohol, a PHQ-9 item; the worker misreads the case number; the appointment is rescheduled | video | 25 min | full → 10 MODERATE (a correction flips the band) | DECLINED | not asked |
| `session-04-misreflection.txt` | `expected-04-misreflection.json` | Worker reflects back wrongly, client corrects (who moved in with whom, drinking more vs less, 8h in bed vs 5h asleep, stopped med, SSI, son vs nephew, ADLs, a GAD-7 item, active vs passive SI). ADLs/IADLs assessed | phone | 20 min | not given (null) | full → 9 MILD | not asked |
| `session-05-nothing.txt` | `expected-05-nothing.json` | 8-minute check-in; almost nothing fillable (71 keys in must_leave_blank). No risk inquiry; a prior PHQ-9 score is mentioned; prior referrals are followed up, not made | phone | 8 min | not given (null) | not mentioned | not asked |
| `session-06-hypothetical.txt` | `expected-06-hypothetical.json` | Conditionals: "on the street" ≠ UNSHELTERED, "drink more if the pain gets worse", SSDI pending, food stamps "if", daughter "might" move in, church "if Mom were alive", dog "if allowed", legal aid "if they file", conditional SI clarified | video | 18 min | partial (items 1-5) → null | DEFERRED | not asked |
| `session-07-third-party.txt` | `expected-07-third-party.json` | Family members' problems not attributed to the client: mother's diabetes/insulin/SSI/Medicare/faith, sister's drinking/rehab/AA/suicidal crisis, partner's probation and cannabis | video | 20 min | PHQ-2 only (items 1-2) → null | full → 13 MODERATE | not asked |
| `session-08-long.txt` | `expected-08-long.json` | 60 minutes, ~400 segments, nearly every field fillable, for latency and prefix cache. The ZIP code is corrected about 55 minutes after it was given | video | 60 min | full → 17 MODERATELY_SEVERE | full → 8 MILD | **asked: HAS_ACCESS** (stockpiled medications) |
| `heldout/heldout-01.txt` | `heldout/expected-heldout-01.json` | Held out: mixed trap classes | phone | 24 min | see file | see file | see file |
| `heldout/heldout-02.txt` | `heldout/expected-heldout-02.json` | Held out: mixed trap classes | video | 18 min | see file | see file | see file |

**`heldout/` is never used while tuning prompts** (see `heldout/README.md`). Only score it at gates.

Across sessions 02-08, the risk ground truth covers NONE and PASSIVE ideation, prior attempts
NONE and ONE, and safety plans UPDATED, REVIEWED and never-mentioned (blank). Lethal means are
asked and answered only in session-08; in 02-07 they are never asked (blank or NOT_ASSESSED). No
transcript states an overall risk level. The held-out files are summarised only in their own
expected files.
