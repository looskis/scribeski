# Extraction eval: session-03-correction.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | FAIL | 85.1% (57/67) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 6827, mean after = 133 |

Review load (accepted, but the HUD must flag for review): 1 (iadl_transport)

## Blank violations (0)

None.

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| case_number_worker_misread | pass |  |  |
| dob_year_corrected | pass |  |  |
| phone_digits_corrected | pass |  |  |
| unit_corrected | pass |  |  |
| emergency_contact_switched | **FAIL** | emergency_contact_name |  |
| layoff_month_corrected | manual |  | presenting_problem, psychosocial_history |
| sleep_hours_corrected | pass |  |  |
| mood_fine_retracted | pass |  |  |
| alcohol_frequency_corrected | **FAIL** | substances |  |
| phq9_item4_corrected | **FAIL** | phq9_score |  |
| appointment_rescheduled | **FAIL** | next_appointment |  |
| insurance_past_vs_current | pass |  |  |
| past_income_and_cannabis | **FAIL** | substances |  |
| daughter_not_in_home | **FAIL** | protective_factors, legal_involvement |  |
| gad7_declined_by_client | pass |  |  |
| no_doctor_no_meds | pass |  |  |
| phq9_total_not_spoken | **FAIL** | phq9_score |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | **FAIL** | crisis_resources, next_appointment |  |

## Must-fill accuracy: 85.1% (57/67)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| interpreter_needed | must_fill | NO | ∅ (rejected) | **FAIL** |
| legal_involvement | must_fill | NONE | ∅ (rejected) | **FAIL** |
| living_situation | must_fill | ROOMMATES | ∅ (rejected) | **FAIL** |
| phq9_5 | must_fill | 0 | 2 | **FAIL** |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | ∅ (insufficient_evidence) | **FAIL** |
| protective_factors | checkbox_constraints | include [FAMILY_CONNECTION], exclude [CHILDREN_IN_HOME, PETS, RELIGIOUS_BELIEFS] | ∅ (insufficient_evidence) | **FAIL** |
| substances | checkbox_constraints | include [ALCOHOL], exclude [CANNABIS, NONE_REPORTED, OPIOIDS, SEDATIVES, STIMULANTS] | ∅ (rejected) | **FAIL** |
| emergency_contact_name | text_match | equals case_insensitive Keisha Moore | ∅ (rejected) | **FAIL** |
| next_appointment | text_match | equals date 2026-10-08 | ∅ (rejected) | **FAIL** |
| phq9_score | derived | 10 | 12 | **FAIL** |
| alcohol_frequency | must_fill | TWO_TO_THREE_PER_WEEK | TWO_TO_THREE_PER_WEEK | ok |
| case_number | must_fill | AB-207791 | AB-207791 | ok |
| children_in_home | must_fill | NO | NO | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | OTHER | OTHER | ok |
| employment_status | must_fill | UNEMPLOYED | UNEMPLOYED | ok |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| gad7_status | must_fill | DECLINED | DECLINED | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | STABLE | STABLE | ok |
| insurance_type | must_fill | UNINSURED | UNINSURED | ok |
| language_combo | must_fill | ENGLISH | ENGLISH | ok |
| phq9_1 | must_fill | 1 | 1 | ok |
| phq9_2 | must_fill | 2 | 2 | ok |
| phq9_3 | must_fill | 2 | 2 | ok |
| phq9_4 | must_fill | 2 | 2 | ok |
| phq9_6 | must_fill | 2 | 2 | ok |
| phq9_7 | must_fill | 1 | 1 | ok |
| phq9_8 | must_fill | 0 | 0 | ok |
| phq9_9 | must_fill | 0 | 0 | ok |
| phq9_difficulty | must_fill | SOMEWHAT | SOMEWHAT | ok |
| pronouns | must_fill | HE_HIM | HE_HIM | ok |
| referral_source | must_fill | SELF | SELF | ok |
| referrals_made | must_fill | [BENEFITS] | [BENEFITS] | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_ideation (risk) | must_fill | NONE | NONE | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| tobacco_use | must_fill | CURRENT | CURRENT | ok |
| transportation | must_fill | UNRELIABLE | UNRELIABLE | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| client_preferred_name | acceptable | one of [null, Marcus] | Marcus | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED, INDEPENDENT] | INDEPENDENT | ok |
| si_frequency (risk) | acceptable | one of [null, NONE] | NONE | ok |
| si_intent (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| income_sources | checkbox_constraints | include [UNEMPLOYMENT_INSURANCE], exclude [CHILD_SUPPORT, NONE, SNAP, SSDI, SSI, TANF, WAGES] | [UNEMPLOYMENT_INSURANCE] | ok |
| support_system | checkbox_constraints | include [FAMILY, FRIENDS], exclude [FAITH_COMMUNITY, NONE, PEER_GROUP] | [FAMILY, FRIENDS] | ok |
| address_city | text_match | equals case_insensitive Riverton | Riverton | ok |
| address_line | text_match | contains case_insensitive [1457 birch, 21] | 1457 Birch Avenue, Unit 21 | ok |
| address_zip | text_match | equals digits 92509 | 92509 | ok |
| client_dob | text_match | equals date 1992-07-12 | 1992-07-12 | ok |
| client_first_name | text_match | equals case_insensitive Marcus | Marcus | ok |
| client_goal | text_match | contains case_insensitive [job by christmas, sleep back] | Get a job by Christmas and get my sleep back. | ok |
| client_last_name | text_match | equals case_insensitive Bell | Bell | ok |
| contact_phone | text_match | equals digits 9515550183 | 951-555-0183 | ok |
| emergency_contact_phone | text_match | equals digits 9515550129 | 951-555-0129 | ok |
| mse_mood | text_match | contains case_insensitive stressed | Not fine. Stressed. Kind of flat, I guess. Like nothing's that fun. | ok |
| sleep_hours | text_match | equals digits 4 | Four hours | ok |
| phq9_severity | derived | MODERATE | MODERATE | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 172 | 2 |
| interventions | filled | 210 | 5 |
| plan | filled | 149 | 3 |
| presenting_problem | filled | 221 | 4 |
| psychosocial_history | filled | 233 | 5 |
| risk_narrative (risk) | filled | 389 | 7 |

## Rejections by reason

- quote_not_found: 5
- segment_not_found: 2

Statuses: clinician_only 11 · derived 2 · filled 56 · insufficient_evidence 29 · rejected 6

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 6827 tokens
- requests 2..N prefill: 11705 tokens (mean 1.95% of request 1)
- misses (a request after the first 1 with prefill > 3413 tokens): 0 → pass

Summed model time: 165543 ms
