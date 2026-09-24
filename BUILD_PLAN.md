# Scribeski — Build Plan

Companion to [DESIGN.md](DESIGN.md). The design doc says *why*; this says *what, in what
order, and how we know each piece is done*.

Every phase ends in a demo that someone can watch. Every task has a **done when**. Every
estimate is in engineer-days for one engineer working with Claude Code, and is rough.

---

## 0. Baseline: verified, not assumed

Checked on the dev machine (macOS 26.6.2, M1 Max 64 GB; Xcode 27.0 installed, Command Line Tools selected).
**The dev machine is now a 32 GB M6** (2026-09-23), i.e. the deployment floor: no loaner needed.
**Re-checked 2026-09-22 at P1.0:** the machine is now on **macOS 27.0**, Swift 6.4; rows marked 🔁 changed.

| Claim the plan depends on | Result |
| --- | --- |
| SwiftPM builds and **swift-testing** runs without Xcode | 🔁 `swift build` ✅. `swift test` under the macOS 27 CLT **fails** (`TestingMacros` plugin moved to `plugins/testing/`); passes with `-Xswiftc -plugin-path`. Use `scripts/swift-test.sh`, which prefers Xcode and applies the workaround under CLT |
| XCTest | ❌ under CLT, ✅ under Xcode 27 → **use swift-testing everywhere** so the package builds and tests either way |
| Xcode 27.0 without `sudo xcode-select` | ✅ `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` → `xcodebuild`, macOS 27 SDK; tap and SpeechAnalyzer APIs present |
| `NSAppleScript` and CryptoKit AES-GCM from a SwiftPM target | ✅ |
| Process-tap API surface: `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID/BundleID/IsRunningOutput`, `kAudioHardwarePropertyTranslatePIDToProcessObject` | ✅ all present |
| Aggregate-device keys: `kAudioAggregateDeviceTapListKey`, `…IsPrivateKey`, `…MainSubDeviceKey`, `kAudioSubTapDriftCompensationKey`, `kAudioSubTapUIDKey` | ✅ all present |
| `CATapDescription.privateTap`, `.muteBehavior` (default `CATapUnmuted`) | ✅ |
| `SpeechAnalyzer` vocabulary biasing | ✅ `AnalysisContext.contextualStrings` |
| `SpeechAnalyzer` live input (needed for zero-recording) | ✅ `start(inputSequence:)` / `AnalyzerInput`, `volatileResults`, `isFinal`, `finalize(through:)` |
| Zero-recording preconditions | ✅ FileVault active, `fdesetup isactive` needs no root; `ulimit -l` unlimited |
| `SpeechAnalyzer` model assets | ⚠️ **OS-managed download** via `AssetInventory.assetInstallationRequest` / `reserve(locale:)`. Not bundled by us, but not "zero download" either. DESIGN §3 corrected. |
| Safari `do JavaScript` | ✅ exists; gated on *Allow JavaScript from Apple Events* |
| `llama.cpp`, `whisper.cpp` via Homebrew (dev only) | ✅ available |
| Node.js (dev and CI only: page bundle build + Playwright-WebKit) | 🔁 was not installed; `brew install node` (v26). Never shipped |
| TTS voices for synthetic test audio | ✅ Samantha (en_US), Daniel (en_GB), Moira (en_IE), Karen (en_AU), Tessa (en_ZA), Paulina (es_MX) |

**Consequence:** Phase 1 needs no Xcode, no audio, and no permissions beyond one Safari
toggle. Phase 2 isn't blocked on an Xcode install either. Both can start today.

---

## 1. Shape

| Phase | Proves | Needs | Ends with | Est. |
| --- | --- | --- | --- | --- |
| **1 — Text → Form** | The brain: profile, map, extract, fill | CLT, Safari toggle, llama.cpp | **Demo 1:** one CLI command turns `sample-session.txt` into a filled mock EHR in your Safari | ~20 d |
| **2 — Audio → Text** | The ears: capture and stream-transcribe | Xcode 27 (installed), signing identity | **Demo 2:** real Zoom call → transcript seconds after Stop, **no audio on disk** | ~29 d |
| **3 — The product loop** | It's an app, not a pipeline | Phases 1 + 2 | **Demo 3:** call → reviewed, filled form → audio purged → audit entry | ~21 d |
| **4 — Ship** | Someone else can install and trust it | Developer ID, a real EHR | **Pilot** with 2–3 workers | ~14 d + pilot |

Phases 1 and 2 are **independent** and can run in parallel. Serial total is ~84
engineer-days (~17 weeks). With two parallel tracks, pilot start is ~12 weeks out.
Zero-recording added ~5 days: streaming transcription becomes the only pipeline, and the
recorder shrinks to an optional tee.
Treat P1.5 (extraction) and P2.2 (tap + aggregate device) as ±50%: they carry the most
unknowns.

### Progress (2026-09-22)

| Task | State | What's left |
| --- | --- | --- |
| P1.0 Bootstrap | ✅ | CI hasn't run (no remote yet) |
| P1.1 Safari transport | ✅ | See `eval/spike-safari.md`: works under strict CSP; real-Safari fill all ok |
| P1.2 Profiler | ✅ | 107 fields, golden file, PHI checks |
| P1.3 Filler + read-back | ✅ | Playwright and real Safari |
| P1.4 Mapping | ✅ | `map` + egress scrub; Gemma's mapping agrees 98/107 with the hand-reviewed one (`eval/extraction-2026-09-22.md`) |
| P1.5 Extraction | ✅ | Runs against Gemma 4 26B-A4B; verifier hardened by 3 real runs |
| P1.6 Eval | 🟡 | Sample session: 0 blank / 0 risk / 87.3% / cache pass / 248 s. Corpus and held-out runs, 31B comparison, speed |
| P1.7 Demo CLI + MCP shim | 🟡 | `scribeski note --transcript …`: transcript → filled front tab in one command (same pipeline as the app). MCP shim not built |
| P1.8 Model store | ✅ | Default models pulled into `Looski/Models` and served by llama-server |
| P2.0 App shell | ✅ | `App/Scribeski.xcodeproj`, Apple Development signed. Mic, audio capture, and Safari automation granted and **survive a rebuild with a new CDHash** |
| P2.1 Call-app discovery | 🟡 | Grouped by responsible app; "in a call" = using the mic, ranked first; native apps followed by bundle ID (re-attach verified); "call started" prompt. Needs a real Meet and Zoom call |
| P2.2 Tap + aggregate | 🟡 | One clock, tap isolated, 0 drops; rebuild + gaps (forced); **echo cancellation** (tap as reference, 17 dB live, 0 echo lines); **45-min synthetic run clean**. Needs: a real unplug/AirPods switch, a real 45-min call |
| P2.3 Segmenter + hygiene | 🟡 | VAD, locked + wiped buffers, bounded queue → gaps, FileVault gate, sleep assertion, degrade → alert → gap proven with a throttled transcriber; 45-min run: 0 gaps, 0 bytes written |
| P2.4 Transcribers | ✅ | Parakeet (default) and SpeechAnalyzer behind one protocol; tracks merged into `Transcript`; lanes restart on crash |
| P2.7 Synthetic audio + proofs | 🟡 | `scripts/synth-audio.swift` + `--transcribe-probe` harness: 0% WER, **0 bytes written**. Needs: CI-able form, audit-log check (P3.5) |
| P3.1 Orchestrator | 🟡 | **Chart bound at Start** (found by URL, client read from the banner, confirmed by Start); extraction from the learned form; fill finds that client's tab anywhere, brings it forward, banner re-checked in the page. Keyed client tags in the audit. Same chart in two tabs: the worker picks. **Crash resume** from sealed transcript checkpoints (20 s) or sealed results |
| P3.2 LLM sidecar | ✅ | `LlamaServer`: unix socket in a 0700 dir, key via file, `/slots` + web UI off and **verified**, started after Stop, stopped after extraction |
| P3.3 Review panel | 🟡 | Floating panel: status chips, quotes with speaker/time, Show in form, worker edits, **proposed changes (follow-ups)**, Undo all, confirm; chart confirmation before fill. Missing: validation/second-voice badges, consistency flags, playback (retained modes) |
| P3.4 Learn-form + mapping UI | 🟡 | Learn window: read → banner picker (suggested, patterns proposed, live preview) → exact egress preview (scrubbed, local model) → generate → review → save. Templates, form packs, stable keys, **drift re-matching** (app + `forms rematch`). Missing: walk mode for lazily rendered wizards (no fixture yet), a remote provider option |
| P3.5 Storage + audit | 🟡 | Per-session Keychain key, AES-GCM blobs, purge = key destroyed, retention scheduler, Spotlight/TM exclusion verified, hash-chained audit (JSONL). Missing: N/2N unconfirmed gate, agency-locked policy, data-protection keychain (needs provisioning) |
| P3.6 Menu-bar UX | 🟡 | Every state real, incl. "Ready to fill". Missing: settings, completion notification |
| P1.9 Distilled classifier | ✅ | **Shipped r3** (`dist/scribeski-classifier-r3`, 2026-09-23): Qwen3-1.7B, 8-bit MLX, 2 s/session, 62 fields; blank = needs review. Sealed test: 0 risk-field errors, 0.38% wrong, 18% of facts filled. Reports: `eval/classifier-*2026-09-23.md`. Left: HF upload + catalog pin; Swift/MLX integration |

---

## 2. Prerequisites: things only you can do

| When | What | Why |
| --- | --- | --- |
| Phase 1, day 1 | Safari → Settings → Advanced → *Show features for web developers*, then Developer → **Allow JavaScript from Apple Events** | It's a security setting in your browser. I won't flip it for you. |
| Phase 2, day 1 | Optionally `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | Needs your password. Otherwise our scripts set `DEVELOPER_DIR`, which works but won't affect your other tools |
| Phase 2, day 1 | An **Apple Development** signing identity (free Apple ID works) | TCC grants are tied to code signature. Ad-hoc builds lose their mic/audio grants on every rebuild. |
| Phase 2, P2.8 | A colleague and a Zoom account for **6–10 role-played, consented** test sessions | The ASR bake-off needs real call audio. Synthetic TTS audio proves the pipeline works; it can't measure accuracy. |
| Phase 1, P1.6 | ~40 GB free disk and a fast connection | Gemma 4 26B-A4B and 31B QAT weights for the eval (~15–20 GB each, estimated) |
| ~~Phase 2, P2.8~~ | ~~Borrow a **32 GB M-series** Mac~~ — the dev machine is now 32 GB | The deployment floor (DESIGN §4). 64 GB hides memory problems, and zero-recording must transcribe in real time **during** a Zoom call on it |
| Phase 4 | **Apple Developer Program** ($99/yr) | Developer ID signing + notarization |
| By end of Phase 1 | **Name the target EHR** | Its hard cases should enter the fixtures early, not surprise us at pilot |

---

## 3. Repository layout

```
scribeski/
├── DESIGN.md  BUILD_PLAN.md
├── Package.swift                 # tools 6.2, macOS 26. Everything but the app shell.
├── Sources/
│   ├── ScribeskiCore/            # contracts (§4), pure types, no I/O
│   ├── FormDriver/               # Safari transport + page-bundle loader + job protocol
│   ├── Extraction/               # prompt builder, LLM client, schema builder, verifier, scorers
│   ├── Capture/                  # discovery, tap, aggregate device, segmenter, audio tee (P2)
│   ├── Transcription/            # Transcriber protocol; Parakeet, Qwen3-ASR, SpeechAnalyzer (P2)
│   ├── Storage/                  # keychain, encrypted blobs, GRDB metadata, audit log (P3)
│   └── scribeski/                # dev CLI: profile | map | extract | fill | eval | demo | record
├── Tests/                        # swift-testing only
├── page/                         # TypeScript → one IIFE injected into the EHR page
│   ├── src/{protocol,profile,fill,guard}.ts
│   └── test/                     # Playwright-WebKit against fixtures/ (CI-safe, headless)
├── Packages/SuiteModelStore/     # suite-wide model store + catalog + selection (DESIGN §4a). Own repo later.
├── tools/mcp-shim/               # ~100-line Node MCP server that shells out to the CLI. Dev only, never shipped.
├── App/                          # Scribeski.xcodeproj (synced folders) + thin SwiftUI shell, links ScribeskiUI (P2)
├── fixtures/                     # mock-ehr/ (+ FIELDS.md inventory), sample-session.txt, expected-extraction.json
├── eval/                         # generated reports: extraction-*.md, asr-bakeoff.md
└── scripts/                      # swift-test.sh, llama-serve.sh, synth-audio.swift, eval-corpus.sh
```

Three rules this layout enforces:

- **The app target is thin.** All logic lives in the SwiftPM package, so it builds and tests
  with CLT alone. The Xcode project uses synchronized folders, so the `.pbxproj` changes only
  for settings, not for every file added.
- **The page bundle is the only code that touches the EHR DOM.** It is pure DOM code, so it
  runs identically in Safari (production, over AppleScript) and in Playwright-WebKit (CI).
- **The CLI is the single entry point for dev tooling.** The MCP shim wraps the CLI rather
  than reimplementing the Safari transport, so that transport exists in exactly one place.

No Python in the product. No Python in the dev loop either: WER and the scorers are a
few dozen lines of Swift.

---

## 4. Contracts: the seams between workstreams

Fix these first (P1.0). They're what let the profiler, extraction, and capture proceed in
parallel without blocking each other. All are versioned JSON, with Codable types in
`ScribeskiCore`.

**`FormProfile`**: what the profiler saw. Structure only, never values.
```jsonc
{ "schema": "scribeski.form-profile/1",
  "origin": "http://localhost:8787", "path_pattern": "/index.html", "fingerprint": "sha256:…",
  "steps": [{ "id": "step-client", "activate": { "click": ["#tab-client"] } }],
  "fields": [{
    "key": "case_number",                    // stable: id → name → data-testid → hash(label,kind,step)
    "step": "step-client", "frame": [],      // ["#risk_frame"] for iframe fields
    "kind": "text",                          // text|textarea|date|select|radio_group|checkbox_group|combobox|hidden
    "label": "Case number", "label_source": "label_for",
    "help": "Format: AB-000000", "required": false,
    "options": [],                           // [{value,label}] for select/radio/checkbox/combobox
    "selectors": ["#case_number", "[name=\"case_number\"]", "xpath=//…"],
    "write": "native_setter",                // native_setter|select|click_toggle|combobox_click|never
    "computed": false                        // true for page-computed hidden fields, e.g. phq9_score
  }],
  "unreachable": [{ "frame": "https://other-origin/…", "reason": "cross-origin" }] }
```

**`FormMapping`**: what each field means. Produced once at setup, reviewed by the worker.
```jsonc
{ "schema": "scribeski.form-mapping/1", "profile_fingerprint": "sha256:…",
  "fields": { "si_ideation": {
      "intent": "Whether the client reported suicidal ideation this session, and its form",
      "mode": "discrete",                    // discrete|narrative|derived|clinician_only|skip
      "evidence_speaker": "client",          // client|worker|any
      "option_semantics": { "PASSIVE": "wishes to be dead / others better off, no intent or plan" },
      "max_chars": null, "derive": null } } }
```

**`Transcript`**: what the ears heard. Speakers come from track identity and are not inferred.
```jsonc
{ "schema": "scribeski.transcript/1", "session_id": "…",
  "retention": "none",                     // none|until_confirm|days:N — none ⇒ no playback, no re-transcription
  "tracks": { "worker": { "source": "mic:BuiltInMicrophoneDevice" },
              "client": { "source": "tap:us.zoom.xos" } },
  "started_at": "2026-09-17T14:00:00-07:00",   // resolves relative dates ("next Thursday")
  "segments": [{ "id": "s0041", "speaker": "client", "start": 228.1, "end": 241.0,
                 "text": "Several days. Not like — I'm not going to do anything…", "confidence": 0.91 }],
  "gaps": [{ "track": "client", "start": 1210.4, "end": 1212.0, "reason": "device_rebuild" }] }
  // other gap reasons: "transcriber_backlog" (zero-recording overflow), "transcriber_crash"
```

**`FieldResult`**: what extraction concluded, and why.
```jsonc
{ "key": "si_ideation",
  "status": "filled",                        // filled|insufficient_evidence|clinician_only|derived|rejected
  "value": "PASSIVE",                        // string, or [option values] for checkbox groups
  "evidence": [{ "segment": "s0041", "quote": "Several days. Not like — I'm not going to do anything." }],
  "reject_reason": null,                     // e.g. "quote_not_found" | "speaker_mismatch" — kept for eval
  "model": "qwen3-8b-q4_k_m@sha256:…", "prefill_tokens": 41, "ms": 380 }
```

**`FillReport`**: what actually landed in the page after read-back.
```jsonc
{ "key": "case_number", "intended": "AB-114322", "read_back": "AB-114322",
  "outcome": "ok",                           // ok|reverted|conflict_skipped|not_found|computed_verified|computed_mismatch
  "prior_value": "" }
```

---

## 5. Phase 1: Text → Form

No Xcode, no audio. The goal is to make the difficult logic correct against fixtures before
any capture code exists.

### P1.0 Bootstrap (0.5 d)
`git init`, `Package.swift` (tools 6.2, macOS 26), the targets above, `ScribeskiCore`
contracts as Codable types with round-trip tests, `page/` with esbuild + TypeScript,
GitHub Actions on an arm64 macOS runner for `swift test` + Playwright-WebKit.
**Done when:** CI is green on an empty-but-wired skeleton.

### P1.1 Safari transport spike (1 d): answer these before building on it
1. **Is `do JavaScript` synchronous only?** Assume yes: a returned Promise will not be
   awaited. → Design the **job protocol**: `__scribeski.start(cmdJSON)` returns a job id
   immediately; `__scribeski.poll(id)` returns `{done, result}`. Async work such as
   combobox clicks runs inside the page and gets polled.
2. **Escaping and size.** Call through ScriptingBridge (`doJavaScript:in:`, an NSString in,
   no AppleScript string escaping). Fall back to `NSAppleScript` only if necessary. Install
   the bundle once per document behind a version guard (`__scribeski?.version`), then send
   only small commands.
3. **CSP.** Add `fixtures/mock-ehr/csp.html` carrying a strict
   `<meta http-equiv="Content-Security-Policy">` (no `unsafe-eval`, no `unsafe-inline`).
   Confirm injected code still runs. The bundle must never call `eval`/`new Function` itself.
4. **Targeting.** Front window's current tab by default; later, a stored tab URL match.
   Detect navigation (bundle gone) and re-inject. Every fill carries an **identity check**
   (a client-banner selector + the expected client identifier); on mismatch nothing is
   written. Detect a logged-out tab (login form, not the profiled page) and say so.

**Done when:** a short `scribeski js 'document.title'` works against the mock EHR, the
job protocol round-trips an async task, and the CSP page passes. The findings go in
`eval/spike-safari.md`. If CSP blocks injection, see risk R3.

### P1.2 Page bundle: profiler (3 d)
- Walk the top document plus every same-origin `iframe.contentDocument`, recursively.
  Record cross-origin frames in `unreachable`.
- Resolve labels in order: `label[for]` → wrapping `<label>` → `aria-labelledby` →
  `aria-label` → `placeholder` → nearest preceding text in the same fieldset. Record
  `label_source`.
- Group radios and checkboxes by `name`. For each group, the label is its question text:
  the row label via `aria-labelledby`, or the `<legend>`.
- Detect ARIA widgets (`role=combobox` + `aria-controls` → `role=listbox` → `role=option`)
  and harvest their options.
- Read hidden panels **without clicking**. Build the step graph from `role=tablist` /
  `aria-controls`. Wizards that lazy-render get a *walk mode* later (P3.4), where the
  worker clicks through once while we record.
- `input[type=hidden]` → `kind: hidden, write: never, computed: true`.
- Collect **only** text attached to controls. Never collect page headers, banners, or any
  `value`. The mock's header contains a worker name and a session ID, and that must not
  appear in the profile.
- Compute a `fingerprint` over (key, kind, options) to detect EHR drift later.

**Done when:** a Playwright test profiles the mock EHR into **107 fields** with correct kinds,
all 10 iframe fields found, the combobox's 7 options harvested, every `label_source` class
represented, and a golden-file snapshot committed. A second test greps the profile JSON for
`K. Loo` and `2026-0917` and requires zero hits.

### P1.3 Page bundle: filler + read-back (3 d)
Per-field write strategies:

| kind | strategy |
| --- | --- |
| text / textarea / date | focus → **native prototype setter** → `input` + `change` (bubbling) → blur |
| select | `HTMLSelectElement.prototype` value setter → `input` + `change` |
| radio / checkbox | `.click()` **only if state differs** (so it's React-safe and idempotent) |
| combobox | click trigger → wait for listbox → click the matching `role=option` → verify the trigger reflects it (async, via job protocol) |
| hidden / computed | **never write**. After the other writes, read it and compare to our own derived value (`computed_verified` / `computed_mismatch`) |

- **Activate each step before filling it**, using the profile's step graph, then return to
  step 1. This handles EHRs that validate only visible fields.
- **Read back everything after a settle period** (≥1 s; the mock reverts at 400 ms). Any
  mismatch becomes `reverted`. This catches controlled-input behaviour on EHRs we've never
  seen, not only the one trick we know about.
- **Conflict policy:** if a field's current value differs from its **page-load default**
  (`defaultValue`, `defaultSelected`, `defaultChecked`) and from ours, skip it and report
  `conflict_skipped`. The worker may have typed during the session. (Not "non-empty":
  real EHRs pre-select defaults like "No", which would make every such field a conflict.)
- **Identity check** before any write (P1.1 §4). **Autosave detection:** count the page's
  own fetch/XHR/beacon requests while we write and settle, and return them with the
  reports. A form that autosaves flips the product to review-then-fill (DESIGN §7).
- **Snapshot prior values** for undo.
- **Highlight** filled fields with a `data-scribeski` attribute and an injected stylesheet.
  **Never put transcript text, quotes, or rationale into the page DOM.** EHR page scripts
  can read anything we inject. The review UI is native (P3.3).
- **Submit guard** (`guard.ts`): the bundle refuses to click any `type=submit` element or any
  element inside a `<form>` action bar, and never dispatches Enter keydown.

**Done when:** Playwright fills the mock EHR from a hand-written `FieldResult[]` and every
`FillReport` is `ok`. A test proves the naive `.value=` path yields `reverted` (proving the
read-back catches it). The mock's submit handler never fires, asserted via the
`[mock-ehr] SUBMIT` console line being absent. Undo restores the snapshot exactly.

### P1.4 Mapping, CLI-only (2 d)
- `scribeski map profile.json --endpoint <openai-compatible> --model <m>` produces
  `mapping.json`. The same client code serves local llama-server or a cloud endpoint.
- **Egress scrub** before any non-localhost call: send only the profile's structural fields,
  regex-scan the payload for phone/email/SSN/date/case-number shapes, fail closed on hits,
  and print the exact payload with a `--yes` confirmation. The native preview UI comes in P3.4.
  Two refinements: allowlist the form's own structural text (help like "Format:
  AB-000000" would otherwise always trip it), and **flag option lists that change between
  page loads**. A dropdown populated from the client record (household members, staff)
  is PHI that no regex sees.
- Heuristics the model must propose and the worker confirms: `derived` for score fields
  (`phq9_score`, `gad7_score`); `clinician_only` for judgement fields (`risk_level`);
  `evidence_speaker: client` for anything about the client's own state or history.
- The mapping is hand-editable JSON. That's the review UI until P3.4.

**Done when:** mapping generated for the mock EHR, checked in as
`fixtures/mock-ehr/mapping.json` after hand review, and matching the `must_leave_blank` /
`traps` intent in `expected-extraction.json`: `risk_level` is `clinician_only`,
`gad7_score` is `derived`, `substances` has `evidence_speaker: client`.

### P1.5 Extraction engine (5 d, ±50%)
**Prompt layout (load-bearing, see DESIGN §4):**
```
[system: rules — quote verbatim, prefer insufficient_evidence, never infer scores]
[transcript rendered as "[mm:ss] sNNNN SPEAKER: text" lines]      ← identical across all requests
─────────── cache boundary ───────────
[one field: label, help, options + option_semantics, intent, evidence_speaker]
```
- **Per-field JSON schema, built in code from the profile and mapping,** and sent as
  `response_format: json_schema`. `value` is an `enum` of the field's option values plus
  `null`. Checkbox groups are `array` + `uniqueItems`. Dates have a `pattern`. `status` is
  an enum. `evidence` is `[{segment, quote}]`. An invalid option is therefore structurally
  impossible, and temperature is 0.
- **Evidence is a verbatim quote plus segment ids, not character offsets.** LLMs can't
  count characters. The verifier does a whitespace/punctuation-normalized substring match
  of `quote` inside the cited segment's text and computes offsets itself. *(Refines
  DESIGN §7.)*
- **Verifier, in code and never the model:** quote not found → `rejected: quote_not_found`.
  `evidence_speaker: client` but every cited segment is the worker's →
  `rejected: speaker_mismatch`. That second check turns the cannabis/opioids trap into a
  structural rule. Every rejection becomes `insufficient_evidence` in the UI, and the
  reason is kept for eval.
  *Review correction:* speaker checks alone don't catch that trap. The model can cite the
  worker's question **and** the client's "No. None of that." So also: reject a positive
  value whose only client evidence is a short negation (`negated_answer`); require the
  worker's question alongside a bare "yes" (`missing_question_context`); verify each ticked
  checkbox option on its own evidence; and accept quotes that span consecutive segments
  of one speaker (ASR splits utterances). Worker-asserted facts (GAD-7 deferred, safety
  plan completed, referrals) are `evidence_speaker: any`.
- **Derived fields are computed in code.** PHQ-9/GAD-7 totals and bands come only from
  filled items, and only when *all* items are filled. The LLM never does arithmetic on a
  clinical score.
- **`clinician_only` fields are never sent to the model.** They surface as *needs your
  judgement*.
- **Narrative fields** (presenting problem, history, interventions, plan, risk narrative) are
  generated as sentences, each carrying `[segment, quote]` citations. Uncited or unverifiable
  sentences are dropped, and the length is capped by `max_chars`. This absorbs the separate
  "summarize" step from DESIGN §7. Keeping it per field means a summarization error can't
  cascade into every discrete field downstream.
- **LLM runtime for dev:** Homebrew `llama-server`, 127.0.0.1, `cache_prompt: true`,
  `--swa-full`, `-ctk q8_0 -ctv q8_0`, 32k context, thinking disabled (`chat_template_kwargs`).
  Model candidates for P1.6: **Gemma 4 26B-A4B QAT (default)** and **Gemma 4 31B QAT
  (quality ceiling)**, from the shared store (P1.8). The cache assertion below *verifies*
  that `--swa-full` actually makes the prefix cache hit.
- **Cross-field consistency, in code:** e.g. PHQ-9 item 9 > 0 while `si_ideation` is NONE
  is flagged for review, never auto-resolved.

**Done when:** `scribeski extract --transcript … --profile … --mapping …` produces a
`FieldResult[]` for the mock EHR, and unit tests cover the schema builder, verifier, and
derivations without a model.

### P1.6 Eval harness + corpus (4 d)
**Corpus.** `sample-session.txt` alone would let prompts overfit to one transcript. Add
synthetic sessions, each targeting one failure class:

| file | trap |
| --- | --- |
| `session-03-correction.txt` | Client self-corrects ("laid off in May — no, June") |
| `session-04-misreflection.txt` | Worker reflects back wrongly; client corrects the worker |
| `session-05-nothing.txt` | Short check-in, almost nothing fillable. The blank bias must not break |
| `session-06-hypothetical.txt` | "If I lose the apartment I'll be on the street" ≠ unsheltered |
| `session-07-third-party.txt` | Sister's drinking ≠ client's drinking |
| `session-08-long.txt` | 60 minutes, for latency and cache under a long prefix |
| `heldout-01.txt`, `heldout-02.txt` | **Never looked at while tuning prompts.** Only scored at gates |

Each gets an `expected-*.json` in the same shape as `expected-extraction.json`, where
`phq9_score`/`phq9_severity` live in a `derived` block, asserted after fill and never
extracted.

**`scribeski eval` reports**, per model and per transcript: must-fill accuracy; blank
violations; risk-field errors; traps passed; rejection counts by reason; **prefill tokens on
requests 2..N vs request 1**; total wall time; peak RSS.

**Gates (all must hold on the held-out set):**
- **0** `must_leave_blank` violations (hard)
- **0** errors on risk fields: `si_*`, `hi_*`, `safety_plan` (hard)
- ≥ **90%** must-fill accuracy
- No request after the first S (parallel slots) processes more than half of request 1's
  prefill (**the cache assertion**; a miss re-does the whole transcript, a hit only the field)
- Wall time for the mock EHR: target **≤ 60 s**, hard gate **≤ 180 s** on the M1 Max,
  re-measured on the 32 GB loaner in Phase 3. Re-baseline both after the first real run.

**Done when:** `eval/extraction-<date>.md` shows the default model passing every gate, and the
result is recorded in DESIGN §4. If 26B-A4B fails and 31B passes, 31B becomes the default.

### P1.7 Demo CLI + MCP shim (1.5 d)
- `scribeski demo --transcript fixtures/sample-session.txt` does profile (front Safari tab) →
  load mapping → extract → fill → read back, then prints a table of every field with status,
  value, and quote.
- `tools/mcp-shim`: exposes `profile`, `fill`, `read_values`, and `eval` as MCP tools by
  shelling out to the CLI. That lets Claude Code drive real forms while we build.

### P1.8 Shared model store + model selection (3 d)
`Packages/SuiteModelStore` (DESIGN §4a): App Group location with dev fallback,
content-addressed blobs, snapshots for multi-file models, cross-process download lock,
resumable downloads with streaming SHA-256, GC by app registration, and a pinned catalog:
Gemma 4 26B-A4B QAT (default LLM), Gemma 4 31B QAT, Parakeet TDT 0.6B v3 CoreML
(default ASR), Qwen3-ASR 1.7B MLX, Sortformer CoreML. Per-app selection: defaults out of
the box, user override by catalog id or custom model (always *not validated*), RAM-aware.
CLI: `scribeski models list | pull <id> | use <role> <id|path>`.

**Done when:** unit tests cover dedupe, resume, tamper refusal, concurrent download,
GC, and selection; `scribeski models pull` fetches the default LLM and llama-server loads
it from the store.

### P1.9 Distilled classifier tier (experiment, ~8 d, ±50%)
1. **Decompose first, no training.** Break the worst field classes (ADL/IADL,
   frequencies, absence-read-as-"no") into atomic questions with typed answers plus a
   deterministic rule in code (e.g. occasions + period → frequency band). Run them with
   Gemma on the corpus. If the questions and rules don't beat whole-field extraction, stop.
2. **Generate training data.** Synthetic sessions at *real* speaking rates (130–160 wpm;
   the current corpus runs at 72–98 wpm and understates context and latency), including
   dense hour-long ones. DeepSeek labels (retrieved window, question) pairs through the
   Vercel AI Gateway. **No client data, ever:** synthetic sessions only. Public CC BY 4.0 clinic
   dialogues (PriMock57, ACI-BENCH, MTS-Dialog) were blended in, then carved out on 2026-09-23:
   GP visits teach clinic patterns, not social-work intake. They now live outside the repo
   (`~/Downloads/scribeski-gp-data/`) for a future doctor-intake model. Keep teacher-labelled training data
   and human-reviewed eval data strictly apart; the held-out pair and the P2.8 role-plays
   are never trained on.
3. **Train** a small kev-style model (scored answers + calibrated temperature) at 4k
   context; Python/MLX at dev time is fine.
4. **Compare** against Gemma-only on the held-out pair: unsafe outputs, blanks, wall time.
5. **Port** only if it wins: its scoring head to MLX Swift or CoreML (llama.cpp can't run
   it). That's the real engineering risk.

**Done when:** the comparison is recorded in `eval/`, with a keep/drop decision.

### 🎬 Demo 1
Open `http://localhost:8787` in Safari and run one command. The four steps of the mock EHR
fill in, with PHQ-9 at **18 / moderately severe** (computed by the page and confirmed to
match ours), GAD-7 **empty**, `si_means` **empty or Not assessed**, `risk_level` **empty**
and listed under *needs your judgement*, language **English**, and `#case_number` surviving
read-back. Submit is never touched.

---

## 6. Phase 2: Audio → Text

Transcription **streams during the call in every retention mode**. Recording audio is an
optional encrypted tee. Zero-recording (`retention: none`) is therefore *the tee switched
off*, not a second pipeline (DESIGN §3, §3a).

```
IOProc ─► SPSC rings (mlocked) ─► per-track VAD segmenter (mlocked backlog ≤120 s)
                                        │
                                        ├─► Transcriber (streaming) ─► finalized Segments ─► encrypted transcript
                                        │                                         └─► zero the audio
                                        └─► [tee, only if retention ≠ none] ─► encrypted chunked audio file
```

### P2.0 App shell, signing, TCC (3 d)
- **Xcode 27 is installed but not selected.** Build scripts export
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or you run
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once. That one needs
  your password.
- A checked-in `App/Scribeski.xcodeproj` using synchronized folders (objectVersion 77), so
  adding files never touches the `.pbxproj`. `Scribeski.app` is a SwiftUI `MenuBarExtra` with
  `LSUIElement`, linking the local package's `ScribeskiUI` product. SDK is macOS 27; **deployment target macOS 26**.
- Hardened runtime, **not sandboxed**. Entitlements: `com.apple.security.device.audio-input`,
  `com.apple.security.automation.apple-events`.
- Info.plist: `NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`, the
  Audio Recording usage key for process taps (**spike: confirm the exact key name** —
  believed to be `NSAudioCaptureUsageDescription`), and `NSSpeechRecognitionUsageDescription`
  **if** SpeechAnalyzer demands it (spike).
- At launch: `setrlimit(RLIMIT_CORE, 0)`.
- Sign with a stable Apple Development identity from the first build. Add
  `scripts/tcc-reset.sh` to re-test onboarding.

**Done when:** the menu-bar app launches, requests mic, audio-capture, and Safari automation
permissions, and each grant survives a rebuild.

### P2.1 Call-app discovery (2 d)
- Enumerate `kAudioHardwarePropertyProcessObjectList`, then read
  `kAudioProcessPropertyPID`, `…BundleID`, and `…IsRunningOutput`.
- **Match by bundle family**, since Zoom and Teams play audio from helper processes: a
  known-apps table (Zoom, Teams, Webex, FaceTime, Slack huddles) plus prefix matching.
- Add a property listener on the process list so the tap can attach late and pick up new
  helpers mid-session.
- **Browser-based calls are a supported target: Google Meet first.** Verified 2026-09-22:
  Safari's audio comes from one `com.apple.WebKit.GPU` process **parented to launchd** and
  shared by every tab, so bundle-family matching never finds it. Group processes by
  **responsible app** instead (`responsibility_get_pid_responsible_for_pid`, SPI, no root):
  it maps the GPU process to Safari. A `WKWebView` in another app gets **its own** GPU
  process. Isolation options, in order:
  1. **Safari web app** (File → Add to Dock) for Meet: real Safari, so sign-in works, and
     probably its own processes. *Unverified.*
  2. **Whole browser** tap with the warning "close other tabs playing audio" (R5).
  3. Meet in a Scribeski-hosted `WKWebView`: isolated, but needs Safari's UA string (else Meet
     redirects to "Get Chrome") and Google may block sign-in from embedded views.

- **Built 2026-09-23:**
  - A source is **in a call** when it's using the mic (`kAudioProcessPropertyIsRunningInput`):
    Zoom, Teams, and a Meet tab take the mic only in a meeting. In-call sources rank first
    and are preselected.
  - Native call apps are also tapped **by bundle ID with `processRestoreEnabled`** (macOS 26).
    Verified with a headless test app: killed at 5 s and relaunched at 9 s, the tap picked it
    back up by itself; and a tap started before the app existed caught it when it launched.
    Browsers stay tapped by process: every WebKit client's audio process shares one bundle ID.
  - `CallWatcher` polls every 2 s while idle and posts "Zoom call started — transcribe it?"
    once per call. It only offers: the click opens the start panel, consent is still manual.
    The notification permission prompt appears the first time a call is detected.

**Done when:** a live Zoom call is detected with its helper processes, and closing and
reopening Zoom mid-session is detected.

### P2.2 Tap + aggregate device + IOProc (5 d, ±50%)
- `CATapDescription(monoMixdownOfProcesses:)`, `privateTap = true`, and **`muteBehavior =
  CATapUnmuted`**, asserted explicitly. `Muted`/`MutedWhenTapped` would silence the call
  for the worker.
- A private aggregate device with the mic as the **main sub-device (clock source)**, plus the
  tap in `kAudioAggregateDeviceTapListKey` with `kAudioSubTapDriftCompensationKey` on.
- IOProc via `AudioDeviceCreateIOProcIDWithBlock`. **Realtime-safe only:** copy into two
  lock-free SPSC ring buffers (`mlock`ed) and nothing else. No allocation, locks, logging,
  or crypto.
- When the helper-process set changes, update the tap's process list in place if supported;
  otherwise rebuild. Handle device loss, default-input change, and sample-rate change
  (AirPods profile switch) the same way: rebuild, and record a `gap`.
- A consumer thread computes per-track RMS for level meters. **Silent-client alarm:** the
  call app is `IsRunningOutput` but tap RMS == 0 for >10 s → alert the worker.

- **Findings, 2026-09-23 (macOS 27):**
  - Tap-only probe on Safari: a 440 Hz tone at gain 0.02 read RMS 0.014142 (= 0.02/√2)
    every second while `afplay` spoke a TTS distractor. Isolation holds; 240,128 frames in
    5 s at 48 kHz, 0 dropped. Probe: `Scribeski --capture-probe <bundle> <s> <out.json>`.
  - The macOS 26 SDK adds `CATapDescription.bundleIDs` and `processRestoreEnabled`: taps
    that follow an app by bundle ID and re-attach when it restarts. Use for native call apps.
    **Not for browsers**: every WebKit client's audio process is `com.apple.WebKit.GPU`.
  - `kAudioTapPropertyDescription` is settable, so a helper-set change can update the tap
    in place.
  - Two tracks, RØDE VideoMic GO II (USB) as clock: input layout `[1, 1]`, **mic first, tap
    last**. Over 8 s the client track held the tone at 0.01414 while the worker track
    followed a TTS voice from the speakers (noise floor ≈ 0.0005, speech up to 0.003).
    385,024 frames on **both** tracks (one clock, no drift), 0 dropped.
  - The Mac mini's 3.5 mm jack is output only: a headset there shows 0 input channels.

  - **Speaker bleed (2026-09-23):** with the worker on speakers, the mic hears the client and
    every client line is also transcribed as the worker. Call apps cancel echo on their own
    mic stream, not ours. **Echo cancellation, built:** SpeexDSP's MDF + residual suppressor
    (vendored, BSD) with the tap as reference, on the aggregate's one clock. VoiceProcessingIO
    was rejected: it needs its own mic capture (a second clock), adds AGC, and can duck the
    call. `--aec-lab` tuned it on this Mac: Speex applies residual suppression only through
    its denoiser (on, -6 dB floor), and a 128 ms filter converges fastest. Live: **17 dB**,
    and no client line reaches the worker track. Bug found on the way: padding a late
    reference with zeros misaligns the filter for good; it now waits. The transcript-level
    bleed filter (overlap ≥50% and WER ≤ 0.25) stays as a second guard.

**Done when:** a 45-minute Zoom call streams both tracks with no dropouts. An AirPods
disconnect mid-call yields a gap and capture continues. The call audio stays audible to the
worker throughout.

### P2.3 Streaming segmenter + memory hygiene (4 d): the core of zero-recording
- The consumer converts each track to **16 kHz mono Int16** (`AVAudioConverter`) and runs a
  per-track VAD. Utterances ≤30 s are emitted to the transcriber. The track is single-speaker,
  so segments are clean by construction.
- **Every Scribeski-owned audio buffer is `mlock`ed and wiped with `memset_s`** once its text
  is finalized. Budget ≈ 7.7 MB locked (2 tracks × 120 s × 16 kHz × Int16).
- **Backpressure without spilling.** Track backlog seconds per track. At 50% of the cap,
  degrade (switch to Parakeet, or SpeechAnalyzer `fastResults`). At the cap, alert the
  worker, drop the oldest *untranscribed* audio, and record a `gap` with
  `reason: "transcriber_backlog"`. **Never write overflow to disk** in `none` mode.
- **Zero-recording preconditions:** refuse to arm unless `fdesetup isactive` is true (the
  sleep image is only encrypted under FileVault). Hold an `IOPMAssertion` against idle sleep
  for the session.
- Timestamps come from the capture clock (sample counts on the aggregate device), not from
  the transcriber.

- **Built 2026-09-23:** `Segmenter` (energy VAD, adaptive floor, 300 ms pre-roll, 700 ms
  hangover, ≤30 s split at the quietest frame), `Resampler` (device rate → 16 kHz Int16),
  `LockedPCM` (utterance buffers `mlock`ed, zeroed with `memset_s` when the last holder
  releases them, including the transcriber), `UtteranceQueue` (120 s cap per track; overflow
  drops oldest → `transcriber_backlog` gap), `CaptureController` (drain every 50 ms,
  rebuild on real device changes, gaps anchored to when the new device's first audio
  arrives), `SessionGuards` (FileVault gate for `none`, idle-sleep assertion).
- **Rebuild storm, found and fixed:** building an aggregate fires the mic's sample-rate and
  alive notifications, so "rebuild on any notification" turned one rebuild into 30. Now a
  notification only triggers a rebuild if the graph is actually wrong, with backoff after 3
  in 30 s. Forced rebuild at 25 s: 1 rebuild, a 1.2 s gap on each track, timestamps after it
  within 0.1 s of reference.

- **45-minute synthetic run (2026-09-23, Parakeet, silent tap):** 397 lines, WER client 2.5%
  / worker 1.9%, 0 lines missed, 0 gaps, 0 overloads, 0 rebuilds, **0 bytes written**,
  transcript 0.08 s after Stop. Client-vs-worker timing moved 0.08 s over 45 min (~30 ppm,
  device clock vs the host-paced injected worker; a real mic shares the aggregate's clock).
  A test muter bug let the distractor play aloud for most of the run; fixed (`ProcessMuter`
  now runs its tap) and verified with the mic (-24 dB).

**Done when:** unit tests prove buffers are zeroed after finalization and that backlog
overflow produces a gap instead of a write. A 45-minute synthetic session with the
transcriber artificially throttled shows degrade → alert → gap, in that order.

### P2.4 Transcriber protocol + Parakeet (default) and SpeechAnalyzer adapters (4 d)
```swift
protocol Transcriber {
  func prepare(locale: Locale, context: [String]) async throws   // AssetInventory install/reserve
  func stream(track: Track, utterances: AsyncStream<Utterance>) -> AsyncThrowingStream<Segment, Error>
  func finish() async throws                                     // finalize(through:) at Stop
}
```
- **Parakeet TDT v3 via FluidAudio** (CoreML, Neural Engine), in-process: VAD utterances
  in, segments out, weights from the shared store. Default engine.
- `SpeechAnalyzer.start(inputSequence:)` over `AnalyzerInput` per track. **Keep only
  `isFinal` results**; volatile results feed nothing but an optional debug view.
  `finalize(through:)` at Stop.
- `audioTimeRange` → segment times (re-based to the capture clock), `alternatives` →
  confidence, `AnalysisContext.contextualStrings` ← vocabulary (program acronyms, med names,
  staff names, the client's name from the form).
- `prepare` shows the OS asset download progress honestly. That first-run download exists,
  even though we don't bundle the model.
- Merge the two tracks by time into one `Transcript`. Speaker = track.

- **Measured 2026-09-23** on the synthetic 2-minute session (`scripts/synth-audio.swift`),
  live tap on `afplay` + worker injected from file + a distractor voice in another app:

  | Engine | Client WER | Worker WER | Lines missed | Stop → transcript |
  | --- | --- | --- | --- | --- |
  | Parakeet TDT v3 (FluidAudio 0.16.1) | **0%** | **0%** | 0 / 17 | 0.01 s |
  | SpeechAnalyzer | 3.3% | 4.6% | 0 / 17 | 0.09 s |

  TTS proves correctness, not real-call accuracy (P2.8 decides the default).
- **SpeechAnalyzer needs an unbroken timeline.** Fed VAD utterances with explicit start
  times it fragments and repeats words at the joins (11.5% WER, 20% live). Filling the gaps
  with zeros, in whole samples, and sending "silence until t" markers every 50 ms while
  nobody speaks gets it to 3.1%. A half-sample overlap between buffers crashes it.
- Parakeet loads from the shared store with `AsrModels.loadLocal` (never downloads). First
  load compiles for the Neural Engine (~40 s), cached by the OS after. It has no biasing API.
- Known nit: SpeechAnalyzer once emitted "E E" over a silent stretch. Not seen with Parakeet.

### P2.5 Qwen3-ASR adapter + second-voice flag (3 d)
- **Qwen3-ASR 1.7B via MLX Swift**, in-process, same utterance interface. It runs on the
  GPU **during the call**, competing with Zoom; P2.8 measures that. Parakeet on the Neural
  Engine contends less.
- **Second voice on the client line:** Sortformer (CoreML) on the client track only.
  Spans with >1 speaker are flagged in the transcript and the HUD. Speakers are never
  relabelled (DESIGN §3).
- The worker picks the engine in settings; the choice is recorded per session.

### P2.6 Encrypted audio tee, only when retention ≠ `none` (2 d)
- The same 16 kHz Int16 stream, in 1-second chunks, sealed with **AES-GCM** under the
  per-session Keychain key (`WhenUnlockedThisDeviceOnly`) with `(track, chunk_index)` as
  AAD, appended to `session.sbk` and fsync'd every few seconds.
- Crash recovery: everything up to the last complete chunk decrypts. That lets a
  `until_confirm` session re-transcribe after a transcriber crash.
- ≈ 64 KB/s ≈ **230 MB/hour**.

**Done when:** kill -9 mid-session, relaunch, and audio is recoverable to within 1 s of the
kill (retained modes). No plaintext audio touches disk in any mode.

### P2.7 Synthetic test audio + the zero-recording proof (3 d)
- `scripts/synth-audio.sh session.txt` renders each speaker's lines with `say` in distinct
  voices (worker Samantha; client Daniel/Moira/Tessa for accent spread), with timing gaps, into `worker.wav` + `client.wav`.
- **Capture isolation test:** `afplay client.wav` is the tapped process, and
  `afplay distractor.wav` runs at the same time and **must not appear** in the client track
  (checked by cross-correlation). The worker track is injected from file.
- **Zero-recording test**, the proof behind the §3a claim:
  - During a `none` session, run `fs_usage -f filesys` on our PIDs and the sidecars' PIDs,
    and assert that total bytes written are consistent with transcript text (KB), not audio
    (MB).
  - Afterwards, scan the data dir, `$TMPDIR`, and `~/Library/Caches/<bundle-id>` for any file
    containing the synthetic audio's known PCM fingerprint.
  - Assert the audit log records `retention: none`.
- **TTS audio proves the pipeline is correct, not how accurate it is.**

- **Built 2026-09-23:** `swift scripts/synth-audio.swift fixtures/sample-session.txt <dir>
  --minutes N` → `worker.wav`, `client.wav`, `distractor.wav`, `reference.json`. The app's
  `--transcribe-probe - <s> <out.json> --client-file … --worker-file … --distractor-file …
  --reference … [--engine parakeet] [--rebuild-at s]` plays the client with `afplay`, taps it,
  injects the worker in real time, and reports WER, missed lines, gaps, and
  **`diskBytesWritten`** from `proc_pid_rusage` (no root, unlike `fs_usage`): **0 bytes** over
  a 2-minute two-track session.

**Done when:** `CaptureE2E` and `ZeroRecording` pass locally, and the transcript is good enough
for Phase 1 extraction to still pass its gates.

### P2.8 ASR bake-off (4 d)
- **Corpus:** 6–10 role-played sessions over real Zoom between consenting colleagues, using
  fixture scripts plus improvisation. Include varied accents, one code-switched
  English/Spanish session, one with the worker on headphones, and one with the client on a
  cellular dial-in. Hand-correct reference transcripts. *(Recorded for the bake-off with
  consent; that's separate from the product's retention mode.)*
- **Metrics:** WER; **entity error rate** (names, dates, numbers, meds, acronyms);
  **streaming-vs-batch WER delta**; **real-time factor with Zoom running, on the 32 GB
  loaner**; backlog high-water mark; peak RAM. The **decisive** metric: run Phase 1
  extraction on each output and compare field accuracy against the gold transcript.
- **Candidates:** Parakeet TDT v3 (default), Qwen3-ASR 1.7B, SpeechAnalyzer (baseline).

**Done when:** `eval/asr-bakeoff.md` names a default transcriber, and states whether that
transcriber keeps up in real time on the 32 GB floor. If it doesn't, zero-recording needs a
hardware requirement (R10).

### 🎬 Demo 2
Set retention to **`none`**, start the menu-bar app, join a Zoom call, and talk. The worker
hears the client normally, and music in another app is absent from the transcript. Stop,
and the two-track, timestamped transcript is ready **within seconds**. Then show the data
directory: no audio file exists, and `fs_usage` shows kilobytes written, not megabytes.

---

## 7. Phase 3: The product loop

### P3.1 Orchestrator (3 d)
- **Built 2026-09-23** (`ChartFinder`, `SafariTabs`, `NotePipeline`): a learned form is
  profile + mapping + templates + chart spec (origin, path pattern, banner selector, client
  ID/name regexes). `scribeski charts` lists what's open; `scribeski fill-chart --client`
  runs the app's fill path. Live: the chart in a background window was found, brought
  forward, filled (60 written, identity verified); a client whose chart isn't open is
  refused. Safari scripting moved from NSAppleScript to ScriptingBridge: NSAppleScript off
  the main thread hung a fill. The audit log records the client as `ct:` + HMAC-SHA256
  (install key in the Keychain), never the ID.
- **Agreed 2026-09-23 — bind the session to a chart at Start.** At Start, scan all Safari
  windows by URL only (never inject into a tab that doesn't match a learned form), read the
  client banner (selector saved at learn time) on matches, and show "Chart: Maria Reyes ·
  AB-114322 · [Intake ▾] · Change". Pressing Start confirms it; several charts open → the
  worker picks, never a guess; none open → "pick before filling". At fill: find that client's
  tab in any window, bring it forward, re-read the banner (hard stop on a different client),
  then confirm "Fill Maria Reyes · AB-114322?". Extraction no longer needs the page open.
  Open question: record the client in the audit log as a keyed hash (recommended) or plain.
An explicit, persisted state machine:
`idle → armed(consent) → recording → stopping → transcribing → extracting → filling →
reviewing → confirmed → purged`, plus `failed(stage, error)`.
Every transition is persisted. A crash mid-extraction resumes from the transcript. **Nothing
ever asks the worker to re-record.**

### P3.2 Sidecar lifecycle: llama-server (2 d)
- **Built 2026-09-23** (`Sources/Extraction/LlamaServer.swift`, `UnixSocketHTTP.swift`):
  llama.cpp b10964 binds a unix socket when `--host` ends in `.sock`; URLSession can't reach
  one, so a ~150-line HTTP/1.1 client runs over `NWConnection`. The key goes in through
  `--api-key-file` (0600, deleted once read), so it never appears in `ps`. After launch the
  app checks that `/slots`, the web UI, and keyless requests are all refused, and refuses
  to send the transcript otherwise. `SCRIBESKI_LLM_TESTS=1` runs the real lifecycle (7 s
  with warm page cache). Two instances share the mmapped weights, so a stray dev server
  doesn't double RAM.
- `scribeski note` on the sample session: 60 filled / 11 clinician / 27 insufficient / 6
  rejected; 60 written, 0 not ok, 0 page requests; extract 257 s, model load 1.5 s. Scores
  87.3% (P1.6's baseline); `safety_plan` came back rejected this run (1 risk-field error),
  so extraction isn't fully run-to-run stable.

- Pinned build, bundled binary. **Spawned only after recording stops**, never during the
  call: ~16 GB of weights competing with Zoom on a 32 GB machine would hurt the call.
  Weights load from the shared store (P1.8).
  Unloaded after N idle minutes.
- **Locked down:** unix socket if the pinned version supports it, otherwise 127.0.0.1 on a
  random port with a per-launch `--api-key`. **Web UI disabled. Slot-inspection endpoints
  disabled** (`/slots` can expose cached prompts, i.e. the transcript, to any local process).
  Verify every flag against the pinned version. Erase slots at session end.
- The ASR engine is unloaded at Stop, before `llama-server` starts.
- Peak-RSS check on the 32 GB loaner: ASR and LLM are **never resident at the same time**.

### P3.3 Review HUD, native (5 d)
- **Built 2026-09-23** (`ReviewView.swift`): a floating SwiftUI window. The page bundle got
  `focus` (open step, scroll, focus; changes nothing) and `fill.overwrite` (the worker's
  edit replaces our own earlier value instead of being skipped as a conflict); both have
  Playwright tests. Every review action re-profiles the front tab and refuses if its
  fingerprint isn't the extracted form's. Undo all returns to the fill confirmation.
  `--demo-review <outcome> <profile> <transcript> [field]` opens it on files.

- A floating `NSPanel` beside Safari, not injected into the page.
- **Target confirmation** before any fill: shows the tab's title and the client banner
  text so the worker confirms the right chart (the identity check backs it up).
- Badges: *model not validated* when the worker chose a model outside the eval gates;
  *second voice on client line*; cross-field consistency flags.
- Fields grouped by step, with status chips: filled · needs your judgement · insufficient
  evidence · conflict skipped · write failed.
- Selecting a field scrolls to and focuses it in Safari (via the page bundle), shows the
  verbatim quote(s) with speaker and timestamp, and, **only if audio was retained**, plays
  that span natively from the encrypted store. In `none` mode the play control is replaced by
  "audio not recorded". Gaps are listed at the top so the worker knows what the transcript
  is missing.
- Edit here, write via the filler, and record the value as `edited_by_worker` in the audit log.
  Clear. Undo all.
- **Confirm** ("I've reviewed this") triggers purge per retention policy. Submitting the form
  in the EHR remains the worker's own action.

### P3.4 Learn-form + mapping review UI (4 d)
- **Built 2026-09-23:** `NoteTemplate` (per-field mode/intent overrides, `update` for
  follow-ups), `FormPack` (`scribeski packs export|import`), templates picked at Start
  (remembered per form), audited per session. `fixtures/mock-ehr/templates.json`: Intake =
  base; Follow-up skips identity on file and marks contact/address/insurance/emergency
  contact updatable. In review an updatable field with a different value on file shows
  "On file → Session" with Accept change. The profiler skips framework-generated ids
  (`:r3:`, `mui-…`, `mat-input-…`, UUIDs, long digit/hex runs) so keys survive reloads.
- **Built 2026-09-23, clearing the open items:**
  - **Learn window** (`LearnView`/`LearnModel`, "Learn a form…" in the menu): reads the
    front tab (the one tab Scribeski injects into without it being learned, because the
    worker asked), flags cross-origin frames, suggests client banners (page op
    `banner_candidates`: smallest element with an ID-like token, banner-ish ids/classes and
    top-of-page ranked first), proposes ID/name patterns from the example
    (`AB-114322` → `Record[:#\s]+([A-Z]{2}-\d{6})`), previews what they read, shows the
    exact scrubbed payload, runs the mapping on the local sidecar, and saves with the chart
    spec. Re-learning sends only fields the old mapping lacks.
  - **Drift** (`FormDrift`): same key → kept; else label + kind (+ options) → moved, mapping
    carried; unmatched → `skip` until mapped; options pruned where they vanished; templates
    and derivations follow renames. A fill that finds the form changed shows the summary with
    "Accept changes and fill", which also moves the extracted answers to the new keys.
  - **Walk mode is deferred:** tab-based wizards keep hidden steps in the DOM (the profiler
    already covers them); a wizard that renders steps only on navigation needs per-step
    profiles at fill time too. Build it against the first real EHR that needs it.
- **Agreed 2026-09-23 — note templates and form packs.** A template = form + session type
  (Intake, Follow-up, Crisis…), a thin override of the form's base mapping (skip fields,
  reword intents, fields a follow-up may *update*). An agency lead learns each form once,
  reviews mappings here, and publishes a form pack (form + templates) workers import; the
  agency config profile can push it. Workers only pick the session type at Start.
  Follow-up updates to values already on file show in review as "proposed change: X → Y",
  written only when accepted.
- **Field-key stability.** Keys come from `id`, then `name`, `data-testid`, then a hash of
  label + kind + step. Stable on server-rendered EHRs; they break on generated ids
  (`:r3:`, `mui-12345`, `mat-input-7`), markup updates, reworded labels, and per-client
  repeats. To do: detect generated ids and skip them, profile twice at learn time and flag
  unstable keys, re-match drifted fields by label + kind + options for worker review, and
  keep per-client option lists (household members, staff) out of the fingerprint.
- Until this lands, `scribeski forms add <mapping.json>` installs a mapping into
  `~/Library/Application Support/Scribeski/forms/`, found by profile fingerprint.

- Learn this form: profile the front tab. *Walk mode* for lazy-rendered wizards (record the
  worker's clicks as step activations).
- Mapping table: intent, mode, evidence speaker, and option semantics, all editable.
- **Egress preview:** the exact JSON that will leave the machine, with an explicit Send
  button. Provider settings: local (default) or an OpenAI-compatible URL, with the key in
  the Keychain.
- **Drift check at run time:** re-profile before filling and compare fingerprints. On drift,
  fill only the unchanged fields and prompt for re-learning.

### P3.5 Storage, retention, audit (4 d)
- **Built 2026-09-23** (`Sources/Storage`): JSON Lines instead of GRDB (no dependency; the
  chain is the same). Keys try the data-protection keychain and fall back to the login
  keychain until the app is provisioned (P4.1). Audit events: armed (consent, retention,
  source, engine), recording, stopped, transcribed, extracted (status counts, model),
  fill_confirmed, filled, edited_by_worker (key only), undo_all, confirmed, purged.

- GRDB SQLite for metadata. Blobs (audio, transcript, results) are encrypted with the
  per-session key.
- **Delete = destroy the Keychain key** (DESIGN §8).
- The data directory gets `.metadata_never_index` and `NSURLIsExcludedFromBackupKey`, and
  both are verified.
- **Audit log:** append-only rows **hash-chained** (each row stores the SHA-256 of the
  previous one) for tamper evidence. It survives purge. It holds consent, models + hashes,
  per-field status and confidence, worker edits, confirm time, and purge time. It never holds
  transcript text.
- **Retention mode** (`none` / `until_confirm` / `days:N`) is a policy setting, fixed at arm
  time for the session and recorded in the audit log. It can be locked by an agency config
  profile. `none` enforces its preconditions (FileVault, sleep assertion) at arm time.
- Retention scheduler at launch and hourly. Warn at N unconfirmed sessions, and block arming
  at 2N.
- All logging through `os_log` with `privacy: .private` on anything session-derived.

### P3.6 Menu-bar UX (3 d)
Consent affirmation gates arming. The retention mode is always visible while armed, e.g.
**"Transcribing · audio not recorded"**, so the worker can say it truthfully to the client.
Call-app picker (auto-detected) with the browser-call warning. Backlog alarm ("transcription
falling behind"). Live dual level meters. Silent-client alarm. Timer. Stop. Pipeline progress.
Completion notification that opens the HUD.

### 🎬 Demo 3
All in the app: a real Zoom role-play, then stop, then the mock EHR fills while the HUD
opens. Click `si_ideation` to see and hear the client's exact words. Fix one field, confirm,
and the audio key is destroyed. The audit log verifies its hash chain and shows the edit.
Run it again in **`none` mode**: same result, with quotes and no playback, and nothing audio
ever on disk. Repeat both on the 32 GB loaner.

---

## 8. Phase 4: Ship

| Task | Est. | Done when |
| --- | --- | --- |
| **P4.1 Packaging** — Developer ID, hardened runtime; `llama-server` built from pinned source with Metal, signed, in `Contents/Helpers`; `notarytool` + staple; DMG | 3 d | Clean-machine install passes Gatekeeper with no warnings |
| **P4.2 Model manager UI + signed catalog** — sign the P1.8 catalog; settings UI to pick models per role (defaults preselected, custom models marked *not validated*); background download with progress; licence attributions (Parakeet CC-BY-4.0) in About | 3 d | Interrupted download resumes; tampered file refused |
| **P4.3 Onboarding** — permission walkthrough with live checks; detect the Safari toggle through the verified error string; OS speech-asset install; model download; learn first form; 10-second test recording | 3 d | A non-engineer completes it unaided |
| **P4.4 Updates & crash policy** — Sparkle with EdDSA-signed appcast; no third-party crash SDK; local crash logs only, scrubbed; sharing is opt-in | 2 d | Update from v0.1 → v0.2 on a clean machine |
| **P4.5 Security review** — threat model (local processes, EHR page scripts, egress); checklist: nothing in logs/temp, sidecar locked down, egress only at setup with preview, Time Machine/Spotlight exclusion, crash leaves no plaintext; run `/security-review` | 3 d | Checklist signed off, findings fixed |
| **P4.6 Pilot** — profile the real EHR and turn its hard cases into fixtures first; 2–3 workers × 2 weeks | calendar | Metrics below |

**Pilot metrics.** The key one is **edit rate per field**: the share of filled fields the
worker changed. Also: time-to-note vs. their baseline; blank rate; and **fabrications found,
target zero**. Each fabrication is a P0 incident with transcript review and a new fixture
that reproduces it.

---

## 9. Test strategy

| Layer | Tool | Runs in CI | What it guards |
| --- | --- | --- | --- |
| Contracts, schema builder, verifier, derivations, crypto, audit chain | swift-testing | ✅ | Logic |
| Page bundle: profile, fill, read-back, submit guard, CSP | Playwright-WebKit on `fixtures/` | ✅ | DOM hard cases |
| Safari transport | `scribeski js` smoke script | ❌ local (needs GUI + toggle) | AppleScript path |
| Extraction quality | `scribeski eval` + gates | ❌ local (needs model) · tiny-model smoke in CI | Fabrication, accuracy, **cache hit** |
| Capture | `afplay` target + distractor, cross-correlation | ❌ local (needs TCC) | Per-process isolation, dropouts |
| Zero-recording | `fs_usage` byte accounting + PCM-fingerprint disk scan | ❌ local | **The "no audio on disk" claim** |
| Memory hygiene | swift-testing on segmenter: zeroing, backlog overflow → gap | ✅ | Buffers wiped, no spill |
| ASR | bake-off corpus | ❌ manual, per model change | Accuracy on real calls |
| End to end | synth audio → full pipeline → mock EHR | ❌ local | Everything wired |

**Rule:** every bug found in pilot becomes a fixture before it becomes a fix.

---

## 10. Critical path

```
P1.0 ─┬─ P1.1 ── P1.2 ── P1.3 ──────────────┐
      ├─ P1.8 (model store) ─────┐
      └─ P1.4 ── P1.5 ── P1.6 ── P1.7 ──────┼─ 🎬1 ─┐
                                            │       ├─ P3.1 ─ P3.2 ─ P3.3 ─ P3.4 ─ P3.5 ─ P3.6 ─ 🎬3 ─ P4.* ─ Pilot
P2.0 ── P2.1 ── P2.2 ── P2.3 ─┬─ P2.4 ─┬─ P2.8 ── 🎬2 ─┘
                              ├─ P2.5 ─┤   (Qwen3-ASR + second-voice flag)
                              └─ P2.7 ─┘   (synthetic audio + zero-recording proof; feeds P2.8)
                  P2.6 audio tee (after P2.3; off the critical path)
```

The two longest poles are **P1.5→P1.6** (extraction quality) and **P2.2** (the tap). Start
both in week 1.

---

## 11. Risk register

| # | Risk | Surfaces at | Early signal | Mitigation | Pivot if mitigation fails |
| --- | --- | --- | --- | --- | --- |
| R1 | 8B model can't reach **0 fabrications** | P1.6 | Held-out blank violations | Larger model where RAM allows; more `clinician_only`; tighter option semantics | v1 fills **discrete fields only**; narrative becomes clearly labelled drafts |
| R2 | Prefix cache silently misses | P1.6 | Cache assertion fails | Full-attention model; `--swa-full` if memory allows | Batch several fields per request to amortize prefill |
| R3 | `do JavaScript` blocked (CSP, async, size) | P1.1 | Spike findings | Job protocol; ScriptingBridge; no eval in bundle | **Safari Web Extension** (content script + native messaging) — heavier, sanctioned |
| R4 | Tap misses Zoom/Teams helper audio | P2.1–2.2 | Silent client track in tests | Bundle-family matching; late attach | ScreenCaptureKit per-app audio, accepting the Screen Recording prompt |
| R5 | Browser-based calls (Meet) tap the whole browser | P2.1 | Meet in a Safari tab | Safari web app per call service; UI warning otherwise | Scribeski-hosted `WKWebView`; else documented limitation |
| R6 | Default ASR weak on accented telephony | P2.8 | Entity error rate | Vocabulary context / post-correction | Qwen3-ASR or SpeechAnalyzer becomes the default |
| R7 | Real EHR has cross-origin iframes / canvas / Citrix | P4.6 | `unreachable` in profile | Name the EHR early | Accessibility-API driver (new milestone) |
| R8 | 32 GB machines swap with Gemma 4 + `--swa-full` | P1.6 / P3.2 | Peak RSS, GPU working-set limit | One slot, q8_0 KV, ASR and LLM never co-resident; idle unload | Smaller Gemma 4 (12B) as a validated low-RAM option |
| R9 | TCC grants lost across builds | P2.0 | Re-prompts every build | Stable signing identity | — |
| R10 | Streaming ASR can't keep up **during** a Zoom call on 32 GB | P2.8 | Backlog high-water, RTF under load | Parakeet on the Neural Engine; `fastResults` | Zero-recording gets a hardware floor. Other modes can fall back to re-transcribing from the tee after Stop |
| R11 | Audio in framework-internal buffers we don't control (SpeechAnalyzer, CoreML, MLX) | P2.4 | — | Encrypted swap + FileVault precondition | State the claim exactly (DESIGN §3a): *we* never write audio to disk. Don't round it up |
| R12 | **Wrong client's chart** filled | P1.1 / P3.3 | Two records open in Safari | Identity check + HUD target confirmation | Refuse to fill unless exactly one tab matches the profile |
| R13 | **EHR autosaves** unreviewed values to its server | P1.3 | Network requests during fill | Detect; switch to review-then-fill | Worker copies approved values from the HUD by hand |
| R14 | Worker picks a model that fabricates | P1.8 / P4.2 | Model not in the validated catalog | *Not validated* badge + audit log | Agency config profile can lock model choice |
| R15 | Synthetic corpus understates real sessions (72–98 wpm vs 130–160) | P1.6 / P1.9 | Context and latency jump on the P2.8 role-plays | Generate at real rates; re-baseline on role-plays | Raise the context split threshold; more aggressive quote caps |

---

## 12. Deferred decisions: who decides, and by when

| Decision | Decided by | Deadline |
| --- | --- | --- |
| **Target EHR** | You | End of Phase 1 |
| Note language for non-English sessions | **Decided (2026-09-22): v1 is English-only.** Spanish sessions are out of scope | — |
| Default LLM | **Gemma 4 26B-A4B QAT** (approved 2026-09-22); P1.6 eval confirms or swaps to 31B | End of Phase 1 |
| Default transcriber | **Parakeet TDT v3** provisionally; P2.8 bake-off confirms | End of Phase 2 |
| Hardware floor | **Decided: 32 GB** (2026-09-22) | — |
| **Default retention mode**, and whether agencies can lock it | You | Before P3.5 |
| Audit depth (worker tool vs. agency compliance product) | You | Before P3.5 |
| Distribution and pricing | You | Before Phase 4 |
