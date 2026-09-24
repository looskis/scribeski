# Extraction eval: session-06-hypothetical.json

**Result: PASS**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | pass | 91.9% (57/62) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 4930, mean after = 341 |

## Blank violations (0)

None.

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| on_the_street_hypothetical | pass |  | presenting_problem |
| drink_more_if_pain_worse | **FAIL** | substances | presenting_problem |
| cannabis_if_no_drug_test | **FAIL** | substances |  |
| stronger_meds_if_worse | **FAIL** | substances |  |
| ibuprofen_partial | pass |  |  |
| benefits_conditional | pass |  |  |
| daughter_might_move_in | **FAIL** | living_situation, children_in_home, protective_factors |  |
| church_if_mom_alive | **FAIL** | protective_factors | client_strengths |
| dog_if_allowed | **FAIL** | protective_factors |  |
| quit_if_price_rises | **FAIL** | tobacco_use |  |
| legal_aid_conditional | pass |  | plan |
| conditional_si_clarified | pass |  | risk_narrative |
| conditional_988_is_provided | pass |  |  |
| hi_not_asked | pass |  |  |
| phq9_partial | pass |  |  |
| gad7_deferred | pass |  |  |
| bus_not_transportation | pass |  |  |
| appointment_conditional_move | pass |  |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | pass |  |  |

## Must-fill accuracy: 91.9% (57/62)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| children_in_home | must_fill | NO | ∅ (insufficient_evidence) | **FAIL** |
| living_situation | must_fill | ALONE | ∅ (rejected) | **FAIL** |
| tobacco_use | must_fill | CURRENT | ∅ (rejected) | **FAIL** |
| protective_factors | checkbox_constraints | include [FAMILY_CONNECTION], exclude [CHILDREN_IN_HOME, PETS, RELIGIOUS_BELIEFS] | [FAMILY_CONNECTION, CHILDREN_IN_HOME, FUTURE_ORIENTATION] | **FAIL** |
| substances | checkbox_constraints | include [ALCOHOL], exclude [CANNABIS, NONE_REPORTED, OPIOIDS, SEDATIVES, STIMULANTS] | [ALCOHOL, CANNABIS] | **FAIL** |
| alcohol_frequency | must_fill | TWO_TO_FOUR_PER_MONTH | TWO_TO_FOUR_PER_MONTH | ok |
| case_number | must_fill | AB-318845 | AB-318845 | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | CHILD | CHILD | ok |
| employment_status | must_fill | EMPLOYED_PT | EMPLOYED_PT | ok |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| gad7_status | must_fill | DEFERRED | DEFERRED | ok |
| housing_status | must_fill | AT_RISK | AT_RISK | ok |
| insurance_type | must_fill | MEDI_CAL | MEDI_CAL | ok |
| interpreter_needed | must_fill | NO | NO | ok |
| language_combo | must_fill | ENGLISH | ENGLISH | ok |
| legal_involvement | must_fill | NONE | NONE | ok |
| medication_adherence | must_fill | PARTIAL | PARTIAL | ok |
| phq9_1 | must_fill | 1 | 1 | ok |
| phq9_2 | must_fill | 2 | 2 | ok |
| phq9_3 | must_fill | 3 | 3 | ok |
| phq9_4 | must_fill | 2 | 2 | ok |
| phq9_5 | must_fill | 0 | 0 | ok |
| pronouns | must_fill | HE_HIM | HE_HIM | ok |
| referral_source | must_fill | PCP | PCP | ok |
| referrals_made | must_fill | [HOUSING_NAV] | [HOUSING_NAV] | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_ideation (risk) | must_fill | NONE | NONE | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_frequency (risk) | acceptable | one of [null, NONE] | NONE | ok |
| si_intent (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | [LINE_988] | ok |
| income_sources | checkbox_constraints | include [WAGES], exclude [CHILD_SUPPORT, NONE, SNAP, SSDI, SSI, TANF, UNEMPLOYMENT_INSURANCE] | [WAGES] | ok |
| support_system | checkbox_constraints | include [FAMILY], exclude [FAITH_COMMUNITY, FRIENDS, NONE, PEER_GROUP] | [FAMILY] | ok |
| address_city | text_match | equals case_insensitive Castor Bay | Castor Bay | ok |
| address_line | text_match | contains case_insensitive [88 harbor, 3c] | 88 Harbor Boulevard, Apartment 3C. Castor Bay. 90744. | ok |
| address_zip | text_match | equals digits 90744 | 90744 | ok |
| client_dob | text_match | equals date 1979-02-08 | 1979-02-08 | ok |
| client_first_name | text_match | equals case_insensitive Terrence | Terrence | ok |
| client_goal | text_match | contains case_insensitive [find a place i can afford, keep working] | Find a place I can afford before December and keep working. | ok |
| client_last_name | text_match | equals case_insensitive Oyelaran | Oyelaran | ok |
| client_preferred_name | text_match | equals case_insensitive Terry | Terry | ok |
| contact_phone | text_match | equals digits 3235550106 | 323-555-0106 | ok |
| current_medications | text_match | contains case_insensitive [ibuprofen, 800] | Ibuprofen, 800mg | ok |
| emergency_contact_name | text_match | equals case_insensitive Nia Oyelaran | Nia Oyelaran | ok |
| emergency_contact_phone | text_match | equals digits 3235550115 | 323-555-0115 | ok |
| medical_conditions | text_match | contains case_insensitive herniated | Herniated disc | ok |
| mse_mood | text_match | contains case_insensitive [scared, worn down] | Scared. Worn down. | ok |
| next_appointment | text_match | equals date 2026-10-26 | 2026-10-26 | ok |
| pcp_name | text_match | contains case_insensitive abara | Dr. Abara | ok |
| sleep_hours | text_match | equals digits 4 | 4 | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 155 | 2 |
| interventions | filled | 297 | 6 |
| plan | filled | 293 | 4 |
| presenting_problem | filled | 377 | 5 |
| psychosocial_history | filled | 335 | 4 |
| risk_narrative (risk) | filled | 417 | 6 |

## Rejections by reason

- quote_not_found: 2

Statuses: clinician_only 11 · filled 56 · insufficient_evidence 35 · rejected 2

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 4930 tokens
- requests 2..N prefill: 30018 tokens (mean 6.92% of request 1)
- misses (a request after the first 1 with prefill > 2465 tokens): 0 → pass

Summed model time: 185394 ms
