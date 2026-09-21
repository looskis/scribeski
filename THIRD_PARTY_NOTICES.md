# Third-party notices

Scribeski's own code is under the MIT License (see `LICENSE`). These keep their own licenses:

| Component | Where | License |
|---|---|---|
| SpeexDSP (echo canceller) | vendored in `Sources/CSpeexEcho` | BSD 3-Clause, see `Sources/CSpeexEcho/COPYING` |
| FluidAudio | Swift package, fetched at build time | Apache License 2.0 |
| Sparkle | Swift package, fetched at build time | MIT (Sparkle Project) |
| llama.cpp (`llama-server` helper) | built from pinned source by `scripts/build-llama-server.sh` | MIT (the ggml authors) |

The models the app downloads (Parakeet TDT, Gemma 4, Sortformer) are under their own terms,
listed in the app's About pane and in `Packages/SuiteModelStore/Sources/SuiteModelStore/Resources/catalog.json`.
