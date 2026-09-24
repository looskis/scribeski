# Extraction eval — 2026-09-22 (first real runs)

Gemma 4 26B-A4B QAT Q4_0 (`gemma-4-26b-a4b-it-qat-q4_0@d1c082be`), llama.cpp 0.4.1,
`scripts/llama-serve.sh` (1 slot, `--swa-full`, q8_0 KV, reasoning off), M1 Max 64 GB.
Transcript: `fixtures/sample-session.txt` only. **This is the tuning transcript; nothing
here is a held-out result.** Per-run details: `eval/runs/sample-gemma26b-{1,2,3}.md`.

## Gates across runs

| Run | Change | Blank violations | Risk errors | Must-fill | Cache | Wall |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | baseline | **1** | **2** | 69.0% | pass | 249 s |
| 2 | relocate long unique quotes; question anchoring for questionnaire items; 2 mapping intents clarified | 0 | **2** | 83.1% | (warm cache; not measurable) | 235 s |
| 3 | answer cited under its question's id → moved to the answer; `--cold-cache` run marker | 0 | 0 | **87.3%** | pass: 34,229 prefill tokens vs 70,227 allowed | 248 s |

Gates: 0 / 0 / ≥ 90% / cache / ≤ 180 s hard. **Run 3 misses must-fill by 2 fields and wall
time by 68 s.** A copied-line-prefix fix landed after run 3 (it would have recovered
`medication_adherence`); not re-run, to stop tuning on this transcript.

## What the failures were

- **Misnumbered segment ids, not invented quotes.** 234 of 249 unique quotes cited the right
  segment. The misses were off by one, cited the worker question's id with the client's
  answer, or named ids that don't exist (`s0430` of 397). Fixed by relocation rules that
  only move a quote when the move is unambiguous (DESIGN §7, `Verifier.relocated`).
- **Answer to the wrong questionnaire item** (`phq9_2` answered with item 6's reply). Now
  rejected as `question_mismatch`. Correctly rejected in run 3; PHQ-9 total is therefore
  not derived (needs all 9 items).
- **Quotes that aren't verbatim** (a "Like," added; two lines merged). Rejected, correctly.
- **Semantic errors with valid quotes**: `alcohol_frequency` "two or three Saturdays a
  month" → *per week* (runs 1–2); `insurance_member_id` given the case number (run 1);
  `iadl_finances` inferred INDEPENDENT (every run). The verifier can't see these; they're
  what the entailment pass (DESIGN §4) and the 31B comparison are for.
- **Known structural limit:** a bare "No, never." that exists in the transcript verifies for
  any field it's cited for; nothing ties a short answer to its question outside
  questionnaire items (test: `RelocationAndQuestionTests`).

## Speed

37.7 tokens/s decode, ~6,800 output tokens per run → ~180 s of the ~245 s is generation.
The ten narrative fields take 10–14 s each. The cache works: requests 2..N process
160–310 new tokens each (~0.5 s). Levers, in order: fewer output tokens (shorter quotes,
narrative length caps), 2 slots with `--kv-unified` so the prefix is shared (untested),
and the MoE/dense trade (31B will be slower).

## Mapping (P1.4)

`scribeski map` with the same model: 107 fields in 7 requests, 4 m 56 s. Mode agrees with the
hand-reviewed `fixtures/mock-ehr/mapping.json` on 98/107, evidence speaker on 100/107.
Done-when holds (`risk_level` clinician_only, `gad7_score` derived, `substances` client).
It proposed `note_attestation` as **discrete**, i.e. ticking "I attest this note reflects
services I provided". Attestation/signature controls are now forced `clinician_only` in code.

## Next

1. Run the corpus (sessions 02–08) and then the held-out pair, cold cache, same build.
2. Gemma 4 31B QAT on the same set (17.65 GB download).
3. Speed work against the 180 s gate.

## Corpus runs (8 transcripts: sample + sessions 02–08), Gemma 4 26B-A4B

"Unsafe" = a wrong value, or a value where the field must stay blank. "Safe blank" = left
empty where a value was expected: visible, and the worker fills it.

| Run | Change | Unsafe | of which in risk fields | Safe blanks | Total time |
| --- | --- | --- | --- | --- | --- |
| 1 | relocation, question anchoring | 38 | 4 (`safety_plan` NOT_INDICATED ×3, `hi_ideation` NONE) | 44 | 1,533 s |
| 2 | `exclude_options`, strict questionnaire items, short "No" needs its question | 28 | 1 (`hi_ideation` NONE) | 64 | 1,503 s |
| 3 | "was it discussed?" gate; frequency bands in code; shorter output | **22** | **0** | 68 | 1,637 s |

Remaining 22, by kind:
- **Arguably correct; the expected file may be too strict (≈7):** `iadl_transport = INDEPENDENT`
  from "Sí, tengo mi carro" / "The bus"; `food_security = SECURE` from "We're fine. Carol pays
  for groceries"; `sleep_hours = "four, five hours"` (format, not fact). Needs a clinician's
  call on the ground truth.
- **Judgement fields (4):** `protective_factors`. Candidate for `clinician_only`.
- **Note language (3):** Spanish quotes in English text fields (BUILD_PLAN §12, undecided).
- **Real errors (≈8):** names ("Hal" as legal first name; "Brianna" as preferred name),
  `gender_identity` from pronouns, `substances` + CANNABIS from "If it wasn't for the drug
  testing at work I'd try the weed… But no." (a hypothetical), `income_sources = [NONE]`,
  `mse_mood`, IADL medications/finances.

Speed did not improve: output fell only ~10% (69 tokens/request; JSON scaffolding and quotes
are the floor) and the gate made each field prompt longer (341 vs 240 tokens). Time is now
~⅔ generation, ~⅓ reading per-field prompts across ~90 requests. The lever is **fewer
requests** (batch simple fields; parallel slots), not shorter answers.

## Ground-truth rulings (product owner, 2026-09-22)

Ten disputed labels reviewed; see the `$rulings` note in each expected file. Accepted:
IADL values with direct evidence (finances and transport flagged `needs_review`), food
security SECURE when the client says they're fine, `mse_mood` from either of the client's
mood statements, and spelled-out numbers in free-text fields (the scorer now reads "four,
five hours" as 4–5). Rejected: SECURE when the client relies on a food pantry. Spanish
sessions are out of scope for v1 (session-02-es removed).

## Run 4 and the held-out pair (2026-09-23)

Run 4 moved every generic instruction (evidence rules, gate, answer formats) into the cached
prefix: each request now reads ~133 new tokens instead of ~341. Answers shouldn't change;
they mostly didn't.

| | Transcripts | Correct | Unsafe (per session) | in risk fields | Safe blanks | Time |
| --- | --- | --- | --- | --- | --- | --- |
| Run 3, re-scored under the rulings | 7 tuning | 363 | 9 (1.3) | 0 | 56 | 1,436 s |
| **Run 4** | 7 tuning | 357 | **7 (1.0)** | **0** | 62 | **1,256 s (−13%)** |
| **Held-out, run-4 build** | 2 held-out | 106 | **5 (2.5)** | **0** | 14 | 182 s, 391 s |

- **Held-out was scored once, looking only at totals.** No held-out field, value or quote
  was read, so the pair remains usable for the next decision.
- **Tuning → held-out gap: 1.0 → 2.5 unsafe per session.** Some of the verifier and prompt
  work fits the tuning transcripts better than new ones; expected, and why the held-out
  pair exists. Risk fields held at 0 unsafe on both.
- **heldout-02 took 391 s for an 18-minute session**; its slowest fields took 15–20 s each.
  Unexplained; to investigate on a tuning transcript of similar shape, not by reading
  held-out content.
- **Speed gate still unmet**: 240–270 s for the 45–60-minute tuning sessions (target ≤ 180 s),
  on synthetic transcripts that are ~1.5× sparser than real speech. Measured dead ends:
  parallel slots (no gain: this MoE doesn't batch-decode faster on Metal) and n-gram
  speculative decoding (slower, for the same reason).
