# Extraction eval: session-02-es.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | FAIL | 5 |
| risk-field errors = 0 | FAIL | 1 |
| must-fill accuracy ≥ 90% | FAIL | 85.3% (58/68) |
| prefix cache (requests 2..N ≤ 5% of request 1) | pass | 27710 total vs 35024 allowed |

## Blank violations (5)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| gender_identity | must_leave_blank | blank | WOMAN | **FAIL** |
| safety_plan (risk) | must_leave_blank | blank | NOT_INDICATED | **FAIL** |
| legal_involvement | must_leave_blank | blank | NONE | **FAIL** |
| substance_tx_history | must_leave_blank | blank | NONE | **FAIL** |
| referrals_made | must_leave_blank | blank | [NONE] | **FAIL** |

## Risk-field errors (1)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| safety_plan (risk) | must_leave_blank | blank | NOT_INDICATED | **FAIL** |

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| spanish_session_bilingual_worker | pass |  |  |
| spanish_evidence_english_note | **FAIL** | mse_mood, client_goal | presenting_problem, psychosocial_history, interventions, plan, client_strengths, risk_narrative |
| spanish_frequency_scale | **FAIL** | phq9_4, phq9_7 |  |
| phq9_total_not_spoken | **FAIL** | phq9_score, phq9_severity |  |
| gad7_never_mentioned | pass |  |  |
| si_denied_no_safety_plan | **FAIL** | safety_plan | risk_narrative |
| lethal_means_not_asked | pass |  | risk_narrative |
| risk_level_never_stated | pass |  | risk_narrative |
| grief_group_not_an_option | **FAIL** | referrals_made |  |
| faith_is_a_support_here | pass |  | client_strengths |
| grandchildren_not_in_home | pass |  |  |
| no_email | pass |  |  |
| case_number_absent | pass |  |  |
| worker_only_metadata | **FAIL** | follow_up_interval |  |

## Must-fill accuracy: 85.3% (58/68)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| follow_up_interval | must_fill | BIWEEKLY | ∅ (rejected) | **FAIL** |
| phq9_4 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| phq9_7 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| client_goal | text_match | contains case_insensitive sleep better | Quiero volver a tener ganas de hacer mis cosas. Y dormir mejor. Nada más eso. | **FAIL** |
| current_medications | text_match | contains case_insensitive [metformin, 500] | La metformina. De quinientos miligramos, dos veces al día. | **FAIL** |
| mse_mood | text_match | contains case_insensitive [sad, tired] | Triste. Muy triste, y cansada. | **FAIL** |
| phq9_score | derived | 12 | ∅ (insufficient_evidence) | **FAIL** |
| phq9_severity | derived | MODERATE | ∅ (insufficient_evidence) | **FAIL** |
| alcohol_frequency | must_fill | NEVER | NEVER | ok |
| children_in_home | must_fill | NO | NO | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | CHILD | CHILD | ok |
| employment_status | must_fill | EMPLOYED_PT | EMPLOYED_PT | ok |
| food_security | must_fill | SECURE | SECURE | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | STABLE | STABLE | ok |
| insurance_type | must_fill | MEDI_CAL | MEDI_CAL | ok |
| interpreter_needed | must_fill | NO | NO | ok |
| language_combo | must_fill | SPANISH | SPANISH | ok |
| living_situation | must_fill | WITH_PARTNER | WITH_PARTNER | ok |
| medication_adherence | must_fill | ADHERENT | ADHERENT | ok |
| phq9_1 | must_fill | 2 | 2 | ok |
| phq9_2 | must_fill | 3 | 3 | ok |
| phq9_3 | must_fill | 2 | 2 | ok |
| phq9_5 | must_fill | 1 | 1 | ok |
| phq9_6 | must_fill | 1 | 1 | ok |
| phq9_8 | must_fill | 0 | 0 | ok |
| phq9_9 | must_fill | 0 | 0 | ok |
| phq9_difficulty | must_fill | SOMEWHAT | SOMEWHAT | ok |
| pronouns | must_fill | SHE_HER | SHE_HER | ok |
| referral_source | must_fill | PCP | PCP | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_ideation (risk) | must_fill | NONE | NONE | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| substances | must_fill | [NONE_REPORTED] | [NONE_REPORTED] | ok |
| tobacco_use | must_fill | NEVER | NEVER | ok |
| transportation | must_fill | RELIABLE | RELIABLE | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_frequency (risk) | acceptable | one of [null, NONE] | NONE | ok |
| si_intent (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | [LINE_988] | ok |
| income_sources | checkbox_constraints | include [WAGES], exclude [CHILD_SUPPORT, NONE, SNAP, SSDI, SSI, TANF, UNEMPLOYMENT_INSURANCE] | [WAGES] | ok |
| protective_factors | checkbox_constraints | include [FAMILY_CONNECTION, RELIGIOUS_BELIEFS], exclude [CHILDREN_IN_HOME, PETS] | [FAMILY_CONNECTION, FUTURE_ORIENTATION, RELIGIOUS_BELIEFS] | ok |
| support_system | checkbox_constraints | include [FAITH_COMMUNITY, FAMILY], exclude [NONE, PEER_GROUP] | [FAMILY, FAITH_COMMUNITY] | ok |
| address_city | text_match | equals case_insensitive Linwood | Linwood | ok |
| address_line | text_match | contains case_insensitive 418 olive | 418 Olive Street, Linwood | ok |
| address_zip | text_match | equals digits 92507 | 92507 | ok |
| client_dob | text_match | equals date 1973-11-14 | 1973-11-14 | ok |
| client_first_name | text_match | equals case_insensitive Guadalupe | Guadalupe | ok |
| client_last_name | text_match | equals case_insensitive Torres | Torres | ok |
| client_preferred_name | text_match | equals case_insensitive Lupe | Lupe | ok |
| contact_phone | text_match | equals digits 9095550162 | 909-555-0162 | ok |
| emergency_contact_name | text_match | equals case_insensitive Julio Torres | Julio Torres | ok |
| emergency_contact_phone | text_match | equals digits 9095550177 | 909-555-0177 | ok |
| medical_conditions | text_match | contains case_insensitive diabetes | Diabetes (for about six years) | ok |
| next_appointment | text_match | equals date 2026-10-13 | 2026-10-13 | ok |
| pcp_name | text_match | contains case_insensitive nguyen | Doctora Nguyen, clínica familiar de Linwood | ok |
| sleep_hours | text_match | equals digits 5 | 5 | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 150 | 3 |
| interventions | filled | 680 | 14 |
| plan | filled | 272 | 4 |
| presenting_problem | filled | 252 | 5 |
| psychosocial_history | filled | 603 | 9 |
| risk_narrative (risk) | filled | 467 | 7 |

## Rejections by reason

- quote_not_found: 2
- segment_not_found: 2

Statuses: clinician_only 11 · filled 68 · insufficient_evidence 22 · rejected 3

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 6486 tokens
- requests 2..N prefill: 21224 tokens (mean 3.72% of request 1)
- allowed total: 35024 · actual total: 27710 → pass

Summed model time: 214192 ms
