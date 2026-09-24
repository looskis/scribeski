#!/bin/bash
# Regenerates Sources/SuiteModelStore/Resources/catalog.json from the Hugging Face API.
#
# Metadata only: for LFS files (all weights) the sha256 and size come straight from the
# HF tree API (`lfs.oid` is the sha256 of the content). Small non-LFS files (JSON configs,
# CoreML model.mil text, tokenizer vocab) have no sha256 in the API, so the script fetches
# those few files (a few MB total) and hashes them locally. Weights are never downloaded.
#
# Every file is pinned to a commit sha: url = https://huggingface.co/<repo>/resolve/<sha>/<path>.
#
# Usage:
#   scripts/pin-catalog.sh              # resolve each entry's `ref` (default "main") to a commit sha
#   scripts/pin-catalog.sh --check      # regenerate to a temp file and diff against the committed catalog
#   HF_TOKEN=... scripts/pin-catalog.sh # if a repo ever becomes gated
#
# To re-pin a model to a newer upstream commit, run the script and review the diff: sizes and
# hashes will change, and the entry's `validated` flag MUST go back to false until the owning
# app's eval gates pass on the new revision. To freeze an entry at a specific commit, set its
# `ref` below to that sha.
set -eu
cd "$(dirname "$0")/.."
OUT=Sources/SuiteModelStore/Resources/catalog.json
MODE="${1:-write}"

TMP=$(mktemp -t catalog.XXXXXX)
trap 'rm -f "$TMP"' EXIT

/usr/bin/python3 - "$TMP" <<'PY'
import hashlib, json, os, sys, time, urllib.request, fnmatch

OUT = sys.argv[1]
TOKEN = os.environ.get("HF_TOKEN")

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "SuiteModelStore-pin/1"})
    if TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)

def api(path):
    return json.loads(get("https://huggingface.co/api/models/" + path))

# ---------------------------------------------------------------------------------------------
# Catalog definition. `include` are fnmatch patterns over repo paths; `exclude` wins over include.
# ---------------------------------------------------------------------------------------------
ENTRIES = [
    dict(
        id="gemma-4-26b-a4b-it-qat-q4_0",
        display_name="Gemma 4 26B A4B Instruct (QAT Q4_0, GGUF)",
        role="llm", format="gguf",
        repo="google/gemma-4-26B-A4B-it-qat-q4_0-gguf", ref="main",
        include=["gemma-4-26B_q4_0-it.gguf"],
        exclude=["*mmproj*"],
        license="Apache-2.0",
        license_url="https://ai.google.dev/gemma/docs/gemma_4_license",
        min_ram_gb=32,
        notes="Official Google QAT Q4_0 GGUF. Text-only: the vision projector "
              "(gemma-4-26B-it-mmproj.gguf) is deliberately excluded. MoE, ~4B active params. "
              "Gemma 4 uses hybrid sliding-window attention: run llama-server with --swa-full "
              "or prefix caching is silently lost (DESIGN.md section 4).",
        validated=False,
    ),
    dict(
        id="gemma-4-31b-it-qat-q4_0",
        display_name="Gemma 4 31B Instruct (QAT Q4_0, GGUF)",
        role="llm", format="gguf",
        repo="google/gemma-4-31B-it-qat-q4_0-gguf", ref="main",
        include=["gemma-4-31B_q4_0-it.gguf"],
        exclude=["*mmproj*"],
        license="Apache-2.0",
        license_url="https://ai.google.dev/gemma/docs/gemma_4_license",
        min_ram_gb=32,
        notes="Official Google QAT Q4_0 GGUF (dense 31B). Weights are ~17.7 GB, under the "
              "~20 GB line where 48 GB would be required; 32 GB leaves room for KV cache "
              "(--swa-full) and the ASR model but is tight. Vision projector excluded.",
        validated=False,
    ),
    dict(
        id="parakeet-tdt-0.6b-v3-coreml",
        display_name="Parakeet TDT 0.6B v3 (CoreML, FluidAudio)",
        role="asr", format="coreml",
        repo="FluidInference/parakeet-tdt-0.6b-v3-coreml", ref="main",
        include=["Preprocessor.mlmodelc/*", "Encoder.mlmodelc/*", "Decoder.mlmodelc/*",
                 "JointDecisionv3.mlmodelc/*", "parakeet_vocab.json", "config.json"],
        exclude=[],
        license="CC-BY-4.0",
        license_url="https://creativecommons.org/licenses/by/4.0/",
        min_ram_gb=8,
        notes="CC-BY-4.0: ATTRIBUTION REQUIRED in the app's About/licenses screen "
              "(NVIDIA parakeet-tdt-0.6b-v3, CoreML conversion by FluidInference). File set is "
              "what FluidAudio's AsrModels loads for v3 at the default int8 encoder precision "
              "(ModelNames.ASR.requiredModelsV3: Preprocessor, Encoder, Decoder, JointDecisionv3 "
              "+ parakeet_vocab.json). Snapshot dir is loadable as a FluidAudio repo directory.",
        validated=False,
    ),
    dict(
        id="qwen3-asr-1.7b-mlx-8bit",
        display_name="Qwen3-ASR 1.7B (MLX, 8-bit)",
        role="asr", format="mlx",
        repo="aufklarer/Qwen3-ASR-1.7B-MLX-8bit", ref="main",
        include=["*"],
        exclude=[".gitattributes", "README.md"],
        license="Apache-2.0",
        license_url="https://huggingface.co/Qwen/Qwen3-ASR-1.7B",
        min_ram_gb=16,
        notes="Community MLX conversion of Qwen/Qwen3-ASR-1.7B (Apache-2.0) by 'aufklarer', "
              "the repo soniqo/speech-swift uses as its large ASR default "
              "(Qwen3ASR.largeModelId). speech-swift docs also list a 5-bit build "
              "(aufklarer/Qwen3-ASR-1.7B-MLX-5bit) that scored lower WER on a small slice; "
              "8-bit is pinned because it is the library's code default. Not an official Qwen repo.",
        validated=False,
    ),
    dict(
        id="sortformer-4spk-v2.1-coreml",
        display_name="Streaming Sortformer 4-speaker v2.1 (CoreML, FluidAudio)",
        role="diarizer", format="coreml",
        repo="FluidInference/diar-streaming-sortformer-coreml", ref="main",
        include=["v3/fp16/Sortformer_v2.1.mlmodelc/*"],
        exclude=[],
        license="NVIDIA Open Model License (upstream); repo card says CC-BY-4.0",
        license_url="https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/",
        min_ram_gb=8,
        notes="LICENSE UNCONFIRMED: the FluidInference card declares cc-by-4.0, but the base "
              "model nvidia/diar_streaming_sortformer_4spk-v2.1 is under the NVIDIA Open Model "
              "License, which governs derivatives. Treat as NVIDIA Open Model License (commercial "
              "use permitted, attribution + notice required) until legal confirms. File set is "
              "FluidAudio's default streaming variant (Sortformer.Variant.fastV2_1, fp16, v3 "
              "BNNS-fixed rebuild). Used only to flag a second voice on the client track.",
        validated=False,
    ),
]
DEFAULTS = {"llm": "gemma-4-26b-a4b-it-qat-q4_0",
            "asr": "parakeet-tdt-0.6b-v3-coreml",
            "diarizer": "sortformer-4spk-v2.1-coreml"}

def matches(path, pats):
    return any(fnmatch.fnmatchcase(path, p) for p in pats)

models = []
for e in ENTRIES:
    repo, ref = e["repo"], e["ref"]
    sha = api(f"{repo}/revision/{ref}")["sha"]
    tree = api(f"{repo}/tree/{sha}?recursive=true")
    files = []
    for f in tree:
        if f["type"] != "file":
            continue
        p = f["path"]
        if not matches(p, e["include"]) or matches(p, e["exclude"]):
            continue
        url = f"https://huggingface.co/{repo}/resolve/{sha}/{p}"
        lfs = f.get("lfs")
        if lfs:
            digest, size = lfs["oid"], lfs["size"]
        else:
            if f["size"] > 16 * 1024 * 1024:
                sys.exit(f"refusing to fetch large non-LFS file {repo}/{p}")
            body = get(url)
            if len(body) != f["size"]:
                sys.exit(f"size mismatch for {repo}/{p}: {len(body)} != {f['size']}")
            digest, size = hashlib.sha256(body).hexdigest(), len(body)
        files.append({"path": p, "url": url, "sha256": digest, "size": size})
    if not files:
        sys.exit(f"no files matched for {e['id']} in {repo}@{sha}")
    files.sort(key=lambda x: x["path"])
    models.append({
        "id": e["id"], "display_name": e["display_name"], "role": e["role"],
        "format": e["format"], "source": repo, "revision": sha,
        "license": e["license"], "license_url": e["license_url"],
        "min_ram_gb": e["min_ram_gb"], "files": files, "notes": e["notes"],
        "validated": e["validated"],
    })
    total = sum(x["size"] for x in files)
    print(f"{e['id']}: {repo}@{sha[:12]} {len(files)} files {total/1e9:.2f} GB", file=sys.stderr)

catalog = {"schema_version": 1,
           "pinned_at": time.strftime("%Y-%m-%d", time.gmtime()),
           "defaults": DEFAULTS, "models": models}
with open(OUT, "w") as fh:
    json.dump(catalog, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY

if [ "$MODE" = "--check" ]; then
  # Ignore the pinned_at date when comparing.
  if diff <(grep -v '"pinned_at"' "$OUT") <(grep -v '"pinned_at"' "$TMP") >/dev/null 2>&1; then
    echo "catalog.json is up to date"
  else
    echo "catalog.json differs from upstream:"; diff <(grep -v '"pinned_at"' "$OUT") <(grep -v '"pinned_at"' "$TMP") || true
    exit 1
  fi
else
  mkdir -p "$(dirname "$OUT")"
  cp "$TMP" "$OUT"
  echo "wrote $OUT"
fi
