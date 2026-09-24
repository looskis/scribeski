# Scribeski — Design

Ambient documentation assistant for social workers. Listens to a remote session,
produces a clinical note, and fills the agency's web intake forms — on-device.

Part of a family of Apple-Silicon-first tooling for privacy-first professions.

**Status:** Phase 1 in progress (see BUILD_PLAN §1 Progress). App shell not started.

---

## 1. Scope

| Question | Decision |
| --- | --- |
| Session setting | **Remote only** (video/phone call on the Mac). In-person is out of scope. |
| Runtime LLM | **Local only.** Transcript/summary/extraction never leave the Mac. Setup-time form mapping may use a cloud model (form structure only, no client data). |
| Form target | The worker's **live, already-logged-in Safari tab**, via AppleScript `do JavaScript`. |
| Timing | **Transcription streams during the session; everything else runs after it.** The worker sees nothing live except level meters. Stop → extract → fill → review → confirm. |
| Audio retention | **A policy setting, including zero-recording.** `none`: audio never touches disk. `until_confirm`: encrypted, destroyed at confirm. `days(N)`. See §3a. |
| Hardware floor | **32 GB Apple Silicon.** Set by the default LLM (§4). |
| Models | **Sensible defaults out of the box, user-configurable.** Weights live in a store shared by the whole suite of tools (§4a). |

**Remote-only is the decision that shapes everything else.** Two separate digital
audio streams means speaker identity comes from *track identity* — ground truth, not a
model output. There is no diarization in this system at all. That removes the single
largest source of error and the hardest component to build.

### Verified on this machine (macOS 26.6.2, M1 Max, 64 GB)

- `AudioHardwareCreateProcessTap` / `CATapDescription` — present, `macos(14.2)`
- ScreenCaptureKit: `capturesAudio` (13.0), `captureMicrophone` (15.0), separate
  `SCStreamOutputTypeAudio` / `SCStreamOutputTypeMicrophone` buffers
- `Speech.framework`: `public actor SpeechAnalyzer`, `SpeechTranscriber`,
  `AssetInventory`, with `audioTimeRange` (CMTimeRange) and `alternatives`
- Safari 26.6.2 `do JavaScript` present, gated on Develop → *Allow JavaScript from
  Apple Events* (error string verified — it is our onboarding copy, verbatim)
- `SpeechAnalyzer` takes live input: `start(inputSequence:)` over `AnalyzerInput`,
  `volatileResults`, `isFinal`, `finalize(through:)`
- **Xcode 27.0** installed (macOS 27 SDK) but not the selected developer directory; use
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` or `xcode-select -s`.
  Deployment target stays macOS 26.
- FileVault active (`fdesetup isactive`, no root needed); `ulimit -l` unlimited

---

## 2. Audio capture

**Two tracks — a per-process CoreAudio tap (remote party) and the mic (worker) — as
sub-devices of one private aggregate device.**

### Why not mic-only

1. **The call app is engineered against you.** Zoom/Teams run echo cancellation whose
   explicit job is removing speaker output from the mic path.
2. **Headphones** — often policy in a shared office. Then the client's audio never
   reaches the mic at all, and the failure is silent.
3. **Accuracy.** Speaker → room → mic adds reverb and band-limiting.
4. **It throws away free, perfect speaker separation.**

### Why a process tap rather than ScreenCaptureKit

- **Permission.** SCK trips the **Screen Recording** prompt. A tap trips **Audio
  Recording** — narrower and accurate to what we do.
- **Per-process scoping is a structural privacy property.**
  `initMonoMixdownOfProcesses:` taps only the call app. Slack, Music, a second client's
  window — never captured, by construction rather than by policy.

Keep SCK behind the `AudioSource` protocol as a fallback.

### One aggregate device, one clock

Both the mic sub-device and the tap go in a single private aggregate device
(`kAudioAggregateDeviceTapListKey`, `kAudioAggregateDeviceIsPrivateKey`), read by one
IOProc. Two independent capture graphs drift; across a 45-minute session that drift
misaligns speaker turns by hundreds of milliseconds and corrupts every timestamp the
provenance system depends on.

### Build for these from day one

- Never tap globally — you will capture yourself. Inclusive per-process tap only.
- **Zoom/Teams emit audio from helper processes.** Resolve
  `kAudioHardwarePropertyProcessObjectList` → PID → bundle ID, match the bundle
  *family*, and keep watching for new audio clients appearing mid-session.
- The call app may launch *after* recording arms — attach late.
- AirPods switching profiles changes sample rate and can invalidate the aggregate
  device. Detect and rebuild.

---

## 3. Transcription

**No TTS anywhere in this product.** Nothing speaks. STT only.

Because the two tracks are each single-speaker, **transcribe them independently and
merge by timestamp**. Never mix down — mixing throws away the one thing that makes this
tractable.

**Transcription is always streaming, in every retention mode.** Audio goes from the
IOProc to a per-track voice-activity segmenter to the transcriber *during the call*, and
only finalized text is kept. Recording audio is an optional **tee** beside that pipeline,
not a stage in it. One pipeline instead of two, and the transcript is ready seconds after
Stop instead of minutes.

### Three engines behind one `Transcriber` protocol, all in-process

Researched September 2026. Whisper no longer leads any published ranking, so it's out.

| Engine | Role | Why | Catch |
| --- | --- | --- | --- |
| **Parakeet TDT 0.6B v3**, CoreML via FluidAudio (Swift) | **Default** (provisional until the P2.8 bake-off) | ~60× real-time on the **Neural Engine**, so it doesn't fight Zoom for the GPU during the call. 25 European languages incl. Spanish | CC-BY-4.0: attribution in the About box. English accuracy trails the leaders |
| **Qwen3-ASR 1.7B**, MLX (Swift) | Accuracy option | Best measured on-device accuracy (1.32% WER at 5-bit on LibriSpeech). 52 languages. Apache-2.0 | Runs on the GPU, so it competes with the call |
| Apple **`SpeechAnalyzer`** | Baseline | Nothing for us to ship; OS-managed per-locale assets via `AssetInventory` | No public accuracy numbers |

All three run in our process: no transcription sidecar. The worker can switch engines in
settings (§4a). Every published number is clean read English; the P2.8 bake-off measures
what matters: *accented, telephony-band, single-speaker* audio, and extraction accuracy
downstream of it.

### No diarization, one exception

Track identity labels every word with certainty; the best diarizers still misattribute
5–13% of speech. Diarizing would make attribution *worse*. The exception is a **second
voice on the client line** (a family member on the same laptop). Sortformer (streaming,
Neural Engine, ≤4 speakers) runs on the client track only and **flags** those spans for
review. It never relabels speakers.

**Vocabulary biasing matters more than model choice** for this domain. Program acronyms
(SNAP, TANF, SSI/SSDI, CPS, IEP, ADLs, SI/HI), drug names, and staff names.
SpeechAnalyzer takes `AnalysisContext.contextualStrings`. The bake-off checks what
biasing each other engine supports; where there's none, post-correct against the
vocabulary list.

---

## 3a. Zero-recording mode

`retention: none`: **the audio never exists on disk.** It lives for seconds in locked
memory, becomes text, and is zeroed. Some clients and agencies will consent to
transcription and not to recording; this mode is for them, and it's the strongest
privacy claim the product can make.

Because transcription already streams in every mode (§3), zero-recording is just *the tee
switched off*. It's not a second pipeline.

### What it costs, stated plainly

| | `none` | `until_confirm` |
| --- | --- | --- |
| Audio on disk | **never** | encrypted, until confirm |
| Review: hear the client say it | no. Quote, speaker, and timestamp only | yes |
| Re-transcribe after the call with a better model | no | yes |
| Transcriber crashes mid-call | audio beyond the in-memory backlog is lost, and the gap is marked | recoverable from the tee |
| Time from Stop to transcript | seconds | seconds (same pipeline) |

Provenance verification is unaffected, because it is text against text. The worker loses
*playback*, not *evidence*.

### Engineering requirements

- **Locked, zeroed buffers.** Every Scribeski-owned audio buffer (ring buffers, segmenter
  backlog, converter output) is `mlock`ed so it can't be paged to swap, and wiped with
  `memset_s` (which the compiler can't elide) the moment its text is finalized. Budget:
  2 tracks × 120 s × 16 kHz × Int16 ≈ **7.7 MB** locked. `ulimit -l` is unlimited here;
  verify on managed machines.
- **FileVault is a precondition.** A Mac that hibernates mid-session writes RAM to the
  sleep image. That image is only encrypted if FileVault is on. Zero-recording mode refuses
  to arm unless `fdesetup isactive` is true, and holds an `IOPMAssertion` against idle sleep
  for the session.
- **Core dumps off** (`RLIMIT_CORE = 0` at launch). Crash reports carry stacks, not heap.
- **Bounded backlog, never a spill.** If the transcriber falls behind (two tracks, during a
  video call, on a 32 GB machine), the backlog grows in locked RAM up to its cap. Past the
  cap we **do not write to disk**, since that would silently break the mode's promise.
  Instead: degrade (a faster engine: Parakeet, or SpeechAnalyzer `fastResults`), alert the
  worker, and if audio must be dropped, mark the gap in the transcript. Every gap shows in
  the review HUD.
- **Transcriber streaming.** SpeechAnalyzer is built for it: `start(inputSequence:)`,
  keep only `isFinal` results, `finalize(through:)` at Stop. Parakeet and Qwen3-ASR get
  VAD-segmented utterances (≤30 s each, single speaker per track, so segments are clean)
  handed over in memory, in-process. No transcription sidecar, so no audio crosses a
  process boundary.

**The claim we can make, exactly:** *Scribeski never writes audio to disk. Its in-memory
audio buffers are locked and zeroed after transcription.* Apple's framework internals are
Apple's; there we rely on macOS's encrypted swap. Don't let marketing round that up.

**Consent still applies.** Live transcription is interception in most jurisdictions just as
recording is. The consent gate doesn't change.

---

## 4. Local LLM: serving and shipping

**Decision: `llama.cpp` (`llama-server`) as a bundled sidecar binary — but for one
reason, not three.** An earlier draft of this document gave three; one was wrong and is
corrected below.

### Corrected: mlx-lm *does* have server-side prefix caching

`mlx_lm.server` has an LRU prompt cache (`--prompt-cache-size`, `--prompt-cache-bytes`)
that reuses the longest common token prefix across requests, plus `mlx_lm.cache_prompt`
and `make_prompt_cache` in the Python API. The earlier claim that KV prefix reuse was a
llama.cpp differentiator was **wrong**. It is not a reason to prefer either runtime.

### What actually decides it: `mlx_lm.server` silently ignores `response_format`

Both `json_schema` and `json_object` are accepted and dropped — no error, no warning.
[ml-explore/mlx-lm#1007](https://github.com/ml-explore/mlx-lm/issues/1007) is open with
no maintainer response.

Silently ignored is worse than unsupported. An unsupported parameter throws and you fix
it in the first hour. A silently ignored one returns fluent free text that passes a smoke
test, reads fine in a demo, and degrades in production in exactly the way this system
cannot tolerate — see §7: the governing failure mode is a *plausible fabricated value in
a clinical record*. A shape guarantee that silently isn't there is the worst available
outcome.

llama.cpp compiles `response_format: {type: "json_schema"}` to a GBNF grammar and
constrains the sampler. The guarantee is structural.

Workarounds exist for MLX — Outlines with the `mlx_lm` backend, or a
`JSONSchemaLogitsProcessor` — but they are **library-level, not server-level**. Taking
them means hosting the generation loop in Python inside our app, which lands straight
back on the packaging problem below.

### Still standing: packaging

A social worker double-clicks an installer. `llama-server` is one binary to codesign into
`Contents/Helpers/`. mlx-lm means embedding a Python runtime in a notarized app —
python-build-standalone, signing every dylib, MLX's Metal shaders — and the structured-
output workaround *requires* being in-process in Python, so the two problems compound.

### The finding that matters more than the runtime choice

**Sliding-window and hybrid attention break prefix caching on both runtimes, silently.**

- **mlx-lm:** [#980](https://github.com/ml-explore/mlx-lm/issues/980), open, no fix.
  `RotatingKVCache` cannot be trimmed at an arbitrary prefix boundary, and SSM/Mamba
  state is not trimmable at all, so the cache is erased and the prompt fully recomputed.
  Reported as affecting Qwen 3.5, GPT-OSS 20B/120B, Gemma 3, Llama 4, Qwen2.5-VL.
- **llama.cpp:** same class of problem — the server logs *"forcing full prompt
  re-processing due to lack of cache data (likely due to SWA or hybrid/recurrent
  memory)"*. The difference is that a mitigation exists: `--swa-full` allocates a
  full-size unpruned SWA cache, trading KV memory for cacheability.

Our workload is the pathological case for this: ~100 field queries sharing one
~10k-token prefix. A silent fallback turns one prefill into a hundred — roughly **1M
tokens of prefill**, a 20-second note becoming a 20-minute one. The output stays correct,
so nothing fails; it just quietly stops being usable.

Three consequences:

1. **Model selection is now a caching decision, not only a quality one.** Prefer pure
   full-attention models, or budget the `--swa-full` memory — which on a 32 GB floor
   competes directly with model weights.
2. **Prompt layout is load-bearing.** Transcript first, field spec last, byte-identical
   prefix across all ~100 requests. Backwards ordering never hits the cache regardless of
   runtime.
3. **Assert the cache hit; do not trust the flag.** The P1.6 eval measures prefill
   tokens on every request and fails if any request after the first S (parallel slots;
   llama-server's cache is per slot) processes more than half of the first request's
   tokens. A hit costs only the field's own few hundred tokens; a miss re-does the
   whole transcript, so the two never overlap. This is the only defence against a silent regression when
   a model or runtime version changes.

### Honest margin

The gap is narrower than first stated. `response_format` landing natively in
`mlx_lm.server` — with the caching caveat resolved — would make MLX the better pick, and
MLX genuinely prefills faster on Apple Silicon. Everything here speaks OpenAI-compatible
HTTP precisely so that stays a `base_url` change.

Also considered and set aside:

- **Ollama** — a separate global daemon the user installs, on a version we do not
  control. Unshippable into a signed clinical tool.
- **`vllm-mlx`** — MLX-native, OpenAI-compatible, has prefix caching *and* a
  `json_schema` constrained-decoding processor, so it is the closest MLX answer to our
  actual requirements. But it appears on GitHub as a large set of near-identical forks
  with no clear canonical upstream, and it is still Python. Worth re-checking at M5b;
  not something to stake a clinical tool on today.
- **MLX Swift** — in-process, no sidecar, no Python. Structured generation is still an
  [open request](https://github.com/ml-explore/mlx-swift-examples/issues/221). Revisit.
- **Apple Foundation Models** — ~3B on-device with native guided generation and nothing
  to download. Too small to be the extractor, but free and instant for auxiliary passes:
  a pre-send PII scrub check on the form profile, or a cheap per-field "is this evidence
  actually responsive?" second opinion.

### Model choice and sizing

**Two tiers (decided 2026-09-22).**

- **Reasoning tier: Gemma 4 26B-A4B** (MoE, 3.8B active; Google's QAT Q4_0 GGUF; Apache-2.0).
  Narratives, quote-finding, breaking fields into small questions, and the **tool-calling
  loop** around the page: learn the form, find its fields, recover from flaky pages
  (re-inject, re-activate a step, re-profile after drift). It calls only Scribeski's own
  typed tools (`profile`, `activate_step`, `read_structure`, `reinject`). It never gets
  raw JavaScript, and no tool can submit or navigate away. A model writing arbitrary JS into a
  live EHR page could submit a form or leak data, so that capability doesn't exist.
- **Classifier tier: a small model distilled for Scribeski** (P1.9) that answers the atomic
  yes/no and multiple-choice questions fields are broken into (kev-style: one input, many
  independent questions, answers scored rather than generated, calibrated so low confidence
  means blank). Teacher: DeepSeek, via the Vercel AI Gateway, on **synthetic transcripts
  only**.
- **Dense models are out.** Gemma 4 31B matched 26B-A4B's safety on the Spanish session but
  took 23 minutes instead of 3 (7×): every weight runs for every token.

**Context: 32k for the reasoning tier.** Measured from the config: with `--swa-full` and
q8 KV, Gemma 4 26B-A4B's cache costs ~115 KB/token (25 sliding layers × 8 KV heads × 256,
plus 5 global layers), so 32k ≈ 3.8 GB, weights + KV + compute ≈ 19 GB, inside macOS's
default GPU working set on 32 GB (~21 GB). A real hour at conversational pace (130–160 wpm,
short ASR segments) is ≈ 18k tokens in English, ≈ 22k in Spanish; 32k covers 60–75 min.
Longer sessions are split into two overlapping halves, not given a bigger window. The
classifier tier works on retrieved windows (question + the ~20–40 most relevant lines) and
trains at 4k.

**Previously considered:** Gemma 4 31B (dense), same format. Both Apache-2.0 (Gemma 4 left
the Gemma Terms of Use behind).

- **Why the mixture-of-experts model by default:** ~4B parameters active per token, so it
  decodes several times faster than a dense model of its size, and extraction is ~100
  sequential-ish generations. The 31B dense model is the quality ceiling in the P1.6 eval.
- **Why QAT Q4_0:** trained for 4-bit, so it loses much less than quantizing afterwards.
  That's what makes a 27B-class model fit.
- **Sliding-window attention:** Gemma 4 interleaves sliding-window and global layers.
  llama-server runs it with `--swa-full` and quantized KV (`q8_0`) so the prefix cache
  works; the cache assertion above proves it on every eval.
- **Floor: 32 GB.** Estimated: ~15–17 GB weights + a few GB KV at one slot + macOS's
  GPU working-set cap (about two-thirds of RAM by default). Tight but workable, and the
  LLM only runs after the call, never beside Zoom. 16 GB machines are not supported.
- **User-configurable.** The worker (or agency) can pick another catalog model or point
  at their own GGUF. Anything that hasn't passed our eval gates is labelled
  *not validated* in the UI and recorded in the audit log.

### 4a. Shared model store (suite-wide)

Scribeski is one of **Looski**, a suite of tools; weights are stored once per user and shared.

- **Where:** the suite's App Group container,
  `~/Library/Group Containers/<TEAMID>.looski/Models/`. Apple's supported way for
  same-team apps to share files; works for sandboxed and unsandboxed members. Dev tools
  without the entitlement fall back to `~/Library/Application Support/Looski/Models/`,
  and `SUITE_MODEL_STORE` overrides both.
- **Layout:** content-addressed blobs (`blobs/sha256-…`, read-only after verification),
  snapshot directories of symlinks for multi-file models (CoreML, MLX), `users/<app>.json`
  recording which app depends on what, and a file lock so two apps never download the
  same blob at once. Garbage collection only removes blobs no app references.
- **Delivery:** a catalog of pinned manifests (repo revision, per-file SHA-256 and size,
  licence, minimum RAM), resumable downloads, hash verified before a file is ever loaded.
  Not Ollama's registry, no unpinned `latest`. Signing the catalog comes in P4.2.
- **Selection:** each app keeps its own role → model choice (defaults out of the box).
  The store resolves it RAM-aware and reports rather than silently substituting.
- **Free win:** llama.cpp memory-maps weights, so two suite apps loading the same blob
  share its pages. That only works because both point at the same file.
- **Not sensitive:** weights are public and re-downloadable, so the store is excluded from
  Time Machine. Transcripts and prompt caches stay in each app's own encrypted store.
- **Code:** `Packages/SuiteModelStore`, a standalone package that moves to its own repo
  once a second tool adopts it.

## 5. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Scribeski.app  (SwiftUI menu-bar agent, hardened, unsandboxed)│
│  ├── CaptureEngine   tap + mic → one private aggregate device │
│  ├── Transcriber     Parakeet | Qwen3-ASR | SpeechAnalyzer    │
│  ├── SessionStore    SQLite + per-session encrypted audio     │
│  ├── Orchestrator    record → transcribe → extract → fill     │
│  ├── SafariDriver    NSAppleScript → do JavaScript            │
│  └── ReviewHUD       provenance, edits, confirm               │
└────────────────────────────┬─────────────────────────────────┘
                             │ HTTP, OpenAI-compatible, localhost
                ┌────────────▼─────────────┐
                │ llama-server (bundled)   │
                │ GGUF · json_schema · KV  │
                └──────────────────────────┘
```

No Python at runtime. No user-installed daemons. Two processes: the app (capture and
transcription in-process) and `llama-server`, alive only after the call.

**On "Safari MCP":** the app calls the Safari driver in-process — no MCP in the runtime
path. We build the driver as a library and *also* wrap it as an MCP server used only
during development, so Claude Code can drive real forms while we build the profiler.
Same code, two entry points, no runtime dependency.

**Packaging:** hardened runtime + Developer ID + notarization, **not** App Sandboxed.
Sandbox plus Apple Events plus CoreAudio taps is a fight with no prize. Not App Store
compatible and shouldn't try to be.

TCC, each walked through in onboarding: Microphone, Audio Recording, Automation (Safari),
plus Safari's own *Allow JavaScript from Apple Events* toggle.

---

## 6. Setup: form discovery and mapping

1. Worker opens the form in Safari, already logged in, hits **Learn this form**.
2. **Profile the DOM** — walk the document and every same-origin iframe, collecting per
   control: type, label, `name`/`id`/`data-*`, placeholder, help text, `required`,
   full option lists, grouped radios/checkboxes, and ARIA widgets with no native element.
3. **Ordered selector candidates per field** — `id`, `name`, `data-testid`, label-anchored
   XPath, structural path. A single brittle selector means the profile rots silently.
4. **Walk the nav** — the worker clicks through the wizard once while we record the step
   graph and re-profile each step.
5. **Generate the mapping** from *scrubbed structure* — labels and option values,
   **never field values**. Returns per field: what clinical content belongs there, output
   format, and concept→option mapping for enumerated fields.
6. Worker reviews and edits. Save as a versioned `FormProfile`.

**The scrub is load-bearing.** Step 5 is the only egress in the whole system. Strip every
input's `value`/`textContent` — EHR forms routinely render carrying the previous client's
data — and show the worker the exact payload before it sends.

**Cross-origin iframes are a hard wall.** `do JavaScript` cannot enter them. Detect at
profile time and say so, rather than failing mysteriously at fill time.

---

## 7. Run flow

1. **Arm** — pick the call app to tap, affirm consent obtained. Menu bar goes red.
2. **Capture and transcribe** two tracks, one clock, streaming. Finalized segments are
   appended to the encrypted transcript as they land. If retention ≠ `none`, audio is also
   teed to an encrypted file.
3. **Stop** → finalize both transcribers → merge by timestamp. Speakers known.
4. **Extract per field** — each prompt carries that field's label, help text, and allowed
   options, appended after the cached transcript prefix. Returns
   `{status, value, evidence: [{segment, quote}]}`. Narrative fields are generated
   sentence by sentence with citations. That's where "summarize" lives, so a summary
   error can't cascade into every discrete field.
5. **Derive** scores (PHQ-9, GAD-7) **in code** from the extracted items, never by the model.
6. **Fill** the live Safari tab, highlighting every written field. Two guards first:
   - **Right client.** The worker confirms the target tab in the HUD, and the page's
     client banner (a selector chosen at learn time) must contain the session's client
     identifier, or nothing is written. A correct note in the wrong chart is worse than a
     wrong field.
   - **Autosave.** Many EHRs save drafts on change. If the profile says this form
     autosaves (detected by watching the page's network activity during a fill), the
     default flips to **review first, then fill**, so unreviewed machine text never
     reaches the EHR's server.
7. **Review HUD**, a native panel and **not** injected into the page. Click a field to see
   the exact sentence it came from, play that audio segment (only if audio was
   retained), edit, or clear. Transcript
   text never enters the EHR page's DOM, because page scripts could read it.
8. **The worker submits by hand.** Scribeski never clicks submit.
9. **On confirm** — destroy the session audio key if there is one. Transcript per
   retention policy.

### The failure mode that governs the design

Not a blank field. A **plausible fabricated value in a clinical record** that is later
subpoenaed.

Therefore: per-field extraction, not one giant object. Constrained decoding so the shape
is guaranteed by the sampler. Mandatory evidence as a **verbatim quote plus segment id**,
**verified in code** against the transcript (LLMs can't count characters, so offsets are
computed by us, not asked for), with the field rejected if the quote doesn't resolve *or*
comes from the wrong speaker. And an explicit `insufficient_evidence` return that is
**preferred over a guess**.

Speaker checks alone aren't enough: a model can cite the worker's "Any cannabis?" plus
the client's "No. None of that." and pass a speaker check. So the verifier also rejects a
positive value whose only client evidence is a short negation, requires the worker's
question alongside a bare "yes", and checks each ticked checkbox option on its own
evidence. Polarity in general needs a second opinion; the entailment pass (§4, Apple
Foundation Models) is where that goes.

Blank is safe and visible. Wrong is neither.

Provenance is also the entire trust story. A worker who can click a field and hear the
client say it will use this tool. One who cannot, won't — and shouldn't.

---

## 8. Storage, retention, audit

- **Per-session key** in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`);
  audio and transcript encrypted with it.
- **"Delete audio" means destroying the key.** On APFS, copy-on-write and SSD
  wear-levelling make overwrite-in-place meaningless — there is no shredding a file. Key
  destruction is the only honest delete, and it is instant.
- Data directory excluded from Spotlight and Time Machine. Nothing to system temp. Crash
  reports must never carry audio or transcript buffers.
- **Append-only audit log**, surviving audio deletion: session start/stop, consent
  affirmation, models used, fields filled, per-field confidence, which values the worker
  edited, confirm timestamp. "Which parts did the machine write" needs an answer.
- Retention is set by policy per install (§3a); transcript retained N days; hard cap on
  undeleted sessions so nothing accumulates silently.

**Consent.** Recording a client requires it, and some states require all-party consent.
Engineering guardrail, not legal advice: the record button does not arm until consent is
affirmed, and the affirmation is logged.

---

## 9. Fixtures (built — see `fixtures/`)

### `fixtures/mock-ehr/` — a deliberately hostile demo form

Serve with `cd page && npm run serve` (port 8787; needs http, not `file://`, for the iframe).
The field inventory is [`fixtures/mock-ehr/FIELDS.md`](fixtures/mock-ehr/FIELDS.md); `page/test/fixture.spec.ts`
keeps the page honest against it.

"Riverside County HSA — Integrated Client Record": a 4-step intake with **107 fields**,
styled like a county-built EHR. It embeds **PHQ-9 and GAD-7 verbatim** — both genuinely
public domain, released by Pfizer in 2010 with no permission required — so the demo uses
instruments social workers actually fill in.

Every construct is a hard case we will otherwise hit on a real EHR, each verified working:

| Construct | Field | Proves |
| --- | --- | --- |
| React-style controlled input | `#case_number` | Naive `el.value=x` renders then **silently reverts**; only native-prototype-setter + bubbling `input` persists |
| ARIA combobox, no native `<select>` | `#language_combo` | `.value` writes do nothing; requires real option clicks |
| Same-origin iframe | `#risk_frame` (10 fields) | Frame recursion in the profiler |
| Hidden tab panels | steps 2–4 (64 radios) | Viewport-only profiling misses ¾ of the form |
| `aria-labelledby`, no `label[for]` | 65 controls | Label resolution beyond the easy path |
| Placeholder as only label | `#contact_phone` | Placeholder inference |
| No `id`, no `name` | duration | Structural XPath fallback |
| Submit guard | `#btn_submit` | Automation reaching submit is a **bug**, and says so |

Verified in-browser: the naive write returned `AB-114322` then `""` 900 ms later; the
correct write persisted.

### `fixtures/sample-session.txt` + `expected-extraction.json`

A synthetic 45-minute telehealth session (fictional client), in the exact
`[mm:ss] SPEAKER:` shape the two-track pipeline emits, with a scored ground-truth file.

Built so the *refusals* are testable, not just the fills:

- **PHQ-9 administered in full** → must fill 9 items and score **18** (moderately severe)
- **GAD-7 explicitly deferred** → `gad7_status` = Deferred; the 7 items, score and severity
  must stay **blank**. Inferring anxiety
  scores from depression scores is the archetypal fabrication.
- **Access to lethal means never raised** → `NOT_ASSESSED` or blank. Anything else is
  invention in a risk field.
- **Language decoy** — "my mom only speaks Spanish" in the same breath as "English is
  fine". The mother is not the client.
- **Speaker-attribution trap** — cannabis and opioids are named *by the worker, in a
  question*, and denied. Attribution decides the field.
- **Faith community** mentioned and explicitly declined. A mention is not an affirmation.
- **`risk_level`** is never stated. It is clinical judgement, not a transcript fact —
  flag it, never author it.

**This unblocks extraction work today**, with no audio, no Xcode, and no real EHR.

---

## 10. Build plan

See **[BUILD_PLAN.md](BUILD_PLAN.md)**: four phases, each ending in a demo, with per-task
acceptance criteria, contracts, test strategy, risk register, and deferred decisions.

## 11. Open questions

1. **Which EHR?** §6 is generic until we profile the real one. Netsmart, Apricot,
   CaseWorthy, Clarity and a county ASP.NET form are five different problems.
2. ~~Deployment hardware floor.~~ **Decided: 32 GB** (§4).
3. ~~Spanish.~~ **Decided: v1 is English-only** (2026-09-22).
4. **Buyer** — individual worker or agency compliance officer? Decides whether §8's audit
   log is a feature or *the* feature.
