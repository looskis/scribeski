# SuiteModelStore

A per-user, content-addressed store for local model weights, shared by every app in a suite of
privacy-first Apple-Silicon apps (Scribeski is the first). A 14 GB model is downloaded **once**
per user, verified against a pinned SHA-256 before anything can load it, and reused by every app
that needs it. Each app keeps its own record of which models it uses, with defaults out of the box
and user overrides.

- Swift 6.2, macOS 26+, Foundation + CryptoKit (plus Security for the entitlement check), no
  third-party dependencies.
- Standalone: it imports nothing from any app and is meant to move to its own repository.

## What it guarantees

- **Pinned, never "latest".** Every catalog file names an exact upstream commit, byte size and
  SHA-256. URLs contain the commit (`.../resolve/<sha>/<path>`).
- **Verified before load.** Downloads are hashed while streaming; on resume the existing partial
  bytes are re-hashed first. Nothing enters `blobs/` unless the size and hash match. A mismatch
  deletes the partial and throws `ModelStoreError.hashMismatch`.
- **Resumable.** Interrupted downloads stay in `tmp/<sha>.partial` and continue with an HTTP
  `Range` request (falling back to a full restart if the server ignores `Range`).
- **Once per user.** `flock(2)` locks per blob mean two apps (or two tasks) asking for the same
  file never download it twice; the second waits and reuses.
- **Nothing referenced is ever deleted.** GC only removes what no registered app references,
  and skips anything currently being downloaded.
- **No silent substitution.** If the machine has less RAM than a model needs, the resolver says
  `insufficient_ram`; the app decides what to do.

## Location

`ModelStore.resolveLocation(groupID:suiteName:)` (or `StoreLocation.resolve`) picks, in order:

| # | Source | Root (`Models/`) | When |
|---|---|---|---|
| 1 | `SUITE_MODEL_STORE` env var | the path itself | set to an absolute path (dev, CI, external disk) |
| 2 | App Group container | `~/Library/Group Containers/<group>/Models` | the process is signed with `com.apple.security.application-groups` containing `groupID` |
| 3 | Application Support | `~/Library/Application Support/<SuiteName>/Models` | fallback for unentitled dev tools |

The returned `StoreLocation` has `source` and a human-readable `reason` (including why earlier
options were skipped) — log it. The entitlement is checked *before* calling
`containerURL(forSecurityApplicationGroupIdentifier:)`, because an unentitled call can trigger a
"wants to access data from other apps" prompt on recent macOS. Unentitled dev tools that need to
share the apps' store should set `SUITE_MODEL_STORE` to the group container's `Models` path.

## Layout

```
Models/
  blobs/sha256-<hex>                    verified weights, chmod 0444
  snapshots/<model-id>@<rev>/<path>     relative symlinks into ../blobs (Hugging Face cache style)
  users/<app-id>.json                   which models each app depends on (GC roots)
  tmp/<hex>.partial                     resumable partial downloads
  locks/<hex>.lock                      per-blob download locks
  .lock                                 store-wide flock: snapshot linking, registration, GC
  .metadata_never_index                 keeps Spotlight out
```

`Models/` is marked `isExcludedFromBackup` (Time Machine). A multi-file model (a CoreML
`.mlmodelc` directory, an MLX directory, tokenizer files) becomes a snapshot directory you pass
straight to the loader; a single GGUF gets a snapshot containing one symlink. Identical files
across models (e.g. a shared tokenizer) are stored once.

## Adopting it in an app

```swift
import SuiteModelStore

// 1. Open the store. Production group id: "<TEAMID>.<suite>" (Developer ID signed, unsandboxed,
//    with the application-groups entitlement).
let location = ModelStore.resolveLocation(groupID: "ABCDE12345.com.example.suite", suiteName: "ExampleSuite")
log("model store: \(location.root.path) — \(location.reason)")
let store = try ModelStore(location: location)            // built-in catalog

// 2. Load this app's selection (the app decides where its settings live).
let selections = SelectionStore(url: appSupport.appendingPathComponent("model-selection.json"))
let selection = try selections.load()                      // empty → catalog defaults

// 3. Resolve each role.
let llm = Resolver.resolve(role: .llm, selection: selection, catalog: store.catalog)
let asr = Resolver.resolve(role: .asr, selection: selection, catalog: store.catalog)
switch llm.status {
case .ok: break
case .insufficientRAM:   /* offer a smaller model; don't pick one silently */ break
case .unknownModel, .roleMismatch, .noDefault: /* reset to default / ask */ break
}
if !llm.validated { /* warn: "this model hasn't passed <App>'s accuracy checks"; audit-log it */ }

// 4. Register what this app depends on (GC roots), then ensure it's on disk.
let manifests = [llm, asr].compactMap(\.manifest)
try await store.register(app: "com.example.scribeski", models: manifests)
for try await event in store.ensureStream(manifests[0]) {
    switch event {
    case .progress(let p): updateUI(p.fractionCompleted, p.phase)
    case .completed(let snapshotDir): load(snapshotDir)
    }
}
```

Other API:

- `store.ensure(manifest, progress:) async throws -> URL` — same as the stream, returns the snapshot dir.
- `store.localURL(for:) -> URL?` — snapshot dir if complete (stat-only, cheap; call at launch).
- `store.verify(manifest) async throws -> VerificationReport` — full re-hash; corrupt blobs are
  removed so the next `ensure` re-downloads.
- `store.unregister(app:)`, `store.registrations()`,
  `store.garbageCollect(dryRun:) -> GarbageCollectionReport`.
- `CustomModel` — `.local(path:)` (not store-managed) or `.remote(url:sha256:size:)` (fetched and
  verified like any other blob via `resolution.manifest`). Custom models are always
  `validated == false`.
- Errors: `ModelStoreError.hashMismatch`, `.sizeMismatch`, `.insufficientDiskSpace` (preflight via
  `volumeAvailableCapacityForImportantUsage` with a 2 GiB margin), `.httpStatus`,
  `.invalidManifest` (unsafe ids/paths are rejected before touching disk).

Register before (or right after) `ensure`: GC treats unregistered models as garbage.

**Load-time note:** CoreML, llama.cpp and MLX all follow symlinks, so loaders take the snapshot
directory as-is. Blobs are read-only (0444); nothing should write into a snapshot.

## Manifest and catalog JSON

```json
{
  "schema_version": 1,
  "defaults": { "llm": "<id>", "asr": "<id>", "diarizer": "<id>" },
  "models": [{
    "id": "...", "display_name": "...", "role": "llm|asr|diarizer|vad", "format": "gguf|coreml|mlx",
    "source": "<hf repo>", "revision": "<40-hex commit>", "license": "Apache-2.0",
    "license_url": "...", "min_ram_gb": 32,
    "files": [{ "path": "...", "url": "https://huggingface.co/<repo>/resolve/<commit>/<path>",
                "sha256": "<64 hex>", "size": 123 }],
    "notes": "...", "validated": false
  }]
}
```

`validated` means "passed the owning app's evaluation gates". Every built-in entry currently
ships `validated: false` — flip an entry to `true` only after the eval gates pass on that exact
revision.

## Re-pinning the catalog

```sh
scripts/pin-catalog.sh           # re-resolve each entry's ref (default "main") → commit, rewrite catalog.json
scripts/pin-catalog.sh --check   # regenerate to a temp file and diff (ignores the pinned_at date)
```

The script uses the Hugging Face API for metadata only: `api/models/<repo>/revision/<ref>` for
the commit and `api/models/<repo>/tree/<commit>?recursive=true` for sizes and `lfs.oid` (the
SHA-256). Small non-LFS files (JSON, CoreML `model.mil`, vocab; a few MB total) have no SHA-256 in
the API, so the script fetches and hashes those. Weights are never downloaded. The entry list,
include/exclude patterns, licenses, RAM floors and notes live at the top of the script. After
re-pinning, review the diff and reset `validated` to `false` for any entry whose revision changed.

## Built-in catalog (pinned 2026-09-23)

| id | role | repo @ commit | size | license | min RAM |
|---|---|---|---|---|---|
| `gemma-4-26b-a4b-it-qat-q4_0` (**default llm**) | llm | `google/gemma-4-26B-A4B-it-qat-q4_0-gguf` @ `d1c082be` | 14.44 GB (1 file) | Apache-2.0 | 32 GB |
| `gemma-4-31b-it-qat-q4_0` | llm | `google/gemma-4-31B-it-qat-q4_0-gguf` @ `59dde245` | 17.65 GB (1 file) | Apache-2.0 | 32 GB |
| `parakeet-tdt-0.6b-v3-coreml` (**default asr**) | asr | `FluidInference/parakeet-tdt-0.6b-v3-coreml` @ `7dd20fe6` | 0.48 GB (22 files) | CC-BY-4.0 | 8 GB |
| `qwen3-asr-1.7b-mlx-8bit` | asr | `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` @ `e5450a26` | 2.47 GB (6 files) | Apache-2.0 | 16 GB |
| `sortformer-4spk-v2.1-coreml` (**default diarizer**) | diarizer | `FluidInference/diar-streaming-sortformer-coreml` @ `ae9a27ab` | 0.24 GB (10 files) | see below | 8 GB |

### Licensing notes

- **Gemma 4 (both entries): Apache-2.0**, per the official model cards (link:
  https://ai.google.dev/gemma/docs/gemma_4_license). Official Google QAT Q4_0 GGUFs. The vision
  projector (`*-mmproj.gguf`, ~1.2 GB) is excluded: the suite only uses text. Gemma 4 uses hybrid
  sliding-window attention — run `llama-server --swa-full` or prefix caching is silently lost.
  The 31B weights are ~17.7 GB, under the ~20 GB line where 48 GB would be needed, so its floor
  is 32 GB, but that is tight next to KV cache and ASR.
- **Parakeet TDT 0.6B v3: CC-BY-4.0 — attribution required.** Credit NVIDIA
  (`nvidia/parakeet-tdt-0.6b-v3`) and FluidInference (CoreML conversion) in each app's
  About/Licenses screen. The file set is exactly what FluidAudio loads for v3 at the default
  int8 encoder: `Preprocessor`, `Encoder`, `Decoder`, `JointDecisionv3` `.mlmodelc` +
  `parakeet_vocab.json` + `config.json`. The snapshot directory works as a FluidAudio model
  directory.
- **Qwen3-ASR 1.7B: Apache-2.0** (upstream `Qwen/Qwen3-ASR-1.7B`). This is a community MLX
  conversion by `aufklarer`, the repo `soniqo/speech-swift` uses as its large-model default
  (`Qwen3ASR.largeModelId`). speech-swift's docs also list a 5-bit build with lower WER on a
  small sample; 8-bit is pinned because it is the library's code default.
- **Sortformer v2.1 (diarizer): license unconfirmed.** The FluidInference repo card says
  `cc-by-4.0`, but the base model `nvidia/diar_streaming_sortformer_4spk-v2.1` is under the
  **NVIDIA Open Model License**, which governs derivatives. Treat it as the NVIDIA Open Model
  License (commercial use allowed; attribution and notice required) until legal confirms. File
  set: FluidAudio's default streaming variant (`v3/fp16/Sortformer_v2.1.mlmodelc`). It is used
  only to flag a second voice on the client track.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -plugin-path -Xswiftc /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing
```

swift-testing only. The tests use temp directories and a `URLProtocol` stub that serves
deterministic bytes and honors `Range`. They never touch the network.
