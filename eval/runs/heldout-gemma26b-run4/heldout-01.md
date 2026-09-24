# Extraction eval: heldout-01.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | FAIL | 1 |
| must-fill accuracy ≥ 90% | FAIL | 83.8% (57/68) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 6547, mean after = 133 |

Review load (accepted, but the HUD must flag for review): 0

## Blank violations (0)

None.

## Risk-field errors (1)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| si_means (risk) | must_fill | NO_ACCESS | ∅ (rejected) | **FAIL** |

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| dob_day_corrected | pass |  |  |
| lives_alone_misreflection | pass |  |  |
| sell_house_hypothetical | pass |  |  |
| drinking_misreflection | pass |  |  |
| substance_referral_offered_declined | pass |  |  |
| driving_misreflection | pass |  |  |
| spouse_diagnosis_and_meds | **FAIL** | iadl_medications |  |
| firearms_moved_to_son_in_law | **FAIL** | si_means | risk_narrative |
| passive_si | pass |  |  |
| safety_plan_declined | pass |  |  |
| gad7_not_indicated | pass |  |  |
| retirement_income_not_ssi | pass |  |  |
| faith_was_spouses | **FAIL** | protective_factors |  |
| support_group_suggested_only | pass |  |  |
| grandsons_visit | **FAIL** | children_in_home, protective_factors |  |
| va_coverage_not_an_option | **FAIL** | insurance_type |  |
| appointment_rescheduled_other_dates | pass |  |  |
| language_not_asked | pass |  |  |
| phq9_total_not_spoken | **FAIL** | phq9_score, phq9_severity |  |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | pass |  |  |

## Must-fill accuracy: 83.8% (57/68)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| children_in_home | must_fill | NO | ∅ (insufficient_evidence) | **FAIL** |
| insurance_type | must_fill | MEDICARE | ∅ (rejected) | **FAIL** |
| phq9_7 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| phq9_8 | must_fill | 0 | ∅ (rejected) | **FAIL** |
| si_means (risk) | must_fill | NO_ACCESS | ∅ (rejected) | **FAIL** |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| protective_factors | checkbox_constraints | include [FAMILY_CONNECTION, PETS], exclude [CHILDREN_IN_HOME, RELIGIOUS_BELIEFS] | ∅ (insufficient_evidence) | **FAIL** |
| sleep_hours | text_match | equals digits 56 | ∅ (rejected) | **FAIL** |
| phq9_score | derived | 13 | ∅ (insufficient_evidence) | **FAIL** |
| phq9_severity | derived | MODERATE | ∅ (insufficient_evidence) | **FAIL** |
| alcohol_frequency | must_fill | FOUR_PLUS_PER_WEEK | FOUR_PLUS_PER_WEEK | ok |
| case_number | must_fill | AB-611904 | AB-611904 | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | CHILD | CHILD | ok |
| employment_status | must_fill | EMPLOYED_PT | EMPLOYED_PT | ok |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| gad7_status | must_fill | NOT_INDICATED | NOT_INDICATED | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | STABLE | STABLE | ok |
| living_situation | must_fill | ALONE | ALONE | ok |
| medication_adherence | must_fill | ADHERENT | ADHERENT | ok |
| phq9_1 | must_fill | 2 | 2 | ok |
| phq9_2 | must_fill | 2 | 2 | ok |
| phq9_3 | must_fill | 2 | 2 | ok |
| phq9_4 | must_fill | 1 | 1 | ok |
| phq9_5 | must_fill | 1 | 1 | ok |
| phq9_6 | must_fill | 3 | 3 | ok |
| phq9_9 | must_fill | 1 | 1 | ok |
| phq9_difficulty | must_fill | SOMEWHAT | SOMEWHAT | ok |
| referral_source | must_fill | PCP | PCP | ok |
| referrals_made | must_fill | [BENEFITS] | [BENEFITS] | ok |
| safety_plan (risk) | must_fill | DECLINED | DECLINED | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_frequency (risk) | must_fill | SEVERAL_DAYS | SEVERAL_DAYS | ok |
| si_ideation (risk) | must_fill | PASSIVE | PASSIVE | ok |
| si_intent (risk) | must_fill | NO | NO | ok |
| si_plan (risk) | must_fill | NO | NO | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| tobacco_use | must_fill | FORMER | FORMER | ok |
| transportation | must_fill | RELIABLE | RELIABLE | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | [LINE_988] | ok |
| income_sources | checkbox_constraints | include [WAGES], exclude [CHILD_SUPPORT, NONE, SNAP, SSDI, SSI, TANF, UNEMPLOYMENT_INSURANCE] | [WAGES] | ok |
| substances | checkbox_constraints | include [ALCOHOL], exclude [CANNABIS, NONE_REPORTED, OPIOIDS, SEDATIVES, STIMULANTS] | [ALCOHOL] | ok |
| support_system | checkbox_constraints | include [FAMILY, FRIENDS], exclude [FAITH_COMMUNITY, NONE, PEER_GROUP] | [FAMILY, FRIENDS] | ok |
| address_city | text_match | equals case_insensitive Alder Springs | Alder Springs | ok |
| address_line | text_match | contains case_insensitive 1188 quail run | 1188 Quail Run Road. Alder Springs. 93611. | ok |
| address_zip | text_match | equals digits 93611 | 93611 | ok |
| client_dob | text_match | equals date 1963-04-19 | 1963-04-19 | ok |
| client_first_name | text_match | equals case_insensitive Samuel | Samuel | ok |
| client_goal | text_match | contains case_insensitive [visit ruth, parking lot] | I want to be able to visit Ruth without falling apart in the parking lot after. | ok |
| client_last_name | text_match | equals case_insensitive Achterberg | Achterberg | ok |
| client_preferred_name | text_match | equals case_insensitive Sam | Sam | ok |
| contact_phone | text_match | equals digits 5595550147 | 559-555-0147 | ok |
| current_medications | text_match | contains case_insensitive 500 | Levetiracetam (Keppra) 500 milligrams, twice a day | ok |
| emergency_contact_name | text_match | equals case_insensitive Hannah Achterberg-Lee | Hannah Achterberg-Lee | ok |
| emergency_contact_phone | text_match | equals digits 5595550131 | 559-555-0131 | ok |
| medical_conditions | text_match | contains case_insensitive seizure | Seizures and shot knees. | ok |
| mse_mood | text_match | contains case_insensitive lost | Lost. Low. Like I'm waiting for something and I don't know what. | ok |
| next_appointment | text_match | equals date 2026-11-10 | 2026-11-10 | ok |
| pcp_name | text_match | contains case_insensitive castellanos | Dr. Castellanos, at the VA clinic in Alder Springs | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 216 | 3 |
| interventions | filled | 310 | 6 |
| plan | filled | 219 | 3 |
| presenting_problem | filled | 275 | 5 |
| psychosocial_history | filled | 297 | 5 |
| risk_narrative (risk) | filled | 379 | 5 |

## Rejections by reason

- question_mismatch: 2
- quote_not_found: 2
- segment_not_found: 1

Statuses: clinician_only 11 · filled 60 · insufficient_evidence 28 · rejected 5

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 6547 tokens
- requests 2..N prefill: 11705 tokens (mean 2.03% of request 1)
- misses (a request after the first 1 with prefill > 3273 tokens): 0 → pass

Summed model time: 181768 ms
