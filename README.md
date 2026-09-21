# Scribeski

**Visit notes for social workers, written on your Mac.** Scribeski listens to a remote
session (Zoom, Google Meet, and other call apps), transcribes it on the device, drafts the
note with a local language model, and fills your agency's EHR form in Safari. You review
every field before anything is final.

Nothing about a session leaves the Mac. By default nothing is recorded, either: audio lives
in memory for seconds and is never written to disk.

[**Download the latest release**](https://github.com/looskis/scribeski/releases/latest) ·
[Security](SECURITY.md) · [Deploying for an agency](SHIPPING.md) · [Design](DESIGN.md)

---

## How it works

1. **Start with the call.** Scribeski notices when Zoom or a Meet tab starts using the mic
   and offers to transcribe. You confirm the client has agreed and pick their chart. That
   binds the session to that client.
2. **Two tracks, no guessing who spoke.**
   - Your voice comes from the mic, and the client's from the call app's own audio, captured
     from that app alone and never the whole Mac. Speaker labels come from which track the
     audio was on, not from a model.
   - Speaker echo is cancelled on the mic.
   - A second voice on the client's line is flagged, never relabelled.
3. **Transcribed live, on device.** Parakeet runs on the Neural Engine during the call, so
   the transcript is ready seconds after you stop. Apple's speech engine is the fallback.
4. **The note, drafted locally.** After the call, a local model (Gemma 4, via a bundled and
   locked-down `llama-server`) fills each field of your form from the transcript, with the
   quote it came from.
   - Fields that need clinical judgement are left for you.
   - So is anything the session didn't clearly answer.
5. **Filled in Safari, then reviewed.**
   - Scribeski writes into the chart you picked, after checking the page still shows that
     client, and never submits.
   - A review panel lists every field with its status and the quote behind it, plus playback
     if your agency keeps audio.
   - You can edit a field, jump to it in the form, or undo everything. Then you confirm.

Scribeski learns each EHR form once. Open a blank form (or a test client), paste its address,
and it reads the form's structure (labels and choices, never values), then maps it to what a
session can answer. Agencies can share learned forms as a form pack.

## Privacy

- **Nothing leaves the Mac.** The transcription and the note-writing both run locally. The
  only network use is downloading models (pinned by hash) and checking for app updates.
- **Zero recording by default.**
  - Audio is held in locked memory and wiped as soon as it's transcribed.
  - `scripts/e2e.sh` proves it: it measures the bytes written during a session.
  - Agencies can instead keep audio encrypted until the note is confirmed, or for N days.
- **Encrypted at rest.**
  - Transcripts and notes are sealed with a per-session key in the Mac's data-protection
    keychain. Deleting a session destroys its key.
  - Session data is excluded from Time Machine and Spotlight. Unreviewed sessions expire.
- **An audit log without client data.** Events and counts only; the client appears as a
  keyed hash.

The threat model, controls, and what's been verified are in [SECURITY.md](SECURITY.md).

## Requirements

- A Mac with Apple silicon on **macOS 26** or later. **32 GB of memory** recommended (the
  default note model needs it).
- About **15 GB** of disk for the models, downloaded during setup.
- **Safari**, with Settings → Advanced → *Show features for web developers* on, then
  Developer → **Allow JavaScript from Apple Events**. Onboarding walks you through it.
- FileVault on. Zero-recording sessions won't start without disk encryption.

## Install

Download `Scribeski-<version>.dmg` from [Releases](https://github.com/looskis/scribeski/releases/latest),
drag Scribeski to Applications, and open it. It lives in the menu bar. Setup covers
permissions (microphone, call audio, Safari), the model download, your recording choice,
and learning your first form. Updates install from within the app.

Agencies can lock settings (retention, how long notes are kept, engine, vocabulary) with a
configuration profile: see [SHIPPING.md](SHIPPING.md#6-agency-deployment-configuration-profile).

## Status

**0.1.0 is the first release, for pilots.**
- The pipeline is proven on synthetic two-voice sessions:
  - transcription is accurate, with 0% word error on TTS audio;
  - no audio reaches disk;
  - a 45-minute run is stable;
  - the note fills a mock EHR end to end.
- Next: role-played sessions over real Zoom calls, to measure accuracy on real voices
  (`scribeski asr-bakeoff`).

The plan and its progress are in [BUILD_PLAN.md](BUILD_PLAN.md).

## Development

You need Xcode 27 (macOS 26 SDK or later), Node for the page script, and `cmake` for the
`llama-server` helper.

```bash
swift build                                   # all packages and the dev CLI
scripts/swift-test.sh                         # Swift tests (works under Xcode or the CLT)
(cd page && npm ci && npx playwright install webkit && npm test)   # page script: build + Playwright
scripts/build-llama-server.sh                 # pinned, static llama-server → App/Helpers
open App/Scribeski.xcodeproj                  # the app (menu bar)
scripts/e2e.sh                                # live capture → transcript + zero-recording proof
scripts/release.sh --local                    # rehearse a release (no notarization)
```

The dev CLI (`.build/debug/scribeski`) covers:
- models: `models pull`, `models status`;
- form learning and packs: `forms`, `packs`;
- extraction and scoring: `extract`, `score`;
- the ASR bake-off: `asr-bakeoff`.

Debug builds of the app add developer probes (for example `--transcribe-probe` and
`--snapshot`). They're compiled out of Release.

### Layout

| Path | What's there |
|---|---|
| `App/` | The Xcode app shell (menu bar, windows), entitlements, the `llama-server` helper slot |
| `Sources/Capture` | Process taps, the aggregate device, the echo canceller, the VAD segmenter, locked audio buffers |
| `Sources/Transcription` | Parakeet and SpeechAnalyzer engines, live transcription, the second-voice flag, the bake-off |
| `Sources/Extraction` | Per-field extraction with verified quotes; the locked-down `llama-server` sidecar |
| `Sources/FormDriver` | Safari transport and the page script's command protocol |
| `Sources/Orchestrator` | Learned forms, chart binding, the note pipeline, form drift |
| `Sources/Storage` | Session keys, encrypted storage and audio, retention, the audit log |
| `Sources/ScribeskiUI` | The session model, the menu, review, onboarding, settings |
| `Sources/scribeski` | The dev CLI |
| `Packages/SuiteModelStore` | The model store shared with other Looski tools: pinned catalog, resumable verified downloads |
| `page/` | The TypeScript that runs in the EHR page: profile, fill, read-back, undo |
| `fixtures/` | A mock EHR and synthetic sessions (all people fictional) |
| `scripts/` | Build, release, e2e and synthetic-audio scripts |
| `eval/` | Extraction and classifier eval reports |
| `tools/` | Python: synthetic session generation and model-distillation experiments |

## License

MIT, see [LICENSE](LICENSE). Bundled and fetched third-party code keeps its own license;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
