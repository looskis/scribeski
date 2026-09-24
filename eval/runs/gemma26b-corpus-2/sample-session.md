# Extraction eval: sample-session.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | FAIL | 2 |
| must-fill accuracy ≥ 90% | FAIL | 83.1% (59/71) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 13007, mean after = 240 |

## Blank violations (0)

None.

## Risk-field errors (2)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| hi_ideation (risk) | must_fill | NONE | ∅ (rejected) | **FAIL** |
| si_prior_attempts (risk) | must_fill | NONE | ∅ (rejected) | **FAIL** |

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| gad7_deferred | pass |  |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| language_decoy | **FAIL** | interpreter_needed |  |
| speaker_attribution_substances | pass |  |  |
| faith_mentioned_declined | pass |  | client_strengths |
| risk_level_never_stated | pass |  | risk_narrative |
| snap_applied_not_receiving | pass |  | psychosocial_history |
| skipped_meals_not_adl | **FAIL** | iadl_finances, food_security |  |
| gender_not_asked | pass |  |  |
| psychiatry_not_referred | pass |  | plan |
| medication_ran_out | pass |  |  |
| roi_hypothetical | pass |  |  |
| eviction_notice_not_legal | pass |  |  |
| phq9_total_not_spoken | **FAIL** | phq9_score, phq9_severity |  |
| worker_only_metadata | **FAIL** | crisis_resources |  |
| connection_glitch | pass |  |  |

## Must-fill accuracy: 83.1% (59/71)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| alcohol_frequency | must_fill | TWO_TO_FOUR_PER_MONTH | TWO_TO_THREE_PER_WEEK | **FAIL** |
| food_security | must_fill | INSECURE | ∅ (rejected) | **FAIL** |
| hi_ideation (risk) | must_fill | NONE | ∅ (rejected) | **FAIL** |
| interpreter_needed | must_fill | NO | ∅ (rejected) | **FAIL** |
| phq9_2 | must_fill | 3 | ∅ (rejected) | **FAIL** |
| phq9_9 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| phq9_difficulty | must_fill | VERY | ∅ (rejected) | **FAIL** |
| si_prior_attempts (risk) | must_fill | NONE | ∅ (rejected) | **FAIL** |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | ∅ (insufficient_evidence) | **FAIL** |
| phq9_score | derived | 18 | ∅ (insufficient_evidence) | **FAIL** |
| phq9_severity | derived | MODERATELY_SEVERE | ∅ (insufficient_evidence) | **FAIL** |
| case_number | must_fill | AB-114322 | AB-114322 | ok |
| children_in_home | must_fill | YES | YES | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | SIBLING | SIBLING | ok |
| employment_status | must_fill | UNEMPLOYED | UNEMPLOYED | ok |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| gad7_status | must_fill | DEFERRED | DEFERRED | ok |
| housing_status | must_fill | AT_RISK | AT_RISK | ok |
| insurance_type | must_fill | MEDI_CAL | MEDI_CAL | ok |
| language_combo | must_fill | ENGLISH | ENGLISH | ok |
| living_situation | must_fill | WITH_FAMILY | WITH_FAMILY | ok |
| medication_adherence | must_fill | NOT_TAKING | NOT_TAKING | ok |
| phq9_1 | must_fill | 2 | 2 | ok |
| phq9_3 | must_fill | 3 | 3 | ok |
| phq9_4 | must_fill | 2 | 2 | ok |
| phq9_5 | must_fill | 1 | 1 | ok |
| phq9_6 | must_fill | 2 | 2 | ok |
| phq9_7 | must_fill | 2 | 2 | ok |
| phq9_8 | must_fill | 2 | 2 | ok |
| pronouns | must_fill | SHE_HER | SHE_HER | ok |
| referral_source | must_fill | SCHOOL | SCHOOL | ok |
| safety_plan (risk) | must_fill | COMPLETED | COMPLETED | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_frequency (risk) | must_fill | SEVERAL_DAYS | SEVERAL_DAYS | ok |
| si_ideation (risk) | must_fill | PASSIVE | PASSIVE | ok |
| si_intent (risk) | must_fill | NO | NO | ok |
| si_plan (risk) | must_fill | NO | NO | ok |
| tobacco_use | must_fill | FORMER | FORMER | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | ∅ (rejected) | ok |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| income_sources | checkbox_constraints | include [UNEMPLOYMENT_INSURANCE], exclude [CHILD_SUPPORT, NONE, SNAP, SSDI, SSI, TANF, WAGES] | [UNEMPLOYMENT_INSURANCE] | ok |
| protective_factors | checkbox_constraints | include [CHILDREN_IN_HOME, FAMILY_CONNECTION], exclude [PETS, RELIGIOUS_BELIEFS] | [FAMILY_CONNECTION, CHILDREN_IN_HOME, FUTURE_ORIENTATION] | ok |
| referrals_made | checkbox_constraints | include [BENEFITS, FOOD_BANK, HOUSING_NAV], exclude [LEGAL_AID, NONE, PSYCHIATRY, SUBSTANCE_TX] | [FOOD_BANK, HOUSING_NAV, BENEFITS] | ok |
| substances | checkbox_constraints | include [ALCOHOL], exclude [CANNABIS, NONE_REPORTED, OPIOIDS, SEDATIVES, STIMULANTS] | [ALCOHOL] | ok |
| support_system | checkbox_constraints | include [FAMILY, FRIENDS], exclude [FAITH_COMMUNITY, NONE, PEER_GROUP] | [FAMILY, FRIENDS] | ok |
| address_city | text_match | equals case_insensitive Fairhaven | Fairhaven | ok |
| address_line | text_match | contains case_insensitive [2210 alder st, 4] | 2210 Alder Street, Apartment 4 | ok |
| address_zip | text_match | equals digits 92503 | 92503 | ok |
| client_dob | text_match | equals date 1989-03-03 | 1989-03-03 | ok |
| client_first_name | text_match | equals case_insensitive Daniela | Daniela | ok |
| client_goal | text_match | contains case_insensitive [keep us in the apartment, feel like myself again] | I just want to keep us in the apartment and feel like myself again. | ok |
| client_last_name | text_match | equals case_insensitive Reyes | Reyes | ok |
| client_preferred_name | text_match | equals case_insensitive Dani | Dani | ok |
| contact_phone | text_match | equals digits 5105550193 | 510-555-0193 | ok |
| current_medications | text_match | contains case_insensitive [sertraline, 50] | sertraline, 50 milligrams | ok |
| emergency_contact_name | text_match | equals case_insensitive Marisol Reyes | Marisol Reyes | ok |
| emergency_contact_phone | text_match | equals digits 5105550148 | 510-555-0148 | ok |
| medical_conditions | text_match | contains case_insensitive asthma | Asthma | ok |
| mse_mood | text_match | contains case_insensitive [exhausted, numb] | Exhausted. Kind of numb. | ok |
| next_appointment | text_match | equals date 2026-09-24 | 2026-09-24 | ok |
| pcp_name | text_match | contains case_insensitive okafor | Dr. Okafor, Eastside Clinic | ok |
| sleep_hours | text_match | equals digits 45 | 4-5 | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 303 | 6 |
| interventions | filled | 359 | 7 |
| plan | filled | 446 | 8 |
| presenting_problem | filled | 439 | 8 |
| psychosocial_history | filled | 545 | 10 |
| risk_narrative (risk) | filled | 766 | 14 |

## Rejections by reason

- missing_question_context: 5
- question_mismatch: 1
- question_not_asked: 1
- quote_not_found: 6

Statuses: clinician_only 11 · filled 59 · insufficient_evidence 25 · rejected 9

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 13007 tokens
- requests 2..N prefill: 21165 tokens (mean 1.85% of request 1)
- misses (a request after the first 1 with prefill > 6503 tokens): 0 → pass

Summed model time: 245606 ms
