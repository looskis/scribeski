# Extraction eval: session-07-third-party.json

**Result: PASS**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | pass | 94.2% (65/69) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 5337, mean after = 240 |

## Blank violations (0)

None.

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| mother_diabetes_not_client | pass |  |  |
| sister_drinking_not_client | pass |  |  |
| partner_cannabis_not_client | pass |  |  |
| partner_probation_not_client | pass |  |  |
| sister_si_not_client | pass |  | risk_narrative |
| sister_safety_plan_not_client | pass |  |  |
| mother_benefits_not_client | pass |  |  |
| mother_faith_not_client | pass |  | client_strengths |
| mother_care_needs_not_client_adl | **FAIL** | iadl_medications |  |
| sister_not_emergency_contact | pass |  |  |
| son_in_home | pass |  |  |
| household_mixed | pass |  |  |
| al_anon_not_a_referral_option | pass |  |  |
| phq2_only | pass |  |  |
| gad7_complete | pass |  |  |
| voicemail_declined | pass |  |  |
| pronouns_not_asked | pass |  |  |
| lethal_means_not_asked | pass |  | risk_narrative |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | pass |  |  |

## Must-fill accuracy: 94.2% (65/69)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| tobacco_use | must_fill | NEVER | ∅ (rejected) | **FAIL** |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | INDEPENDENT | **FAIL** |
| mse_mood | text_match | contains case_insensitive stretched thin | I'm not depressed, I don't think. I'm just — tired and worried. | **FAIL** |
| sleep_hours | text_match | equals digits 6 | ∅ (rejected) | **FAIL** |
| alcohol_frequency | must_fill | NEVER | NEVER | ok |
| case_number | must_fill | AB-440126 | AB-440126 | ok |
| children_in_home | must_fill | YES | YES | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | NO | NO | ok |
| emergency_contact_relationship | must_fill | FRIEND | FRIEND | ok |
| employment_status | must_fill | EMPLOYED_FT | EMPLOYED_FT | ok |
| follow_up_interval | must_fill | BIWEEKLY | BIWEEKLY | ok |
| food_security | must_fill | SECURE | SECURE | ok |
| gad7_1 | must_fill | 2 | 2 | ok |
| gad7_2 | must_fill | 2 | 2 | ok |
| gad7_3 | must_fill | 3 | 3 | ok |
| gad7_4 | must_fill | 2 | 2 | ok |
| gad7_5 | must_fill | 1 | 1 | ok |
| gad7_6 | must_fill | 2 | 2 | ok |
| gad7_7 | must_fill | 1 | 1 | ok |
| gad7_status | must_fill | COMPLETED | COMPLETED | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| housing_status | must_fill | STABLE | STABLE | ok |
| insurance_type | must_fill | PRIVATE | PRIVATE | ok |
| language_combo | must_fill | ENGLISH | ENGLISH | ok |
| legal_involvement | must_fill | NONE | NONE | ok |
| medication_adherence | must_fill | ADHERENT | ADHERENT | ok |
| phq9_1 | must_fill | 1 | 1 | ok |
| phq9_2 | must_fill | 1 | 1 | ok |
| referral_source | must_fill | SELF | SELF | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_ideation (risk) | must_fill | NONE | NONE | ok |
| si_prior_attempts (risk) | must_fill | NONE | NONE | ok |
| substance_tx_history | must_fill | NONE | NONE | ok |
| substances | must_fill | [NONE_REPORTED] | [NONE_REPORTED] | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | NOT_ASSESSED | ok |
| interpreter_needed | acceptable | one of [null, NO] | NO | ok |
| living_situation | acceptable | one of [WITH_FAMILY, WITH_PARTNER] | WITH_PARTNER | ok |
| si_frequency (risk) | acceptable | one of [null, NONE] | NONE | ok |
| si_intent (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| transportation | acceptable | one of [null, RELIABLE] | RELIABLE | ok |
| crisis_resources | checkbox_constraints | include [LINE_988], exclude [COUNTY_CRISIS, MOBILE_CRISIS, NONE, WARMLINE] | [LINE_988] | ok |
| income_sources | checkbox_constraints | include [WAGES], exclude [CHILD_SUPPORT, NONE, SNAP, SSDI, SSI, TANF, UNEMPLOYMENT_INSURANCE] | [WAGES] | ok |
| protective_factors | checkbox_constraints | include [CHILDREN_IN_HOME], exclude [PETS, RELIGIOUS_BELIEFS] | [CHILDREN_IN_HOME, FUTURE_ORIENTATION] | ok |
| support_system | checkbox_constraints | include [FRIENDS], exclude [FAITH_COMMUNITY, NONE, PEER_GROUP] | [FRIENDS] | ok |
| address_city | text_match | equals case_insensitive Glenmore | Glenmore | ok |
| address_line | text_match | contains case_insensitive 1920 sycamore | 1920 Sycamore Lane, Glenmore 91776 | ok |
| address_zip | text_match | equals digits 91776 | 91776 | ok |
| client_dob | text_match | equals date 1995-05-21 | 1995-05-21 | ok |
| client_first_name | text_match | equals case_insensitive Brianna | Brianna | ok |
| client_goal | text_match | contains case_insensitive take care of myself | I'd take care of myself for once. Not just everybody else. | ok |
| client_last_name | text_match | equals case_insensitive Kowalski | Kowalski | ok |
| contact_phone | text_match | equals digits 6265550172 | 626-555-0172 | ok |
| current_medications | text_match | contains case_insensitive [sumatriptan, 50] | Sumatriptan 50 milligrams as needed | ok |
| emergency_contact_name | text_match | equals case_insensitive Ana Delgado | Ana Delgado | ok |
| emergency_contact_phone | text_match | equals digits 6265550141 | 626-555-0141 | ok |
| medical_conditions | text_match | contains case_insensitive migraine | Migraines | ok |
| next_appointment | text_match | equals date 2026-11-05 | 2026-11-05 | ok |
| pcp_name | text_match | contains case_insensitive feld | Dr. Feld, Glenmore Medical Group | ok |
| gad7_score | derived | 13 | 13 | ok |
| gad7_severity | derived | MODERATE | MODERATE | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 237 | 2 |
| interventions | filled | 239 | 5 |
| plan | filled | 232 | 4 |
| presenting_problem | filled | 380 | 6 |
| psychosocial_history | filled | 439 | 7 |
| risk_narrative (risk) | filled | 270 | 4 |

## Rejections by reason

- missing_question_context: 1
- question_mismatch: 1
- question_not_asked: 1
- quote_not_found: 2

Statuses: clinician_only 11 · derived 2 · filled 65 · insufficient_evidence 22 · rejected 4

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 5337 tokens
- requests 2..N prefill: 21165 tokens (mean 4.51% of request 1)
- misses (a request after the first 1 with prefill > 2668 tokens): 0 → pass

Summed model time: 172006 ms
