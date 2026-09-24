# Extraction eval: session-08-long.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | pass | 0 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | FAIL | 78.2% (68/87) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 13568, mean after = 341 |

Review load (accepted, but the HUD must flag for review): 0

## Blank violations (0)

None.

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| zip_corrected_late | pass |  |  |
| lethal_means_asked_has_access | pass |  | risk_narrative |
| passive_si_frequency | **FAIL** | phq9_9 |  |
| prior_attempt_once | pass |  | risk_narrative |
| safety_plan_updated | pass |  |  |
| clinician_only_spoken | pass |  |  |
| roi_psychiatrist_only | pass |  |  |
| family_members_meds_and_problems | pass |  | psychosocial_history |
| opioids_historical | pass |  |  |
| prescribed_trazodone_not_sedative_use | pass |  |  |
| lamotrigine_partial_but_iadl_independent | pass |  |  |
| adl_motivation_not_ability | **FAIL** | adl_dressing, adl_eating |  |
| finances_assisted | pass |  |  |
| skipping_lunch_food_insecurity | **FAIL** | phq9_5, adl_eating |  |
| daughter_not_in_home | pass |  |  |
| family_court_legal | pass |  |  |
| income_three_sources | **FAIL** | employment_status |  |
| dual_coverage | **FAIL** | insurance_type |  |
| gender_explicit | pass |  |  |
| referral_source_peer_group | pass |  |  |
| instrument_totals_not_spoken | **FAIL** | phq9_score, phq9_severity, gad7_score, gad7_severity |  |
| risk_level_never_stated | pass |  | risk_narrative |
| worker_only_metadata | **FAIL** | follow_up_interval, next_appointment |  |

## Must-fill accuracy: 78.2% (68/87)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| adl_dressing | must_fill | INDEPENDENT | ∅ (insufficient_evidence) | **FAIL** |
| adl_eating | must_fill | INDEPENDENT | ∅ (insufficient_evidence) | **FAIL** |
| employment_status | must_fill | DISABLED | ∅ (rejected) | **FAIL** |
| follow_up_interval | must_fill | WEEKLY | ∅ (rejected) | **FAIL** |
| gad7_3 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| gad7_4 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| gad7_6 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| housing_status | must_fill | STABLE | ∅ (rejected) | **FAIL** |
| phq9_4 | must_fill | 3 | ∅ (rejected) | **FAIL** |
| phq9_5 | must_fill | 1 | ∅ (rejected) | **FAIL** |
| phq9_7 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| phq9_8 | must_fill | 0 | ∅ (rejected) | **FAIL** |
| phq9_9 | must_fill | 2 | ∅ (rejected) | **FAIL** |
| insurance_type | acceptable | one of [MEDICARE, MEDI_CAL] | ∅ (rejected) | **FAIL** |
| next_appointment | text_match | equals date 2026-11-03 | ∅ (rejected) | **FAIL** |
| gad7_score | derived | 8 | ∅ (insufficient_evidence) | **FAIL** |
| gad7_severity | derived | MILD | ∅ (insufficient_evidence) | **FAIL** |
| phq9_score | derived | 17 | ∅ (insufficient_evidence) | **FAIL** |
| phq9_severity | derived | MODERATELY_SEVERE | ∅ (insufficient_evidence) | **FAIL** |
| adl_bathing | must_fill | INDEPENDENT | INDEPENDENT | ok |
| alcohol_frequency | must_fill | MONTHLY_OR_LESS | MONTHLY_OR_LESS | ok |
| case_number | must_fill | AB-502268 | AB-502268 | ok |
| children_in_home | must_fill | YES | YES | ok |
| consent_telehealth | must_fill | VERBAL | VERBAL | ok |
| contact_ok_voicemail | must_fill | YES | YES | ok |
| emergency_contact_relationship | must_fill | SIBLING | SIBLING | ok |
| food_security | must_fill | INSECURE | INSECURE | ok |
| gad7_1 | must_fill | 1 | 1 | ok |
| gad7_2 | must_fill | 1 | 1 | ok |
| gad7_5 | must_fill | 0 | 0 | ok |
| gad7_7 | must_fill | 1 | 1 | ok |
| gad7_status | must_fill | COMPLETED | COMPLETED | ok |
| gender_identity | must_fill | WOMAN | WOMAN | ok |
| hi_ideation (risk) | must_fill | NONE | NONE | ok |
| iadl_finances | must_fill | NEEDS_ASSISTANCE | NEEDS_ASSISTANCE | ok |
| iadl_medications | must_fill | INDEPENDENT | INDEPENDENT | ok |
| iadl_transport | must_fill | INDEPENDENT | INDEPENDENT | ok |
| income_sources | must_fill | [CHILD_SUPPORT, SNAP, SSDI] | [SNAP, SSDI, CHILD_SUPPORT] | ok |
| interpreter_needed | must_fill | NO | NO | ok |
| language_combo | must_fill | ENGLISH | ENGLISH | ok |
| legal_involvement | must_fill | FAMILY_COURT | FAMILY_COURT | ok |
| living_situation | must_fill | WITH_FAMILY | WITH_FAMILY | ok |
| medication_adherence | must_fill | PARTIAL | PARTIAL | ok |
| phq9_1 | must_fill | 2 | 2 | ok |
| phq9_2 | must_fill | 2 | 2 | ok |
| phq9_3 | must_fill | 3 | 3 | ok |
| phq9_6 | must_fill | 2 | 2 | ok |
| phq9_difficulty | must_fill | VERY | VERY | ok |
| pronouns | must_fill | SHE_HER | SHE_HER | ok |
| referral_source | must_fill | COMMUNITY_ORG | COMMUNITY_ORG | ok |
| referrals_made | must_fill | [BENEFITS, LEGAL_AID] | [BENEFITS, LEGAL_AID] | ok |
| release_of_info | must_fill | [PSYCHIATRIST] | [PSYCHIATRIST] | ok |
| safety_plan (risk) | must_fill | UPDATED | UPDATED | ok |
| session_type | must_fill | INTAKE | INTAKE | ok |
| si_frequency (risk) | must_fill | MORE_THAN_HALF | MORE_THAN_HALF | ok |
| si_ideation (risk) | must_fill | PASSIVE | PASSIVE | ok |
| si_intent (risk) | must_fill | NO | NO | ok |
| si_means (risk) | must_fill | HAS_ACCESS | HAS_ACCESS | ok |
| si_plan (risk) | must_fill | NO | NO | ok |
| si_prior_attempts (risk) | must_fill | ONE | ONE | ok |
| substance_tx_history | must_fill | OUTPATIENT | OUTPATIENT | ok |
| tobacco_use | must_fill | NEVER | NEVER | ok |
| transportation | must_fill | UNRELIABLE | UNRELIABLE | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED, INDEPENDENT] | INDEPENDENT | ok |
| hi_plan (risk) | acceptable | one of [null, NO, NOT_ASSESSED] | NO | ok |
| crisis_resources | checkbox_constraints | include [COUNTY_CRISIS, LINE_988], exclude [NONE, WARMLINE] | [LINE_988, COUNTY_CRISIS] | ok |
| protective_factors | checkbox_constraints | include [CHILDREN_IN_HOME, PETS, RELIGIOUS_BELIEFS, TREATMENT_ENGAGEMENT], exclude [] | [FAMILY_CONNECTION, CHILDREN_IN_HOME, FUTURE_ORIENTATION, RELIGIOUS_BELIEFS, TREATMENT_ENGAGEMENT, PETS] | ok |
| substances | checkbox_constraints | include [CANNABIS], exclude [NONE_REPORTED, OPIOIDS, SEDATIVES, STIMULANTS] | [ALCOHOL, CANNABIS] | ok |
| support_system | checkbox_constraints | include [FAITH_COMMUNITY, FAMILY, PEER_GROUP], exclude [NONE] | [FAMILY, FAITH_COMMUNITY, PEER_GROUP] | ok |
| address_city | text_match | equals case_insensitive Northgate | Northgate | ok |
| address_line | text_match | contains case_insensitive [3301 kestrel, 210] | 3301 Kestrel Way, Apartment 210, Northgate, 95404 | ok |
| address_zip | text_match | equals digits 95404 | 95404 | ok |
| client_dob | text_match | equals date 1981-01-30 | 1981-01-30 | ok |
| client_first_name | text_match | equals case_insensitive Jolene | Jolene | ok |
| client_goal | text_match | contains case_insensitive [winter, hospital] | I want to get through the winter without ending up in the hospital. | ok |
| client_last_name | text_match | equals case_insensitive Marsh | Marsh | ok |
| client_preferred_name | text_match | equals case_insensitive Jo | Jo | ok |
| contact_email | text_match | equals case_insensitive jolene.marsh@example.com | jolene.marsh@example.com | ok |
| contact_phone | text_match | equals digits 7075550153 | 707-555-0153 | ok |
| current_medications | text_match | contains case_insensitive [lamotrigine, 200, trazodone, levothyroxine] | Lamotrigine, 200 milligrams, in the morning. Trazodone, 50 milligrams at night, for sleep. And levothyroxine, 75 micrograms. | ok |
| emergency_contact_name | text_match | equals case_insensitive Paula Greene | Paula Greene | ok |
| emergency_contact_phone | text_match | equals digits 7075550164 | 707-555-0164 | ok |
| insurance_member_id | text_match | equals digits 91402837 | 91402837 | ok |
| medical_conditions | text_match | contains case_insensitive thyroid | Hypothyroidism, prediabetic (borderline), and bipolar II. | ok |
| mse_mood | text_match | contains case_insensitive [heavy, wading through mud] | Heavy. Like I'm wading through mud. | ok |
| pcp_name | text_match | contains case_insensitive ross | Dr. Imani Ross, Northgate Family Health | ok |
| sleep_hours | text_match | equals digits 1011 | 10-11 | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 263 | 4 |
| interventions | filled | 247 | 7 |
| plan | filled | 293 | 6 |
| presenting_problem | filled | 407 | 6 |
| psychosocial_history | filled | 405 | 6 |
| risk_narrative (risk) | filled | 402 | 7 |

## Rejections by reason

- question_mismatch: 3
- quote_not_found: 9
- segment_not_found: 2

Statuses: clinician_only 11 · filled 74 · insufficient_evidence 6 · rejected 13

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 13568 tokens
- requests 2..N prefill: 30018 tokens (mean 2.51% of request 1)
- misses (a request after the first 1 with prefill > 6784 tokens): 0 → pass

Summed model time: 299586 ms
