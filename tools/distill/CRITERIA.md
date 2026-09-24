# P1.9 acceptance criteria (written 2026-09-23, before any classifier was scored)

**Scope:** the 63 choice fields the classifier tier answers (`common.SCOPE`: 47 select/checkbox
fields from `tools/synth/fields.mjs` + PHQ-9 and GAD-7 items). Scored with `common.score`,
which mirrors `Scorer.swift` restricted to that scope.

**Test sets.** Never used for training, model selection, thresholds or prompt changes:
- corpus: every `fixtures/corpus/session-*` with an expected file, plus `fixtures/sample-session`
  (7 sessions as of today; `session-02-es` was removed from the corpus by someone else on 2026-09-22)
- held-out: `fixtures/corpus/heldout/` (2 sessions). Scored **once per final candidate**.

**Model selection** (architecture, epochs, confidence threshold, temperature) uses only a
synthetic validation split (15% of generated sessions, by session).

**Baseline:** Gemma 4 26B-A4B, the latest complete corpus run (`eval/runs/gemma26b-corpus-4`),
re-scored on the same checks: accuracy 88.0%, 4 unsafe, 0 unsafe in risk fields.

**Accept** a distilled classifier only if all of these hold:

| # | gate | corpus | held-out |
|---|---|---|---|
| 1 | unsafe answers in risk fields | 0 | 0 |
| 2 | unsafe answers, total | ≤ Gemma (4) | ≤ 2 |
| 3 | accuracy over all checks | ≥ Gemma − 2 pts (≥ 86.0%) | ≥ 85% |
| 4 | wall time for the 63 fields, on this Mac (M6, 32 GB) | ≤ ⅓ of Gemma's recorded time on the same fields (113 s/session mean in corpus-4, on an M1 Max 64 GB — a faster GPU, so this is conservative) | — |

Otherwise **reject**. "Unsafe" = a wrong value, or any value where the field must stay blank.
Abstaining (blank) is always allowed and counts as a safe blank, not as correct.

## Decisions made before the fine-tune's test look (2026-09-23)

- **bge-m3 baseline: rejected.** Final run (114 sessions, settings from val) on the corpus:
  67.3% accuracy, 33 unsafe (2 in risk fields), 9 must-leave-blank violations. Fails gates 1–3.
  This was its only test look.
- **Fine-tune: Qwen3-1.7B, full fine-tune at 32k on 1× H100.** Candidates: run 1 (95 sessions,
  4 epochs) and run 2 (114 sessions, 6 epochs, epochs 3–6). **Pick = lowest val NLL.**
- **What gets tested = the deployable artifact: 8-bit MLX on this Mac.** On val, 4-bit lost
  ~5 pts of thresholded accuracy (NLL 0.111 vs 0.079 bf16); 8-bit matched bf16 (0.081).
- Temperature and threshold: refit on val for the tested artifact, by the rule in `evaluate.py`.

# Round 2 (written 2026-09-23, before any round-2 model exists)

**Test set: the gold review** (`https://claude.ai/artifact/A147o5hoWmgvGjkKE4qkGH`): 20 real
clinic visits (PriMock57 / ACI-BENCH, held out of training and threshold tuning) + 15 AnnoMI
counselling sessions (never trained on). Gold = the human reviewer's answer for every listed
or added field; every other field = not established. 35 sessions × 63 fields.

The corpus and held-out pair are reported for continuity only, **flagged optimistic**: round-2
training data was designed around the corpus's round-1 failure classes.

Chosen on validation only (never on gold): epoch (lowest val NLL), temperature, abstention
threshold. Tested artifact: 8-bit MLX on this Mac.

**Accept** only if, on the gold set:

| # | gate |
|---|---|
| 1 | 0 unsafe answers in risk fields (si_*, hi_*, safety_plan) |
| 2 | unsafe answers ≤ 1.0% of all field answers (Gemma's round-1 corpus rate was 0.9%) |
| 3 | ≥ 75% of established (non-blank gold) fields answered exactly right |
| 4 | ≤ ⅓ of Gemma's recorded per-session time on these fields (≤ 37.7 s) |

Also reported, not gated: the previous model (round-1 run 2 epoch 3) on the same gold set;
DeepSeek-teacher agreement with gold on the clinic visits; style invariance on validation.

**Amended 2026-09-23, still before any round-2 model exists:** the clinic (GP) conversations were
carved out of training (kept in `data/clinic/` for a future doctor-intake model), so the 20 clinic
visits were dropped from the gold set too. **Gold = 30 AnnoMI counselling sessions**, pre-filled
by the round-1 model (not the model under test) plus a fixed 10-field checklist per session.
Round-2 training data is **synthetic only** (≈1,000 sessions, six writer models). Gates unchanged.

# Round 3 (written 2026-09-23, before any round-3 data or model exists)

Decisions by the product owner after round 2:
- **Passing mentions count** (an aside or a detail in a story establishes a fact).
- **Underconfidence is acceptable:** a blank means "needs review", which is safe; confidently
  wrong is what's dangerous.
- **`session_type` is supplied by the app:** out of the classifier and out of scoring.
- **Form gap:** when what was said fits no option (e.g. active suicidal thoughts, plan never
  assessed), the right answer is blank, for review.

**Test set:** 30 fresh AnnoMI counselling sessions, never seen by any model in this project's
training or tuning, hand-labelled on the review page. Pre-filled by round 2 (not the model under
test). The 30 round-2 gold sessions are now **development data**: their errors informed the
policy above.

Chosen on synthetic validation only: epoch (lowest val NLL), temperature, abstention threshold.
Tested artifact: 8-bit MLX on this Mac. Scope: 62 fields (63 minus `session_type`).

**Accept** only if, on the round-3 test set:

| # | gate |
|---|---|
| 1 | 0 unsafe answers in risk fields |
| 2 | unsafe answers ≤ 1.0% of all field answers |
| 3 | ≥ 50% of established facts answered exactly right (the rest may be blank = needs review) |
| 4 | ≤ ⅓ of Gemma's recorded per-session time (≤ 37.7 s) |

## Product-owner decision after round 3 (2026-09-23)

"As long as we're not confidently wrong, social workers can always fill in the rest, as they
already do." **Coverage (gate 3) is not a requirement.** The acceptance bar is the safety gates:
0 unsafe risk-field answers, and a low wrong-answer rate. This was decided **after** the round-3
results, on product grounds, not tuned to the model. Under it, round 3 passes gates 1, 2 and 4.
Open issue under the same standard: **precision when the model does answer is 14/21 (67%)**. The
next step is per-field thresholds tuned on the round-2 development sessions.
