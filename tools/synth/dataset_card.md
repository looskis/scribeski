---
license: cc-by-4.0
language:
- en
- es
pretty_name: Scribeski Intake Dialogues
size_categories:
- 1K<n<10K
task_categories:
- text-classification
tags:
- synthetic
- clinical
- behavioral-health
- mental-health
- dialogue
- form-filling
- information-extraction
configs:
- config_name: intake
  default: true
  data_files:
  - split: train
    path: data/intake/train.jsonl
  - split: validation
    path: data/intake/validation.jsonl
- config_name: clinic
  data_files:
  - split: train
    path: data/clinic/train.jsonl
  - split: validation
    path: data/clinic/validation.jsonl
- config_name: clinic_restyled
  data_files:
  - split: train
    path: data/clinic_restyled/train.jsonl
  - split: validation
    path: data/clinic_restyled/validation.jsonl
---

# Scribeski Intake Dialogues

Clinician–client conversations labelled against a 63-field behavioral-health intake form:
demographics, housing and household, work and income, substances, medications, PHQ-9 and GAD-7
items, suicide/violence risk items, daily-living items, referrals and follow-up. It was built to
train a small classifier that reads a whole session transcript and answers every form field at
once, **leaving a field blank unless the conversation actually establishes it**.

No client data is included. The default `intake` config is fully synthetic behavioral-health
sessions, and is the only part used to train Scribeski's classifier. <!-- CLINIC -->
The `clinic` configs are
primary-care doctor–patient conversations adapted from public CC BY 4.0 datasets. They are kept
separate for doctor-intake work, and **are not recommended for training a behavioral-health
model**: GP visits carry clinic-visit patterns, not social-work intake.
<!-- /CLINIC -->

> **Content note:** some synthetic sessions include discussion of suicidal thoughts, self-harm,
> substance use and domestic violence, written to resemble clinical risk assessments.

## What's inside

<!-- COUNTS -->

| subset | what it is | labels come from |
|---|---|---|
| `intake` | Behavioral-health intake, follow-up and crisis sessions (English and Spanish) written by open-weight LLMs from a sampled ground-truth sheet | the sheet (by rule), kept only where a blind teacher model reproduces them |
<!-- CLINIC -->
| `clinic` | Primary-care doctor–patient conversations from PriMock57, ACI-BENCH and MTS-Dialog, converted to the same transcript format | two blind teacher models from different families; kept only where they agree |
| `clinic_restyled` | The clinic conversations rewritten in new conversational styles (new speaking styles, registers, pacing, sometimes Spanish) with the narrative held fixed | the original's labels, kept only where a blind teacher (or a targeted check that cites a line) reproduces them on the rewrite |
<!-- /CLINIC -->

Train/validation is split **by conversation group**: a restyled variant always sits in the same
split as its original. Use the `group` column if you make your own splits.

## How it was made

**Synthetic sessions** (`tools/synth/generate.mjs`):
1. Code samples a ground-truth sheet. For every field it draws a value **and how it's disclosed**:
   stated, indirect, corrected later, misreflected by the worker, only hypothetical, about someone
   else, a past state, pending (applied for / an earlier referral), ambiguous, declined, or never
   discussed. The label follows from the disclosure mode by rule; for example, hypothetical,
   someone else's, and never-discussed all mean blank.
2. An LLM invents a persona consistent with the sheet.
3. An LLM writes the dialogue ~7 minutes at a time from a brief that says what to establish, how,
   and what must never come up. Sessions vary in presenting problem, setting, client and worker
   style, structure, speaking rate (70–170 wpm) and transcript surface (clean or ASR-like).
4. A separate blind pass extracts every field. `agreed` is true only where it matches the sheet.

Writers: DeepSeek V4 Flash, gpt-oss-120b, Qwen3-Next-80B-A3B, Inkling-Small, Hy4-preview, and
(early batches) Gemma 4 31B, all open-weight under permissive licenses. Blind teacher: DeepSeek
V4 Flash. Batches marked `synth-v1` predate the variety features and used
DeepSeek only.

<!-- CLINIC -->
**Clinic conversations** (`tools/synth/import_public.py`, `label_public.mjs`): converted to
`WORKER`/`CLIENT` turns; family members and second clinicians are kept on the nearest channel
with a `[family member]` / `[another clinician]` prefix. Labelled blind by DeepSeek V4 Flash and
gpt-oss-120b; a label is `agreed` only where both give the same answer.

**Restyled variants** (`tools/synth/restyle.mjs`): an LLM rewrites how people talk and keeps
every fact, negation, hypothetical, correction and speaker. Labels carry over only where they
survive a blind re-extraction or a targeted "does this conversation establish X?" check that
cites a line. Every trusted label is therefore style-invariant by construction.
<!-- /CLINIC -->

## Fields

`schema/fields.json` lists all 63 fields with their options and plain-language meaning. Each
record's `labels` is a list of:

| key | meaning |
|---|---|
| `field` | form field id |
| `value` | list of option codes; `[]` = not established (leave blank); multi-select fields may have several |
| `agreed` | **train only on `agreed: true`**; `false` means the label sources disagreed |
| `mode` | how the fact was disclosed (synthetic), or `REAL` / `RESTYLED` |
| `acceptable` | other values that also count as correct (`""` = blank), e.g. `NOT_ASSESSED` for an unasked risk item |

`transcript` is a list of `{time, speaker, text}` turns. `provenance_json` holds generation
details (writer, teacher, sheet summary, scenario, origin of a variant).

## Limitations

- **Synthetic text is LLM-written.** It is less messy than real speech even with the style
  controls, and writers sometimes drift into topics the brief forbade. Those labels are
  filtered out (`agreed: false`), but the drift stays in the text.
<!-- CLINIC -->
- **Public-data labels are model consensus, not human annotation.** Two teachers can agree on the
  same over-reading; for example, "I don't smoke" can be labelled as "never smoked".
- **The clinic conversations are primary care, not behavioral-health intakes.** Most fields are
  blank there; the social-history fields (household, work, alcohol, tobacco, drugs, medications)
  are the useful signal.
<!-- /CLINIC -->
- Not validated by clinicians. **Not for clinical use.**

## Authors

**Kevin Loo**, Columbia University · kevin@loo.ski

## License and attribution

<!-- CLINIC -->
CC BY 4.0. The `clinic` and `clinic_restyled` subsets are adapted from these sources, all CC BY 4.0:

- **PriMock57**: Papadopoulos Korfiatis et al., ACL 2022. https://github.com/babylonhealth/primock57
- **ACI-BENCH**: Yim et al., *Scientific Data* 2023. https://github.com/wyim/aci-bench
- **MTS-Dialog**: Ben Abacha et al., EACL 2023. https://github.com/abachaa/MTS-Dialog

Changes made to the sources: converted to a common transcript format (speaker mapping,
detokenization, estimated timestamps); added form labels; restyled variants rewrite the wording.
See `CITATION.bib` for BibTeX, and please cite the source datasets as well as this one.
<!-- /CLINIC -->
