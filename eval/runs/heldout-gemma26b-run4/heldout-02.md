# Extraction eval: heldout-02.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | FAIL | 1 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | FAIL | 87.5% (49/56) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 5311, mean after = 133 |

Review load (accepted, but the HUD must flag for review): 0

## Blank violations (1)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| client_first_name | must_leave_blank | blank | Dom | **FAIL** |

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| roommate_drinking_misreflection | pass |  | presenting_problem |
| vape_not_a_substance_option | pass |  |  |
| mother_rent_misreflection | pass |  | psychosocial_history |
| cafe_job_corrected | pass |  |  |
| sertraline_dose_corrected | pass |  |  |
| roommate_moves_out_hypothetical | pass |  |  |
| drop_stats_hypothetical | pass |  | plan |
| gender_identity_explicit | pass |  |  |
| active_si_no_plan | pass |  |  |
| prior_attempt_after_never | pass |  | risk_narrative |
| safety_plan_updated_with_warmline | pass |  |  |
| phq9_selected_items | pass |  |  |
| gad7_complete | **FAIL** | gad7_score, gad7_severity |  |
| prior_release_vague | **FAIL** | release_of_info |  |
| referral_psychiatry | pass |  |  |
| holiday_reschedule | pass |  |  |
| follow_up_no_identity | **FAIL** | client_first_name |  |
| supervisor_mentioned | pass |  |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | pass |  |  |

## Must-fill accuracy: 87.5% (49/56)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| gad7_2 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| protective_factors | checkbox_constraints | include [FUTURE_ORIENTATION], exclude [CHILDREN_IN_HOME, RELIGIOUS_BELIEFS] | ∅ (insufficient_evidence) | **FAIL** |
| release_of_info | checkbox_constraints | include [], exclude [FAMILY, NONE, PSYCHIATRIST, SCHOOL] | [NONE] | **FAIL** |
| pcp_name | text_match | contains case_insensitive ferris | ∅ (insufficient_evidence) | **FAIL** |
| gad7_score | derived | 15 | ∅ (insufficient_evidence) | **FAIL** |
| gad7_severity | derived | SEVERE | ∅ (insufficient_evidence) | **FAIL** |
| employment_status | must_fill | STUDENT | STUDENT | ok |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| gad7_1 | must_fill | 3 | 3 | ok |
| gad7_3 | must_fill | 2 | 2 | ok |
| gad7_4 | must_fill | 3 | 3 | ok |
| gad7_5 | must_fill | 1 | 1 | ok |
| gad7_6 | must_fill | 2 | 2 | ok |
| gad7_7 | must_fill | 2 | 2 | ok |
| gad7_status | must_fill | COMPLETED | COMPLETED | ok |
| gender_identity | must_fill | NONBINARY | NONBINARY | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | STABLE | STABLE | ok |
| living_situation | must_fill | ROOMMATES | ROOMMATES | ok |
| medication_adherence | must_fill | ADHERENT | ADHERENT | ok |
| phq9_1 | must_fill | 2 | 2 | ok |
| phq9_2 | must_fill | 2 | 2 | ok |
| phq9_9 | must_fill | 1 | 1 | ok |
| pronouns | must_fill | THEY_THEM | THEY_THEM | ok |
| referrals_made | must_fill | [PSYCHIATRY] | [PSYCHIATRY] | ok |
| safety_plan (risk) | must_fill | UPDATED | UPDATED | ok |
| session_type | must_fill | FOLLOW_UP | FOLLOW_UP | ok |
| si_frequency (risk) | must_fill | SEVERAL_DAYS | SEVERAL_DAYS | ok |
| si_ideation (risk) | must_fill | ACTIVE_NO_PLAN | ACTIVE_NO_PLAN | ok |
| si_intent (risk) | must_fill | NO | NO | ok |
| si_plan (risk) | must_fill | NO | NO | ok |
| si_prior_attempts (risk) | must_fill | ONE | ONE | ok |
| substance_tx_history | must_fill | OUTPATIENT | OUTPATIENT | ok |
| substances | must_fill | [NONE_REPORTED] | [NONE_REPORTED] | ok |
| tobacco_use | must_fill | CURRENT | CURRENT | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| alcohol_frequency | acceptable | one of [null, NEVER] | NEVER | ok |
| children_in_home | acceptable | one of [null, NO] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| medical_conditions | acceptable | one of [null] | ∅ (insufficient_evidence) | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| crisis_resources | checkbox_constraints | include [LINE_988, WARMLINE], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE] | [LINE_988, WARMLINE] | ok |
| income_sources | checkbox_constraints | include [SNAP], exclude [CHILD_SUPPORT, NONE, SSDI, SSI, TANF, UNEMPLOYMENT_INSURANCE, WAGES] | [SNAP] | ok |
| support_system | checkbox_constraints | include [FRIENDS, PEER_GROUP], exclude [FAITH_COMMUNITY, NONE] | [FRIENDS, PEER_GROUP] | ok |
| client_goal | text_match | contains case_insensitive [finals, panic attack] | Get through finals without a panic attack in the testing center. | ok |
| client_preferred_name | text_match | equals case_insensitive Dom | Dom | ok |
| current_medications | text_match | contains case_insensitive [sertraline, 150] | Sertraline 150mg | ok |
| mse_mood | text_match | contains case_insensitive [wired, tired] | Wired and tired. Like, my body's buzzing but I have no energy. | ok |
| next_appointment | text_match | equals date 2026-11-12 | 2026-11-12 | ok |
| sleep_hours | text_match | equals digits 6 | Maybe six hours | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 205 | 4 |
| interventions | filled | 280 | 5 |
| plan | filled | 268 | 6 |
| presenting_problem | filled | 327 | 3 |
| psychosocial_history | filled | 228 | 4 |
| risk_narrative (risk) | filled | 284 | 3 |

## Rejections by reason

- missing_question_context: 1
- quote_not_found: 1

Statuses: clinician_only 11 · filled 49 · insufficient_evidence 43 · rejected 1

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 5311 tokens
- requests 2..N prefill: 11705 tokens (mean 2.50% of request 1)
- misses (a request after the first 1 with prefill > 2655 tokens): 0 → pass

Summed model time: 391155 ms
