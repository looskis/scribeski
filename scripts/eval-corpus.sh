#!/bin/sh
# Runs extraction + scoring over the eval corpus against a running llama-server.
# Usage: scripts/eval-corpus.sh <run-name> [--heldout]
#   env: ENDPOINT (default http://127.0.0.1:8089), MODEL (default the catalog LLM id),
#        LLAMA_API_KEY (as given to scripts/llama-serve.sh)
# Writes eval/runs/<run-name>/<session>.{json,md} and prints one line per session.
# --heldout scores ONLY the held-out pair. Don't look at their transcripts while tuning.
set -u
cd "$(dirname "$0")/.."
NAME="$1"; shift
ENDPOINT="${ENDPOINT:-http://127.0.0.1:8089}"
MODEL="${MODEL:-gemma-4-26b-a4b-it-qat-q4_0}"
OUT="eval/runs/$NAME"; mkdir -p "$OUT"
swift build -q --product scribeski || exit 1
B=.build/debug/scribeski
if [ "${1:-}" = "--heldout" ]; then
  PAIRS="heldout/heldout-01.txt:heldout/expected-heldout-01.json heldout/heldout-02.txt:heldout/expected-heldout-02.json"
else
  PAIRS=""
  for t in fixtures/corpus/session-*.txt; do
    id="$(basename "$t" .txt | sed 's/^session-//')"
    PAIRS="$PAIRS $(basename "$t"):expected-$id.json"
  done
  PAIRS="$PAIRS ../sample-session.txt:../expected-extraction.json"
fi
for pair in $PAIRS; do
  t="fixtures/corpus/${pair%%:*}"; e="fixtures/corpus/${pair#*:}"
  name="$(basename "$t" .txt)"
  start=$(date +%s)
  $B extract --transcript "$t" --profile page/test/golden/mock-ehr.profile.json \
    --mapping fixtures/mock-ehr/mapping.json --endpoint "$ENDPOINT" --model "$MODEL" \
    --api-key-env LLAMA_API_KEY --cold-cache --out "$OUT/$name.json" >/dev/null 2>"$OUT/$name.log" \
    || { echo "$name: EXTRACT FAILED (see $OUT/$name.log)"; continue; }
  secs=$(( $(date +%s) - start ))
  $B score --results "$OUT/$name.json" --expected "$e" --out "$OUT/$name.md" 2>/dev/null
  gates=$(sed -n '/## Gates/,/^## Blank/p' "$OUT/$name.md" | grep -E '^\| [a-z]' | grep -v "^| gate" \
    | awk -F'|' '{gsub(/ /,"",$3); gsub(/^ +| +$/,"",$4); printf "%s=%s(%s) ", substr($2,2,10), $3, $4}')
  echo "$name ${secs}s $gates"
done
