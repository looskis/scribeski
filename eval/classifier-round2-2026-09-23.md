# Distilled classifier tier, round 2: **rejected** (2026-09-23)

**Decision: drop, again, for a different reason.** Round 1 hallucinated. Round 2 fixed that:
**zero unsafe risk-field answers, and 0.79% unsafe overall**. But on real counselling speech it
gets only **16% of the established facts right** (gate: ≥ 75%). No threshold rescues it: with
no abstention at all it reaches 40% and then fails the unsafe gate. Criteria were written before
the model existed (`tools/distill/CRITERIA.md`, round 2).

## Setup

- **Model:** Qwen3-1.7B, full fine-tune at 32k on 1× H100. Epoch 2 of 3 was picked by lowest
  validation log-loss. Tested as the deployable artifact: 8-bit MLX on the 32 GB M6.
- **Training data:** synthetic only. 686 of the 830 sessions were used for training, from six
  writer models (DeepSeek V4 Flash, gpt-oss-120b, Qwen3-Next-80B, Inkling-Small, Hy4-preview,
  early Gemma 4 31B). They cover 32 presenting problems, trap modes oversampled (past, pending,
  hypothetical, third party, ambiguous), speaking rates of 70–170 wpm, and ASR-like surfaces.
  The GP (clinic) data was carved out and moved to `~/Downloads/scribeski-gp-data/` for a future
  doctor-intake model.
- **Gold test set:** 30 AnnoMI counselling sessions, never trained on, labelled by hand on the
  review page (`https://claude.ai/artifact/A147o5hoWmgvGjkKE4qkGH`). They cover drinking, drugs,
  smoking, reoffending, gambling, self-harm, medication and everyday problems. That is 359
  reviewed answers: 96 established facts, the rest not established. Pre-fills came from the
  round-1 model, not the model under test, and the reviewer overrode 51 of its 93 suggestions.

## Results (gold set: 30 sessions × 63 fields = 1,890 answers)

| gate | round 2 | round 1 (reference) |
|---|---|---|
| 1. unsafe answers in risk fields = 0 | ✅ **0** | ❌ 3 ("active SI with plan" ×2, "has a plan") |
| 2. unsafe ≤ 1.0% | ✅ 0.79% (15) | ✅ 0.63% (12) |
| 3. established facts exactly right ≥ 75% | ❌ **16%** (15/96) | ❌ 27% (26/96) |
| 4. time ≤ ⅓ of Gemma (≤ 37.7 s) | ✅ 2.1 s/session | ✅ 2.1 s/session |

Synthetic validation (144 sessions) scored 98.1% correct with 0.4% unsafe. Every trap mode
scored 88–100% except indirect answers (92%). The model learned the synthetic task. It doesn't
transfer.

**For continuity only, flagged optimistic:**

| set | accuracy | unsafe | unsafe in risk fields | Gemma 26B, same checks |
|---|---|---|---|---|
| old corpus | 90.7% | 4 | 0 | 88.0%, 4, 0 |
| old held-out pair | 93.7% | 1 | 0 | not run |

Round-2 data was designed around the corpus's round-1 failure classes, which is why these are
flagged.

## Why it fails on real speech

**Established facts by field (right/total):**

| field | right / total |
|---|---|
| substances | 0/14 |
| support system | 1/14 |
| session type | 6/14 |
| living situation | 0/13 |
| employment | 0/11 |
| protective factors | 0/7 |
| follow-up interval | 4/5 |

1. **Underconfident on real speech.** Employment answers sit at 0.62–0.68 probability, alcohol
   use at 0.29–0.87. The 0.9 threshold fit on synthetic validation hides them.
   - Lowering it to 0.5 gets 40% of established facts right, but unsafe answers rise to 1.48%.
2. **Implicit disclosures read as absent.** Living situation is P(blank) 0.996–0.998 where the
   reviewer marked, say, *with family*, and support system is P ≈ 0.01. Counselling clients mention
   these in passing ("my wife gets upset when I drink"). The synthetic sessions state them, and
   the synthetic label rules teach "explicit statement or blank". **This is partly a
   label-policy decision**, not only a model failure: should a passing "my wife" establish
   living with a partner?
3. **One systematic prior.** 11 of the 15 unsafe answers are `session_type = FOLLOW_UP`, where
   the reviewer marked it not established. AnnoMI clips start mid-conversation.
4. **A form gap the reviewer found.** In session 95 the client has current suicidal thoughts but
   no plan either way. The form's `si_ideation` options force a plan answer, so the only safe
   label is blank. The form likely needs an *active, plan not assessed* option.

## What would change the verdict

- **Decide the implicit-disclosure policy, then align both the synthetic label rules and the
  gold labels with it.** This is the biggest lever, and it's a product decision (clinician-owned).
- **Real behavioral-health speech in training.** AnnoMI would fit, but its license is unstated.
  Asking the authors could allow training on part of it, keeping the other part held out.
- **Synthetic sessions that disclose the way counselling does:** facts mentioned in passing
  inside stories, not in answer to form questions. Restyling existing synthetic sessions into
  an MI-like style would be a cheap first step.
- **Per-field thresholds, and calibration on real speech,** instead of one global threshold fit
  on synthetic validation.
- **Take `session_type` out of the classifier.** The app knows whether a visit is an intake or a
  follow-up.
- **Gold is spent for this model family.** The next round needs new held-out sessions: more
  AnnoMI, or the P2.8 role-plays.

## Cost and artifacts

- **Gateway:** $44.20 for all generation, labelling and restyling this project, including the
  first $5 of free credit.
- **GPU:** round-2 fine-tune, 1.56 H100-hours, about $5.15. Instance terminated, SSH key removed.
- **Model:** `tools/distill/out/q17-r3/epoch2` (bf16) and `epoch2-mlx8` (tested).
- **Predictions and scoring:**
  - `out/q17-r3/pred-epoch2-mlx8.json`
  - `out/q17-r3/eval-mlx8.txt`
  - `tools/distill/gold.py`
- **Gold labels:** `tools/distill/out/gold/gold-labels.json` (30 sessions) and
  `out/gold/reviews/`. AnnoMI transcripts stay in `data/eval_only/annomi/`: eval only, never
  trained on, never sent to an outside model.
