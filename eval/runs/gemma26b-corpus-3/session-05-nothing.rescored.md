# Extraction eval: session-05-nothing.json

**Result: FAIL**

## Gates

| gate | result | detail |
| --- | --- | --- |
| must_leave_blank violations = 0 | FAIL | 1 |
| risk-field errors = 0 | pass | 0 |
| must-fill accuracy ≥ 90% | pass | 94.4% (17/18) |
| prefix cache (no request re-processes the prefix) | pass | 0 misses; request 1 = 2374, mean after = 341 |

Review load (accepted, but the HUD must flag for review): 0

## Blank violations (1)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| protective_factors | must_leave_blank | blank | [TREATMENT_ENGAGEMENT] | **FAIL** |

## Risk-field errors (0)

None.

## Traps

| trap | result | failed fields | needs manual review |
| --- | --- | --- | --- |
| no_risk_inquiry | **FAIL** | protective_factors |  |
| prior_phq9_score | pass |  |  |
| prior_referrals_not_new | pass |  |  |
| pantry_not_food_security | **FAIL** | food_security |  |
| pay_stubs_not_employment_status | pass |  |  |
| housing_not_assessed | pass |  |  |
| bus_stop_not_transportation | pass |  |  |
| two_dates | pass |  |  |
| mood_in_passing | pass |  |  |
| no_identity_fields | pass |  |  |
| no_goal_stated | pass |  |  |
| risk_level_never_stated | pass |  |  |
| worker_only_metadata | pass |  |  |

## Must-fill accuracy: 94.4% (17/18)

| key | bucket | expected | actual | |
| --- | --- | --- | --- | --- |
| food_security | acceptable | one of [INSECURE, null] | SECURE | **FAIL** |
| follow_up_interval | must_fill | WEEKLY | WEEKLY | ok |
| session_type | must_fill | FOLLOW_UP | FOLLOW_UP | ok |
| adl_bathing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_dressing | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_eating | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| adl_mobility | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| hi_plan (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_finances | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_medications | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| iadl_transport | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_intent (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_means (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| si_plan (risk) | acceptable | one of [null, NOT_ASSESSED] | ∅ (insufficient_evidence) | ok |
| income_sources | checkbox_constraints | include [SNAP], exclude [NONE] | [SNAP] | ok |
| referrals_made | checkbox_constraints | include [], exclude [BENEFITS, FOOD_BANK, HOUSING_NAV, LEGAL_AID, PSYCHIATRY, SUBSTANCE_TX] | ∅ (insufficient_evidence) | ok |
| mse_mood | text_match | contains case_insensitive up and down | Up and down. Better than last time, though. Some days are okay. I'm just tired. | ok |
| next_appointment | text_match | equals date 2026-10-19 | 2026-10-19 | ok |

## Narratives (manual concept review)

| key | status | chars | citations |
| --- | --- | --- | --- |
| client_strengths | filled | 186 | 4 |
| interventions | filled | 142 | 3 |
| plan | filled | 223 | 4 |
| presenting_problem | insufficient_evidence | 0 | 0 |
| psychosocial_history | filled | 175 | 3 |

## Rejections by reason

- speaker_mismatch: 1

Statuses: clinician_only 11 · filled 11 · insufficient_evidence 81 · rejected 1

## Prefix cache

- requests: 89, parallel slots: 1
- request 1 prefill: 2374 tokens
- requests 2..N prefill: 30018 tokens (mean 14.37% of request 1)
- misses (a request after the first 1 with prefill > 1187 tokens): 0 → pass

Summed model time: 113383 ms
