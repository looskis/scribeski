# Distilled classifier tier (P1.9): **rejected** (2026-09-23)

**Decision: drop, for now.** A Qwen3-1.7B classifier, full-fine-tuned at 32k context on
DeepSeek-written synthetic sessions, matches Gemma 4 26B-A4B's accuracy on the 63 choice fields
at ~45× the speed. But on the corpus it gives **3× as many confident wrong answers** (12 vs 4),
and it misses the held-out accuracy gate by one answer. The acceptance criteria were written
before any classifier was scored (`tools/distill/CRITERIA.md`). They fail, and no other
candidate from the same runs would have passed. The frozen bge-m3 baseline fails by a wide
margin.

## What was compared

- **Scope:** the 63 choice fields the classifier tier would own: 47 select/checkbox fields plus
  the PHQ-9 and GAD-7 items. Text, narrative, derived and clinician-only fields stay with
  Gemma either way. Scored by `tools/distill/common.py`, which mirrors `Scorer.swift`
  restricted to that scope. **Unsafe** = a wrong value, or a value where the field must stay
  blank. **Safe blank** = left empty where a value was expected.
- **Test sets:**
  - The corpus: `sample-session` plus sessions 03–08, 441 checks. Session 02-es had been
    removed from the corpus before this ran.
  - The held-out pair, 126 checks, scored once. Neither set was used for training,
    thresholds or model choice.
- **Baseline:** Gemma 26B-A4B `eval/runs/gemma26b-corpus-4`, re-scored on the same checks
  against today's expected files.
- **Training data:** 114 synthetic sessions (`tools/synth`, DeepSeek v4-flash), 2–98 minutes
  long, 20% in Spanish, with trap modes oversampled. The labels come from the sampled sheet
  and are kept only where a blind DeepSeek pass agreed with them. 98 sessions were used for
  training and 16 for validation, split by a hash of the session id.

## Results

| | corpus accuracy | corpus unsafe | …in risk fields | held-out accuracy | held-out unsafe | time for the 63 fields |
|---|---|---|---|---|---|---|
| Gemma 26B-A4B (corpus-4) | **88.0%** | **4** | 0 | not run | not run | ~113 s/session (M1 Max) |
| bge-m3 + trained heads | 67.3% | 33 | 2 | not scored | not scored | 2.5 s/session (M6) |
| **Qwen3-1.7B distilled, 8-bit MLX** | 86.4% | **12** | 0 | **84.9%** | 1 | **2.5 s/session (M6)** |

The Gemma 26B-A4B and bge-m3 rows are both on the corpus. bge-m3 was rejected there and was
never scored on the held-out pair.

Pre-registered gates for the distilled model:

| gate | corpus | held-out |
|---|---|---|
| 1. unsafe answers in risk fields = 0 | ✅ 0 | ✅ 0 |
| 2. unsafe total ≤ Gemma (4) / ≤ 2 | ❌ **12** | ✅ 1 |
| 3. accuracy ≥ 86.0% / ≥ 85% | ✅ 86.4% | ❌ **84.9%** (107/126) |
| 4. ≤ ⅓ of Gemma's time on these fields | ✅ 2.5 s vs 113 s | ✅ 1.9 s |

The model was chosen by lowest validation log-loss (run 2, epoch 3) and tested as the
deployable artifact: 8-bit MLX, 1.7 GB, on this 32 GB M6. On validation, 8-bit matched bf16
while 4-bit lost about 5 points. The confidence threshold was 0.95 and the temperature 1.0,
both fit on validation.

On synthetic validation it scored **95.0% correct with 1.0% unsafe**. By disclosure mode:

| mode | correct |
|---|---|
| stated | 249/271 |
| indirect | 54/72 |
| corrected | 12/12 |
| worker misreflected | 15/15 |
| hypothetical | 9/13 |
| about someone else | 8/9 |
| not discussed | 505/505 |

Validation at 95% against the corpus at 86% is the synthetic-to-real gap. That gap is the
finding.

### Post-hoc robustness (not used for the decision)

Every candidate, each with its own validation-fit threshold:

| candidate | corpus accuracy | corpus unsafe | held-out accuracy | held-out unsafe |
|---|---|---|---|---|
| run 1, epoch 4 (95 sessions) | 83.0% | 3 | 82.5% | 0 |
| run 2, epoch 3 (tested) | 86.2% | 12 | 85.7% | 1 |
| run 2, epoch 4 | 87.1% | 7 | 84.9% | 0 |
| run 2, epoch 5 | 87.3% | 11 | 85.7% | 1 |
| run 2, epoch 6 | 87.5% | 10 | 87.3% | 1 |

All rows are bf16. None passes both gate 2 and gate 3 on the corpus. The model can reach
Gemma's unsafe count only by abstaining down to 83% accuracy.

Without the abstention threshold, every candidate beats Gemma on corpus accuracy (89.6–91.4%),
but with 15–19 unsafe answers, 1–3 of them in risk fields. Its confidence isn't calibrated
well enough off-distribution for the extra coverage to be safe.

## The 12 unsafe answers (corpus)

- **Household composition (4):**
  - `living_situation` WITH_PARTNER for WITH_FAMILY, twice
  - `children_in_home` YES for NO
  - `housing_status` DOUBLED_UP for STABLE
- **Frequency arithmetic (1, plus 1 on the held-out pair):** `alcohol_frequency` put in the
  wrong band. This is the error Gemma made before frequency bands moved into code.
- **Trap misses (2):**
  - `referrals_made` HOUSING_NAV, where a prior referral was only followed up
  - `income_sources` SSDI while the claim is still pending
- **Misreflection session (2):** `transportation` NONE for RELIABLE; `iadl_transport`
  INDEPENDENT for DEPENDENT.
- **Other (1):** `referral_source` HOSPITAL for COMMUNITY_ORG.
- **Incomplete multi-selects (2):** in session 08, `income_sources` is missing SNAP and
  `referrals_made` is missing BENEFITS. No false value was added, but this counts as unsafe
  under the same rule applied to Gemma.

Gemma's 4 unsafe answers don't overlap with these. Its errors were `phq9_5`, `income_sources`
NONE, `food_security` and a CANNABIS hypothetical.

## What would change the verdict

1. **Take arithmetic and household composition out of the model.** Do P1.9 step 1, which this
   run skipped: occasions plus period give the frequency band in code, and household members
   become atomic questions. That targets 5–6 of the 12.
2. **Close the synthetic-to-real gap.**
   - Use more than one writer model; everything came from DeepSeek v4-flash on the Vercel
     free tier.
   - Generate at corpus-like pacing, not only 130–160 wpm.
   - Produce many more sessions. 114 ran out the $5 of gateway credit.
   - Validation keeps improving with data: 95 sessions gave a validation log-loss of 0.080;
     114 gave 0.069.
3. **Use it as a router instead of a replacement.** Accept only high-confidence answers on
   fields where validation precision is near 100%, and send everything else to Gemma. That
   still removes most of Gemma's ~113 s on these fields. It needs its own held-out set.
4. **A new held-out set for the next round.** The corpus and held-out pair have now scored
   this model family. Iterating against them again would be tuning on the test.

## Cost and artifacts

- **DeepSeek via the Vercel AI Gateway:** $4.50 for 114 sessions plus pilots.
- **Lambda 1× H100 PCIe:** 1.16 h, about $3.81. Two full fine-tunes at 32k context, 11 and
  18 minutes. The instance is terminated and its SSH key removed.
- **Code:** `tools/synth/` (generator), `tools/distill/` (harness, bge baseline, LM
  fine-tune, MLX scorer, Lambda helper, `CRITERIA.md`).
- **Local artifacts, gitignored:**
  - `data/synth/`: sessions
  - `tools/distill/out/q17-r2/epoch3{,-mlx8}`: the tested model
  - `tools/distill/out/*/pred-*.json`: every prediction
  - `tools/distill/out/posthoc.txt`
- **Eval fingerprints** (hashes of transcript plus expected file) are in
  `tools/distill/out/q17-r2/report-pred-epoch3-mlx8.md`.
