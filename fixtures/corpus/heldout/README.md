# Held-out transcripts: do not use for prompt tuning

`heldout-01.txt` and `heldout-02.txt` and their `expected-heldout-*.json` files are the
**held-out gate set** for BUILD_PLAN §5 P1.6.

- **Never** read, quote, paste into prompts, or use as few-shot examples while writing or tuning
  extraction prompts, the schema builder, the verifier or mappings.
- Score them **only at gates**: `scribeski eval` on the held-out set decides whether a
  model or prompt change passes (0 must_leave_blank violations, 0 risk-field errors, ≥ 90%
  must-fill accuracy, cache assertion, wall time).
- If a held-out file is ever seen during tuning, it is burned. Replace it with a new
  held-out session rather than keep scoring against it.

Both are realistic sessions (one intake, one follow-up) that mix the trap classes of
sessions 03-07 in new combinations. Their expected files follow the same schema as
`../expected-*.json`.
