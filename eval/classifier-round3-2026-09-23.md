# Distilled classifier tier, round 3: rejected on the pre-registered gates; **safe under the revised product bar** (2026-09-23)

> **Update, same day:** the product owner dropped the coverage requirement: blanks are filled by the
> social worker, as today, and the bar is "never confidently wrong". Round 3 meets the safety gates
> (0 risk-field errors, 0.38% wrong overall). The remaining issue under that bar is **precision when
> it answers: 14 of 21 (67%)**. Per-field thresholds come next. The original verdict below stands as
> recorded.

**Decision: reject.** The safety gates hold: **0 unsafe risk-field answers and 0.38% unsafe
overall** on 30 sealed, human-labelled counselling sessions. Coverage still fails. The model
gets **18% of established facts right** against a bar of ≥ 50%. With no abstention at all it
reaches 43%, and unsafe answers pass 1%, so no threshold passes. Criteria were written before
any round-3 data or model existed (`tools/distill/CRITERIA.md`, round 3).

## What changed from round 2 (product-owner decisions)

- **Passing mentions count.** New synthetic disclosure mode: the fact comes up only in an aside
  or a story, and is never asked about or confirmed.
- **Abstaining is fine.** A blank means "needs review", so the coverage bar dropped from 75% to 50%.
- **`session_type` is supplied by the app.** It is out of the classifier and out of scoring;
  scope is 62 fields.
- **Form gap: when an answer fits no option, leave it blank for review.** New synthetic case:
  active suicidal thoughts with the plan never assessed.

## Setup

- **Data:** batch 5 added 376 sessions with passing mentions and the form-gap case, for 1,207
  synthetic sessions in total: 1,004 for training, 203 for validation. Writers were
  Inkling-Small (double weight), Hy4-preview, gpt-oss-120b, Qwen3-Next and DeepSeek V4 Flash.
- **Model:** Qwen3-1.7B, full fine-tune at 32k, 2 epochs on 1× H100. Epoch 2 was picked by
  validation loss (0.0273). Temperature 1.25 and threshold 0.9 were fit on validation. Tested as
  8-bit MLX on the M6.
- **Sealed test:** 30 fresh AnnoMI sessions, hand-labelled: 333 answers, 77 established facts.
  Pre-filled by round 2, not the model under test.

## Results

| gate (sealed test, 30 × 62 = 1,860 answers) | round 3 |
|---|---|
| 1. 0 unsafe in risk fields | ✅ 0 |
| 2. unsafe ≤ 1% | ✅ 0.38% (7) |
| 3. ≥ 50% of established facts right | ❌ **18%** (14/77) |
| 4. ≤ 37.7 s/session | ✅ 2.0 s |

**Established facts by field (right/total):**

| field | right / total |
|---|---|
| follow-up interval | 5/5 |
| tobacco | 4/10 |
| substances | 2/15 |
| protective factors | 0/8 |
| support system | 0/7 |
| drinking frequency | 0/6 |
| living situation | 0/5 |
| children at home | 0/4 |

**Post-hoc threshold sweep (not the decision):**

| threshold | established facts right | unsafe | precision when it answers |
|---|---|---|---|
| 0.9 (tested) | 18% | 0.38% | 67% |
| 0.5 | 40% | 0.91% | 65% |
| none | 43% | 1.02% | 63% |

**The 7 unsafe answers:**
- employment = STUDENT, twice. The reviewer noted "full-time not stated".
- substances = ALCOHOL.
- follow-up interval, twice.
- legal involvement = NONE. The reviewer noted asking whether one is in trouble isn't a denial.
- referral source = PCP.

**Other measures:**
- Round-2 gold, now development data: 23% of established facts, 0.38% unsafe, 0 risk-field
  errors.
- Synthetic validation: 98.1% correct, 0.5% unsafe. Passing-mention facts: 45/57.
- Old corpus (optimistic): 90.3%, 2 unsafe, 0 in risk fields. Held-out pair: 91.9%, 0 unsafe.

## Across three rounds

| round | risk-field errors | unsafe | established facts right | what changed |
|---|---|---|---|---|
| 1 (on the corpus, not gold) | 0 | 2.7% | — | first model |
| 2 (gold) | 0 | 0.79% | 16% | synthetic only, more variety |
| 3 (sealed gold) | **0** | **0.38%** | **18%** | passing mentions, abstention policy |

(The round-1 model scored 3 risk-field errors on the round-2 gold set.)

**Safety is solved; transfer isn't.** Every round scores about 98% on synthetic validation and
gets under a quarter of established facts in real counselling speech. More synthetic variety
and the passing-mention policy moved coverage only slightly (16% → 18%). A 1.7B student trained
on synthetic text alone doesn't learn how real clients disclose facts.

## What would change it

1. **Measure the bar before moving it: run Gemma 26B-A4B on the same 30 sealed sessions.** It
   runs locally, so no AnnoMI text leaves the Mac. If the reasoning tier also gets well under
   half of these facts, the gold labels are strict (literal reading, e.g. "full-time student")
   and 50% is the wrong bar. If Gemma gets 80%, the classifier really is far behind.
2. **A larger student (Qwen3-4B).** About $10–15 of GPU. Tests whether this is a capacity problem.
3. **Real behavioral-health speech in training** (the P2.8 role-plays, or AnnoMI with the
   authors' permission). This is still the most likely fix. It isn't available yet.

## Cost

- **Round-3 gateway:** about $12 (batch 5 plus reruns).
- **GPU:** about $5.30 (1.6 H100-hours). Instance terminated, SSH key removed.
- **Project totals:** gateway about $56; GPU about $14 across three runs.
