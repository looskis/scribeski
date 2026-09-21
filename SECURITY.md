# Scribeski security review (BUILD_PLAN P4.5)

Reviewed 2026-09-23 against the current tree. This covers what is protected and from whom,
the controls with the code that implements each, what was checked and how, and what's left
for a person to decide.

## What we protect

Scribeski handles social-work sessions, which are protected health information:

- the client's words: live audio, transcript text, and field values;
- the client's identity: name and record number from the EHR banner;
- the fact that a session happened at all.

## From whom

| Adversary | In scope | Notes |
|---|---|---|
| Lost or stolen Mac | ✅ | FileVault is required before a session arms (`SessionGuards.checkZeroRecording`). |
| Backups and sync (Time Machine, iCloud, migration) | ✅ | Data folder excluded; keys are "this device only" (release builds). |
| Other macOS users on the Mac | ✅ | Per-user folders; sidecar socket in a 0700 folder. |
| Other apps running as the worker | Partly | See **Local processes** below. |
| Scripts on the EHR page (the EHR's own, or third-party) | Partly | See **Page scripts** below. |
| Network observers | ✅ | Nothing about sessions leaves the Mac. The only network use is model download (HTTPS, pinned hashes) and update checks. |
| Screen sharing during a call | Best effort | Client-text windows set `sharingType = .none`. |
| A worker filling the wrong client's chart | ✅ | Binding confirmed at Start; exact record-number check in the page before every write and undo. |

## Controls

**Zero recording (default mode, `Retention.none`)**

- Audio exists only in memory, and only for seconds:
  - capture ring buffers and utterance buffers are `mlock`ed and wiped with `memset_s` when
    freed (`RingBuffer`, `LockedPCM`);
  - the echo canceller's buffers never reallocate and are zeroed as they drain
    (`EchoCanceller.consume`).
- Core dumps are off (`RLIMIT_CORE 0` at launch). The sidecar inherits that.
- Proof: `scripts/e2e.sh` measures the bytes the process writes during capture
  (`proc_pid_rusage`; kilobytes, not audio) and fails if any file over 64 KB appears in the
  data, temp, or cache folders.

**At rest (retained modes and every transcript)**

- One AES-256 key per session in the Keychain, plus a separate key for its audio.
  - Data is sealed with AES-GCM, and its associated data binds each file to its session and
    name (`SessionStore.seal`).
  - Audio is sealed in 1-second chunks, each bound to session, track and index
    (`AudioVault`). A torn final chunk after a crash loses only that second.
  - Deleting data means destroying its key.
- **Release builds fail closed** if the data-protection keychain is unavailable
  (`SessionKeys.allowedBackends`). A session never falls back to the login keychain, which
  is backed up and migrated.
- Retention:
  - confirmed sessions are purged after `TranscriptDays`;
  - unreviewed sessions after the same number of days since they were made;
  - sessions that never started, after an hour;
  - audio kept "until you confirm" is purged at confirm, and `days:N` audio N days after the
    session.
  - A failed purge is audited and doesn't stop the pass (`SessionStore.purgeDue`).
- The data folder is excluded from Time Machine; session data sits in `sessions.noindex`,
  away from Spotlight (`verifyExclusions` reads both back).
- The audit log records events, counts and error *types*, never text. The client appears
  only as a keyed hash (`ClientTagger`, HMAC-SHA256 under a per-install key). Page-supplied
  strings are reduced to known values before they're logged.
- Notifications are generic ("Notes are ready"). Notification Center keeps its own copy
  outside our retention, so no name or record number ever goes into one.

**The note-writing sidecar (`llama-server`)**

- The binary is built from pinned llama.cpp source (`scripts/build-llama-server.sh`, tag
  b10964, commit checked). It's static and links only OS libraries.
  - It's signed with hardened runtime inside `Contents/Helpers`.
  - Release builds use only that copy.
- It listens on a unix socket in a fresh 0700 folder, with no TCP port.
  - The API key is random per launch, passed as a 0600 file and deleted once the sidecar is
    ready.
  - The web UI and `/slots` are off; both are verified live, and every probe must answer or
    the sidecar is refused.
- It gets a clean environment, so inherited `LLAMA_ARG_*` variables can't re-enable anything.
- Lifetime:
  - it starts after Stop and stops after extraction;
  - all sidecars stop at quit;
  - at launch, sidecars orphaned by a crash are killed and their folders removed
    (`LlamaServer.sweepOrphans`).

**Safari and the EHR page**

- The app only lists tabs by URL and title. JavaScript runs only in tabs whose origin and
  path match a learned form.
- Every dynamic string reaches JavaScript as a JSON literal, and ScriptingBridge passes the
  script as an object, not source text.
- The page bundle:
  - is built without `eval`;
  - makes no requests of its own;
  - uses no storage and no `innerHTML`;
  - only counts the page's own requests while filling.
- Before every fill and every undo:
  - the tab is re-profiled, and its fingerprint must match the learned form;
  - the banner must show the bound record number as a *whole token*, so `AB-11432` doesn't
    pass on `AB-114322`.
- Undo restores only fields that still hold what Scribeski wrote.
- Learned forms store structure only: labels, options and selectors. Record numbers in the
  URL path are replaced with `*` (`generalizePath`).
- Release builds ignore `SCRIBESKI_PAGE_BUNDLE` and `SUITE_MODEL_STORE`, so nobody can use
  `launchctl setenv` to swap the page script or the model weights.

**The shipped app**

- It's signed with Developer ID and hardened runtime, and notarized.
- Its only entitlements are the microphone, Apple Events, and (in release) the keychain
  group.
- Developer modes are compiled out of Release (`#if DEBUG`), and `scripts/release.sh` checks
  the binary for them. It also refuses ad-hoc-signed nested code and `get-task-allow`.
- Model downloads use HTTPS only, checked against pinned SHA-256 hashes before install.

## Checklist

| Check | How it was verified | Status |
|---|---|---|
| Nothing in logs | No `print`, `NSLog` or `Logger` in app code outside `#if DEBUG` | ✅ |
| Nothing in temp | e2e file scan; sidecar folder removed at stop, quit and launch | ✅ |
| Zero recording: bytes | `--transcribe-probe`: 0 bytes over 2 min; 45-min run 0 bytes | ✅ |
| Audio copy encrypted, recoverable | `AudioVaultTests`; live probe with `--retain`: 3/3 segments | ✅ |
| Sidecar locked down | `--sidecar-check` on the bundled, signed helper: lockdown verified | ✅ |
| Wrong-client writes | Playwright: fill and undo refuse a mismatched or prefix record | ✅ |
| Time Machine and Spotlight exclusion | `verifyExclusions` test | ✅ |
| Crash leaves no plaintext | No core dumps; checkpoints are sealed; orphaned sidecars swept | ✅ |
| Release has no dev modes | `release.sh` string check on the archived binary | ✅ |
| Notarized, Gatekeeper passes | `release.sh`, full mode | ⏳ needs the Developer ID certificate |
| Data-protection keychain in release | Provisioned build | ⏳ needs the provisioning profile |

## Residual risks (decided 2026-09-23)

1. **Page scripts share the page's JavaScript world. Accepted.** `do JavaScript` runs
   alongside the EHR's own scripts, so a hostile script on the EHR page could shadow the page
   bundle, fake a "verified" identity or a read-back, or read the values we fill. The EHR
   already renders the chart and no session data leaves the Mac, so we trust the EHR's page.
   A Safari Web Extension with an isolated world (BUILD_PLAN R3) stays the fix if that ever
   changes.
2. **The audit log is tamper-evident, not tamper-proof. Accepted.** The hash chain catches
   edits but not truncation of the newest lines. The latest hash isn't anchored in the
   Keychain: the log never leaves the Mac, and its integrity rests on the worker's account
   security, like everything else here.
3. **"Delete" means unreadable.** Destroying a key makes the ciphertext unreadable, but APFS
   local snapshots may keep the encrypted files *and* the keychain database for a while.
   Privacy wording says "unreadable once deleted", not "erased".
4. **Screen sharing.** `sharingType = .none` is best effort, and some capture paths may
   ignore it. Workers should be told not to share their screen while reviewing.
5. **Swift strings can't be wiped.** Transcript text lives in ordinary memory until it's
   freed. Core dumps are off, and swap is encrypted on Apple silicon.
6. **Other apps running as the worker** can read what the worker can. Scribeski doesn't
   defend against malware on the worker's account.
7. **The developer CLI** (`scribeski extract --endpoint …`) can send a transcript to any
   endpoint. It's a developer tool, not in the app bundle; don't install it on workers' Macs.
8. **http EHR origins stay allowed. Accepted.** Every target EHR is already served over
   https, so requiring it adds nothing today.
