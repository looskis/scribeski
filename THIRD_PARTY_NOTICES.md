# Third-party notices

Scribeski's own code is under the MIT License (see `LICENSE`). These keep their own licenses:

| Component | Where | License |
|---|---|---|
| SpeexDSP (echo canceller) | vendored in `Sources/CSpeexEcho` | BSD 3-Clause, see `Sources/CSpeexEcho/COPYING` |
| FluidAudio | Swift package, fetched at build time | Apache License 2.0 |
| Sparkle | Swift package, fetched at build time | MIT (Sparkle Project) |
| llama.cpp (`llama-server` helper) | built from pinned source by `scripts/build-llama-server.sh` | MIT (the ggml authors) |
| Lucide `audio-lines` icon (app icon artwork, recolored) | `App/Scribeski/Assets.xcassets/AppIcon.appiconset` | ISC, see "Lucide" below |

The models the app downloads (Parakeet TDT, Gemma 4, Sortformer) are under their own terms,
listed in the app's About pane and in `Packages/SuiteModelStore/Sources/SuiteModelStore/Resources/catalog.json`.

## Lucide

```
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```
