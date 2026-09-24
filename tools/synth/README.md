# tools/synth — synthetic sessions for the classifier tier (BUILD_PLAN P1.9 step 2)

Code decides the truth. DeepSeek only writes dialogue around it.

1. **`sample.mjs`** draws a sheet: session frame (type, modality, length, language, speaking
   rate) and, for every choice field in `fields.mjs`, a value **and a disclosure mode**
   (stated, indirect, corrected — sometimes much later, misreflected by the worker,
   hypothetical, about a third party, ambiguous, declined, never discussed). Labels follow
   from the mode by rule. `--balance` mixes realistic priors toward uniform so rare answers
   (ACTIVE_WITH_PLAN, UNSHELTERED, MAT…) get coverage. Coherence rules keep sheets
   plausible (PHQ-9 item 9 matches SI, living alone ⇒ no kids at home, and so on).
2. **Persona**: DeepSeek invents names, meds and a backstory consistent with the sheet.
3. **Segments**: one ~7-minute segment per call, each with a brief saying what to establish,
   how, what's reserved for later, and what must never come up. The previous 30 lines and a running
   summary carry continuity. Timestamps come from word counts at the sheet's 130–160 wpm.
4. **Blind teacher**: a separate call extracts every field from the finished transcript
   without seeing the sheet. `truth.json` marks each label `agree: true|false`. Train on
   agreeing labels. Disagreements are either writer drift or teacher error; read them.

```bash
node tools/synth/generate.mjs --check                      # fields.mjs ↔ fixtures/mock-ehr/FIELDS.md
node tools/synth/generate.mjs --dry --n 3 --seed 1         # print briefs, no API calls
node tools/synth/generate.mjs --n 20 --seed 1000 --out data/synth/batch-1 \
  --writer deepseek/deepseek-v4-flash --teacher deepseek/deepseek-v4-flash
```

Options: `--minutes N`, `--lang en|es`, `--balance 0..1`, `--concurrency 4`. Needs
`AI_GATEWAY_API_KEY` (env or repo-root `.env`). Reruns skip sessions whose `truth.json` exists.

Output (`data/`, gitignored) per session: `sheet.json`, `persona.json`, `briefs.json`,
`transcript.txt` (same header format as `fixtures/corpus`), `truth.json`; plus `index.jsonl`
per run.

**Rules:** synthetic text only. Never write under `fixtures/`, and never train on
`fixtures/corpus/heldout/` or the P2.8 role-plays.
