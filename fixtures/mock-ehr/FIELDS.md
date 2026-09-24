# Mock EHR — field inventory

The source of truth for `fixtures/mock-ehr/`. The HTML must match this table, and
`expected-extraction.json` uses these keys and option values. P1.2's profiler golden file
is checked against it.

**Totals:** 107 fields · 4 steps · 10 in the same-origin iframe `#risk_frame` ·
64 radios in steps 2–4 (PHQ-9 9×4 + GAD-7 7×4) · 65 controls labelled only by
`aria-labelledby` (the 64 radios + the language combobox) · 4 hidden computed fields.

A **field** is what the profiler emits: one per text/textarea/date/select/hidden/combobox
control, and one per radio or checkbox **group** (grouped by `name`).

Label sources (`label_source`): `label_for`, `label_wrap`, `aria_labelledby`, `aria_label`,
`placeholder`, `preceding_text`, `legend`. Every one appears at least once.

Option values are what the page stores (`<option value>`, `input value`, `data-value`).
Labels shown in the UI are human-readable.

## Step 1: Client & session (`#tab-client` → `#panel-client`, visible on load)

| # | key | kind | label source | label | options (value) | notes |
|---|---|---|---|---|---|---|
| 1 | case_number | text | label_for | Case number | | **Controlled input** (React-style). Help: "Format: AB-000000" |
| 2 | client_first_name | text | label_for | Legal first name | | required |
| 3 | client_last_name | text | label_for | Legal last name | | required |
| 4 | client_preferred_name | text | label_wrap | Preferred name | | |
| 5 | client_dob | date | label_for | Date of birth | | required |
| 6 | pronouns | select | label_for | Pronouns | SHE_HER, HE_HIM, THEY_THEM, OTHER, NOT_ASKED | |
| 7 | gender_identity | select | label_for | Gender identity | WOMAN, MAN, NONBINARY, TRANSGENDER_WOMAN, TRANSGENDER_MAN, OTHER, DECLINED | |
| 8 | contact_phone | text | placeholder | Primary phone | | `id` present; **no label, placeholder only** |
| 9 | contact_email | text | aria_label | Email | | `type=email` |
| 10 | contact_ok_voicemail | select | label_for | OK to leave voicemail? | YES, NO | |
| 11 | address_line | text | label_wrap | Street address | | |
| 12 | address_city | text | label_wrap | City | | |
| 13 | address_zip | text | label_wrap | ZIP | | |
| 14 | language_combo | combobox | aria_labelledby | Preferred language | ENGLISH, SPANISH, VIETNAMESE, TAGALOG, MANDARIN, ARABIC, OTHER | **ARIA combobox**, 7 options, no native select |
| 15 | interpreter_needed | select | label_for | Interpreter needed | YES, NO | |
| 16 | session_date | date | label_for | Session date | | from session metadata |
| 17 | session_modality | radio_group | legend | Service modality | VIDEO, PHONE, IN_PERSON | 3 radios (step 1, not counted in the 64) |
| 18 | *(none)* duration | text | preceding_text | Duration (minutes) | | **No `id`, no `name`.** `type=number`. Key falls back to hash |
| 19 | session_type | select | label_for | Session type | INTAKE, FOLLOW_UP, CRISIS | |
| 20 | referral_source | select | label_for | Referral source | SELF, SCHOOL, PCP, HOSPITAL, CPS, COURT, COMMUNITY_ORG, OTHER | |
| 21 | insurance_type | select | label_for | Coverage | MEDI_CAL, MEDICARE, PRIVATE, UNINSURED, UNKNOWN | |
| 22 | insurance_member_id | text | label_for | Member ID | | |
| 23 | emergency_contact_name | text | label_for | Emergency contact name | | |
| 24 | emergency_contact_phone | text | label_for | Emergency contact phone | | |
| 25 | emergency_contact_relationship | select | label_for | Relationship | PARENT, SIBLING, PARTNER, CHILD, FRIEND, OTHER | |
| 26 | consent_telehealth | select | label_for | Telehealth consent | VERBAL, WRITTEN, DECLINED | |
| 27 | release_of_info | checkbox_group | legend | Releases of information on file | PCP, PSYCHIATRIST, SCHOOL, FAMILY, NONE | |

## Step 2: Screening (`#tab-screening` → `#panel-screening`, hidden on load)

PHQ-9 and GAD-7 are rendered as grids. Each row is a radio group named after the key.
Each radio has **no `id` and no `label`**; it carries
`aria-labelledby="<key>_q <instrument>_c<value>"` (row question, then column header).
Radio values are `0`–`3`: Not at all · Several days · More than half the days ·
Nearly every day.

| # | key | kind | label source | label |
|---|---|---|---|---|
| 28–36 | phq9_1 … phq9_9 | radio_group | aria_labelledby | PHQ-9 items 1–9, verbatim |
| 37 | phq9_difficulty | select | label_for | "If you checked off any problems, how difficult have these problems made it for you…" — NOT_DIFFICULT, SOMEWHAT, VERY, EXTREMELY |
| 38 | phq9_score | hidden | — | computed by the page when all 9 items are answered, else empty |
| 39 | phq9_severity | hidden | — | MINIMAL (0–4), MILD (5–9), MODERATE (10–14), MODERATELY_SEVERE (15–19), SEVERE (20–27) |
| 40 | gad7_status | select | label_for | GAD-7 administration — COMPLETED, DEFERRED, DECLINED, NOT_INDICATED |
| 41–47 | gad7_1 … gad7_7 | radio_group | aria_labelledby | GAD-7 items 1–7, verbatim |
| 48 | gad7_score | hidden | — | computed when all 7 answered |
| 49 | gad7_severity | hidden | — | MINIMAL (0–4), MILD (5–9), MODERATE (10–14), SEVERE (15–21) |

The page shows a visible total and band next to each instrument ("Total: 18 · Moderately
severe").

## Step 3: Risk (`#tab-risk` → `#panel-risk`, hidden on load)

Fields 50–59 live in `<iframe id="risk_frame" src="risk.html">` (same origin), labelled
with `label[for]`.

| # | key | kind | label | options |
|---|---|---|---|---|
| 50 | si_ideation | select | Suicidal ideation | NONE, PASSIVE, ACTIVE_NO_PLAN, ACTIVE_WITH_PLAN |
| 51 | si_frequency | select | SI frequency (past 2 weeks) | NONE, SEVERAL_DAYS, MORE_THAN_HALF, NEARLY_EVERY_DAY |
| 52 | si_plan | select | Plan | NO, YES, NOT_ASSESSED |
| 53 | si_intent | select | Intent | NO, YES, NOT_ASSESSED |
| 54 | si_means | select | Access to lethal means | NO_ACCESS, HAS_ACCESS, NOT_ASSESSED |
| 55 | si_prior_attempts | select | Prior attempts | NONE, ONE, MULTIPLE, UNKNOWN |
| 56 | hi_ideation | select | Homicidal ideation | NONE, PASSIVE, ACTIVE |
| 57 | hi_plan | select | HI plan | NO, YES, NOT_ASSESSED |
| 58 | safety_plan | select | Safety plan | COMPLETED, UPDATED, REVIEWED, DEFERRED, DECLINED, NOT_INDICATED |
| 59 | risk_narrative | textarea | Risk assessment narrative | |

Parent document, same panel:

| # | key | kind | label source | label | options |
|---|---|---|---|---|---|
| 60 | risk_level | select | label_for | Overall risk level (clinician determination) | LOW, MODERATE, HIGH, IMMINENT |
| 61 | protective_factors | checkbox_group | legend | Protective factors | FAMILY_CONNECTION, CHILDREN_IN_HOME, FUTURE_ORIENTATION, RELIGIOUS_BELIEFS, TREATMENT_ENGAGEMENT, PETS |
| 62 | crisis_resources | checkbox_group | legend | Crisis resources provided | LINE_988, COUNTY_CRISIS, MOBILE_CRISIS, WARMLINE, NONE |
| 63 | supervisor_consult | select | label_for | Supervisor consulted | YES, NO, PLANNED |

## Step 4: Assessment & plan (`#tab-plan` → `#panel-plan`, hidden on load)

| # | key | kind | label source | label | options |
|---|---|---|---|---|---|
| 64 | presenting_problem | textarea | label_for | Presenting problem | |
| 65 | psychosocial_history | textarea | label_for | Psychosocial history | |
| 66 | interventions | textarea | label_for | Interventions this session | |
| 67 | plan | textarea | label_for | Plan | |
| 68 | client_strengths | textarea | label_for | Client strengths | |
| 69 | housing_status | select | label_for | Housing status | STABLE, AT_RISK, DOUBLED_UP, SHELTERED, UNSHELTERED |
| 70 | living_situation | select | label_for | Lives with | ALONE, WITH_FAMILY, WITH_PARTNER, ROOMMATES, OTHER |
| 71 | employment_status | select | label_for | Employment | EMPLOYED_FT, EMPLOYED_PT, UNEMPLOYED, NOT_IN_LABOR_FORCE, DISABLED, STUDENT |
| 72 | income_sources | checkbox_group | legend | Current income sources | WAGES, UNEMPLOYMENT_INSURANCE, SNAP, TANF, SSI, SSDI, CHILD_SUPPORT, NONE |
| 73 | food_security | select | label_for | Food security | SECURE, INSECURE |
| 74 | transportation | select | label_for | Transportation | RELIABLE, UNRELIABLE, NONE |
| 75 | legal_involvement | select | label_for | Legal involvement | NONE, PROBATION, PENDING_CASE, FAMILY_COURT, CPS_OPEN |
| 76 | children_in_home | select | label_for | Minor children in home | YES, NO |
| 77 | substances | checkbox_group | legend | Substances used (past 30 days) | ALCOHOL, CANNABIS, OPIOIDS, STIMULANTS, SEDATIVES, NONE_REPORTED |
| 78 | alcohol_frequency | select | label_for | Alcohol frequency | NEVER, MONTHLY_OR_LESS, TWO_TO_FOUR_PER_MONTH, TWO_TO_THREE_PER_WEEK, FOUR_PLUS_PER_WEEK |
| 79 | tobacco_use | select | label_for | Tobacco / nicotine | NEVER, FORMER, CURRENT |
| 80 | substance_tx_history | select | label_for | Prior substance-use treatment | NONE, OUTPATIENT, RESIDENTIAL, MAT |
| 81 | pcp_name | text | label_for | Primary care provider | |
| 82 | current_medications | textarea | label_for | Current medications | |
| 83 | medication_adherence | select | label_for | Medication adherence | ADHERENT, PARTIAL, NOT_TAKING, NONE_PRESCRIBED |
| 84 | medical_conditions | text | label_for | Medical conditions | |
| 85 | sleep_hours | text | label_for | Typical sleep (hours/night) | |
| 86 | support_system | checkbox_group | legend | Support system | FAMILY, FRIENDS, FAITH_COMMUNITY, PEER_GROUP, NONE |
| 87 | mse_appearance | select | label_for | Appearance | WNL, DISHEVELED, OTHER |
| 88 | mse_mood | text | label_for | Mood (client's words) | |
| 89 | mse_affect | select | label_for | Affect | FULL, CONSTRICTED, FLAT, LABILE |
| 90 | mse_thought_process | select | label_for | Thought process | LINEAR, TANGENTIAL, DISORGANIZED |
| 91 | mse_orientation | select | label_for | Orientation | X4, IMPAIRED |
| 92 | mse_insight | select | label_for | Insight | GOOD, FAIR, POOR |
| 93 | mse_judgment | select | label_for | Judgment | GOOD, FAIR, POOR |
| 94–100 | adl_bathing, adl_dressing, adl_eating, adl_mobility, iadl_finances, iadl_transport, iadl_medications | select | label_for | ADL/IADL items | INDEPENDENT, NEEDS_ASSISTANCE, DEPENDENT, NOT_ASSESSED |
| 101 | referrals_made | checkbox_group | legend | Referrals made | FOOD_BANK, HOUSING_NAV, BENEFITS, PSYCHIATRY, SUBSTANCE_TX, LEGAL_AID, NONE |
| 102 | client_goal | text | label_for | Client goal (client's words) | |
| 103 | next_appointment | date | label_for | Next appointment | |
| 104 | follow_up_interval | select | label_for | Follow-up interval | WEEKLY, BIWEEKLY, MONTHLY, AS_NEEDED |
| 105 | level_of_care | select | label_for | Recommended level of care | OUTPATIENT, INTENSIVE_OUTPATIENT, PARTIAL_HOSPITALIZATION, INPATIENT |
| 106 | diagnosis_impression | text | aria_label | Diagnostic impression | |
| 107 | note_attestation | checkbox_group | label_wrap | "I attest this note reflects services I provided" | ATTESTED |

## Non-field page content that must never enter a profile

- Header: worker **"K. Loo, ASW"**, session **"SES-2026-0917-0042"**, last saved time.
- A banner "Previous client record closed: M. Okonkwo" (stale PHI, as real EHRs show).
- Section headings, help text not attached to a control, footer.

## Behaviours

- **Controlled input** (`#case_number`): mirrors React's value tracker. An instance-level
  `value` setter records the tracked value, and an `input` event is ignored when the DOM
  value equals the tracked value. Every write re-renders the field from component state
  400 ms later. Result: `el.value = x` (with or without a dispatched `input`) reverts to
  `""`; the native `HTMLInputElement.prototype` setter plus a bubbling `input` persists.
- **Combobox** (`#language_combo`, `role=combobox`, `aria-controls=language_listbox`):
  options are in the DOM but `hidden` until the trigger is clicked (listbox opens after
  ~60 ms). Clicking a `role=option` sets `aria-selected`, updates the trigger text, and
  stores `data-value` on the trigger. There is no backing input.
- **Tabs**: `role=tablist`; each `role=tab` has `aria-controls` → `role=tabpanel`, and the
  inactive panels are `hidden`. All panels are in the DOM on load.
- **Scoring**: on any PHQ-9/GAD-7 change the page recomputes the hidden score and severity,
  and sets them to `""` unless every item is answered.
- **Submit guard**: `#btn_submit` (`type=submit`) sits in `.form-actions` inside the
  `<form>`. The form's submit handler calls `preventDefault()`, logs
  `console.error("[mock-ehr] SUBMIT — automation must never reach this")`, and shows a red
  banner. The Enter key in a text field would also submit, so it triggers the same guard.
- **CSP-clean**: no inline `<script>` or `style=` attributes, so the same assets work under
  `csp.html`.
