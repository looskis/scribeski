# Extraction eval: session-04-misreflection.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | FAIL | 5 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | FAIL | 85.7% (42/49) |
| prefix cache (requests 2..N ≤ 5% of request 1) | pass | 26292 total vs 27367 allowed |

## Blank violations (5)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| client_first_name | must_leave_blank | blank | Hal | **FAIL** |
| phq9_3 | must_leave_blank | blank | 2 | **FAIL** |
| phq9_9 | must_leave_blank | blank | 1 | **FAIL** |
| income_sources | must_leave_blank | blank | [SSI] | **FAIL** |
| food_security | must_leave_blank | blank | SECURE | **FAIL** |

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| who_moved_in | pass |  | psychosocial_history |
| drinking_less_not_more | pass |  | presenting_problem |
| time_since_death | manual |  | presenting_problem |
| sleep_in_bed_vs_asleep | pass |  |  |
| grief_group_not_attending | pass |  | client_strengths |
| nephew_not_son | pass |  | psychosocial_history |
| medication_stopped_by_doctor | pass |  |  |
| adl_misreflections | **FAIL** | adl_dressing, iadl_transport |  |
| transportation_misreflection | pass |  |  |
| social_security_not_ssi | **FAIL** | income_sources |  |
| gad7_item2_misreflection | **FAIL** | gad7_2, gad7_score, gad7_severity |  |
| si_passive_not_active | pass |  | risk_narrative |
| safety_plan_reviewed | pass |  |  |
| phq9_not_given | **FAIL** | phq9_3, phq9_9 |  |
| gad7_total_not_spoken | **FAIL** | gad7_score, gad7_severity |  |
| follow_up_identity_fields | **FAIL** | client_first_name |  |
| no_referrals | pass |  |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | pass |  |  |

## Must-fill accuracy: 85.7% (42/49)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| adl_dressing | must_fill | INDEPENDENT | ∅ (rejected) | **FAIL** |
| gad7_2 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| gad7_4 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| gad7_6 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| iadl_transport | must_fill | NEEDS_ASSISTANCE | DEPENDENT | **FAIL** |
| gad7_score | derived | 9 | ∅ (insufficient_evidence) | **FAIL** |
| gad7_severity | derived | MILD | ∅ (insufficient_evidence) | **FAIL** |
| adl_bathing | must_fill | INDEPENDENT | INDEPENDENT | ok |
| adl_eating | must_fill | INDEPENDENT | INDEPENDENT | ok |
| adl_mobility | must_fill | NEEDS_ASSISTANCE | NEEDS_ASSISTANCE | ok |
| alcohol_frequency | must_fill | MONTHLY_OR_LESS | MONTHLY_OR_LESS | ok |
| children_in_home | must_fill | NO | NO | ok |
| employment_status | must_fill | NOT_IN_LABOR_FORCE | NOT_IN_LABOR_FORCE | ok |
| follow_up_interval | must_fill | BIWEEKLY | BIWEEKLY | ok |
| gad7_1 | must_fill | 1 | 1 | ok |
| gad7_3 | must_fill | 2 | 2 | ok |
| gad7_5 | must_fill | 0 | 0 | ok |
| gad7_7 | must_fill | 2 | 2 | ok |
| gad7_status | must_fill | COMPLETED | COMPLETED | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | STABLE | STABLE | ok |
| iadl_finances | must_fill | INDEPENDENT | INDEPENDENT | ok |
| iadl_medications | must_fill | INDEPENDENT | INDEPENDENT | ok |
| living_situation | must_fill | WITH_FAMILY | WITH_FAMILY | ok |
| medication_adherence | must_fill | ADHERENT | ADHERENT | ok |
| safety_plan (risk) | must_fill | REVIEWED | REVIEWED | ok |
| session_type | must_fill | FOLLOW_UP | FOLLOW_UP | ok |
| si_frequency (risk) | must_fill | SEVERAL_DAYS | SEVERAL_DAYS | ok |
| si_ideation (risk) | must_fill | PASSIVE | PASSIVE | ok |
| si_intent (risk) | must_fill | NO | NO | ok |
| si_plan (risk) | must_fill | NO | NO | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| transportation | must_fill | RELIABLE | RELIABLE | ok |
| client_last_name | acceptable | one of [null, Jennings] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | [LINE_988] | ok |
| protective_factors | checkbox_constraints | include [FAMILY_CONNECTION, PETS], exclude [CHILDREN_IN_HOME, RELIGIOUS_BELIEFS] | [FAMILY_CONNECTION, TREATMENT_ENGAGEMENT, PETS] | ok |
| referrals_made | checkbox_constraints | include [], exclude [BENEFITS, FOOD_BANK, HOUSING_NAV, LEGAL_AID, PSYCHIATRY, SUBSTANCE_TX] | ∅ (insufficient_evidence) | ok |
| substances | checkbox_constraints | include [ALCOHOL], exclude [CANNABIS, NONE_REPORTED, OPIOIDS, SEDATIVES, STIMULANTS] | [ALCOHOL] | ok |
| support_system | checkbox_constraints | include [FAMILY, FRIENDS], exclude [FAITH_COMMUNITY, NONE, PEER_GROUP] | [FAMILY, FRIENDS] | ok |
| client_goal | text_match | contains case_insensitive eat at the table | I'd like to sleep more than five hours. And eat at the table again, instead of in front of the TV. | ok |
| client_preferred_name | text_match | equals case_insensitive Hal | Hal | ok |
| current_medications | text_match | contains case_insensitive [lisinopril, 10] | lisinopril, 10mg every morning | ok |
| medical_conditions | text_match | contains case_insensitive arthritis | Blood pressure and arthritis in knees. | ok |
| mse_mood | text_match | contains case_insensitive lonesome | Lonesome. And tired. Mostly lonesome. | ok |
| next_appointment | text_match | equals date 2026-10-20 | 2026-10-20 | ok |
| pcp_name | text_match | contains case_insensitive halvorsen | Dr. Halvorsen, Mercy Family Medicine | ok |
| sleep_hours | text_match | equals digits 5 | 5 | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 274 | 7 |
| interventions | filled | 215 | 5 |
| plan | filled | 181 | 4 |
| presenting_problem | filled | 356 | 4 |
| psychosocial_history | filled | 434 | 6 |
| risk_narrative (risk) | filled | 800 | 11 |

## Rejections by reason

- question_mismatch: 1
- quote_not_found: 4

Statuses: clinician_only 11 · filled 51 · insufficient_evidence 37 · rejected 5

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 5068 tokens
- requests 2..N prefill: 21224 tokens (mean 4.76% of request 1)
- allowed total: 27367 · actual total: 26292 → pass

Summed model time: 166124 ms
