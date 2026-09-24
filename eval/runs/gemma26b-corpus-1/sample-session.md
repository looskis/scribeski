# Extraction eval: sample-session.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | FAIL | 1 |
| must-fill accuracy ≥ 90% | pass | 93.0% (66/71) |
| prefix cache (requests 2..N ≤ 5% of request 1) | pass | 34229 total vs 70227 allowed |

## Blank violations (0)

None.

## Risk-field errors (1)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| safety_plan (risk) | must_fill | COMPLETED | ∅ (rejected) | **FAIL** |

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| gad7_deferred | pass |  |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| language_decoy | pass |  |  |
| speaker_attribution_substances | pass |  |  |
| faith_mentioned_declined | pass |  | client_strengths |
| risk_level_never_stated | pass |  | risk_narrative |
| snap_applied_not_receiving | pass |  | psychosocial_history |
| skipped_meals_not_adl | **FAIL** | iadl_finances |  |
| gender_not_asked | pass |  |  |
| psychiatry_not_referred | pass |  | plan |
| medication_ran_out | pass |  |  |
| roi_hypothetical | pass |  |  |
| eviction_notice_not_legal | pass |  |  |
| phq9_total_not_spoken | pass |  |  |
| worker_only_metadata | **FAIL** | safety_plan, crisis_resources |  |
| connection_glitch | pass |  |  |

## Must-fill accuracy: 93.0% (66/71)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| alcohol_frequency | must_fill | TWO_TO_FOUR_PER_MONTH | TWO_TO_THREE_PER_WEEK | **FAIL** |
| phq9_difficulty | must_fill | VERY | ∅ (rejected) | **FAIL** |
| safety_plan (risk) | must_fill | COMPLETED | ∅ (rejected) | **FAIL** |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | ∅ (insufficient_evidence) | **FAIL** |
| case_number | must_fill | AB-114322 | AB-114322 | ok |
| children_in_home | must_fill | YES | YES | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | SIBLING | SIBLING | ok |
| employment_status | must_fill | UNEMPLOYED | UNEMPLOYED | ok |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| food_security | must_fill | INSECURE | INSECURE | ok |
| gad7_status | must_fill | DEFERRED | DEFERRED | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | AT_RISK | AT_RISK | ok |
| insurance_type | must_fill | MEDI_CAL | MEDI_CAL | ok |
| interpreter_needed | must_fill | NO | NO | ok |
| language_combo | must_fill | ENGLISH | ENGLISH | ok |
| living_situation | must_fill | WITH_FAMILY | WITH_FAMILY | ok |
| medication_adherence | must_fill | NOT_TAKING | NOT_TAKING | ok |
| phq9_1 | must_fill | 2 | 2 | ok |
| phq9_2 | must_fill | 3 | 3 | ok |
| phq9_3 | must_fill | 3 | 3 | ok |
| phq9_4 | must_fill | 2 | 2 | ok |
| phq9_5 | must_fill | 1 | 1 | ok |
| phq9_6 | must_fill | 2 | 2 | ok |
| phq9_7 | must_fill | 2 | 2 | ok |
| phq9_8 | must_fill | 2 | 2 | ok |
| phq9_9 | must_fill | 1 | 1 | ok |
| pronouns | must_fill | SHE_HER | SHE_HER | ok |
| referral_source | must_fill | SCHOOL | SCHOOL | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_frequency (risk) | must_fill | SEVERAL_DAYS | SEVERAL_DAYS | ok |
| si_ideation (risk) | must_fill | PASSIVE | PASSIVE | ok |
| si_intent (risk) | must_fill | NO | NO | ok |
| si_plan (risk) | must_fill | NO | NO | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| tobacco_use | must_fill | FORMER | FORMER | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
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
| pcp_name | text_match | contains case_insensitive okafor | Dr. Okafor at the Eastside Clinic | ok |
| sleep_hours | text_match | equals digits 45 | 4-5 | ok |
| phq9_score | derived | 18 | 18 | ok |
| phq9_severity | derived | MODERATELY_SEVERE | MODERATELY_SEVERE | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 317 | 6 |
| interventions | filled | 350 | 7 |
| plan | filled | 450 | 9 |
| presenting_problem | filled | 578 | 10 |
| psychosocial_history | filled | 645 | 11 |
| risk_narrative (risk) | filled | 747 | 14 |

## Rejections by reason

- negated_answer: 1
- quote_not_found: 5

Statuses: clinician_only 11 · derived 2 · filled 65 · insufficient_evidence 23 · rejected 3

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 13005 tokens
- requests 2..N prefill: 21224 tokens (mean 1.85% of request 1)
- allowed total: 70227 · actual total: 34229 → pass

Summed model time: 242568 ms
