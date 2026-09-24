#!/bin/sh
# Dev launcher for llama-server with the flags DESIGN §4 / BUILD_PLAN P3.2 depend on.
# Usage: scripts/llama-serve.sh [model.gguf]   (default: the llm the shared store resolves to)
#
#   --swa-full, -ctk/-ctv q8_0   Gemma 4 interleaves sliding-window layers; without a full SWA
#                                cache the prefix cache silently misses (P1.6 asserts it).
#   -c 32768 -np 1               one slot, 32k: a real 60–75 min session (≈18–26k tokens); KV ≈ 3.8 GB.
#   -rea off                     no thinking tokens; they fight the JSON-schema grammar.
#   --no-webui --no-slots        /slots can expose cached prompts (the transcript) locally.
#   127.0.0.1 + random API key   the app will use a unix socket (P3.2); dev uses loopback.
set -eu
cd "$(dirname "$0")/.."
MODEL="${1:-}"
if [ -z "$MODEL" ]; then
  swift build -q --product scribeski
  DIR="$(.build/debug/scribeski models where | head -1)"
  MODEL="$(find "$DIR/snapshots" -path '*gemma-4-26b-a4b*' -name '*.gguf' 2>/dev/null | head -1)"
  [ -n "$MODEL" ] || { echo "default LLM not downloaded: run .build/debug/scribeski models pull" >&2; exit 1; }
fi
PORT="${PORT:-8089}"
KEY="${LLAMA_API_KEY:-$(openssl rand -hex 16)}"
echo "llama-server on http://127.0.0.1:$PORT  (export LLAMA_API_KEY=$KEY)" >&2
exec llama-server -m "$MODEL" --host 127.0.0.1 --port "$PORT" --api-key "$KEY" \
  -c "${CTX:-32768}" -np "${NP:-1}" ${KVU:+--kv-unified} --swa-full -ctk q8_0 -ctv q8_0 -fa on -rea off \
  ${SPEC:+--spec-type $SPEC} ${SPEC_ARGS:-} --no-webui --no-slots --jinja
