#!/usr/bin/env bash
# Remote plumbing for the Lambda box in out/gpu/state.json.
#   remote.sh sync            code + synthetic data (transcripts/truth only) + eval fixtures
#   remote.sh run '<cmd>'     run a command in ~/scribeski with the venv active
#   remote.sh get <remote> <local>
set -euo pipefail
CALLER=$PWD
cd "$(dirname "$0")/../.."
STATE=tools/distill/out/gpu/state.json
IP=$(python3 -c "import json;print(json.load(open('$STATE'))['ip'])")
KEY=tools/distill/out/gpu/ssh/id_ed25519
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)

case "$1" in
  sync)
    rsync -az -e "${SSH[*]}" --relative tools/distill/common.py tools/distill/lm.py tools/distill/evaluate.py \
      tools/distill/fields.json fixtures/sample-session.txt fixtures/expected-extraction.json fixtures/corpus \
      "ubuntu@$IP:scribeski/"
    # Training data only: synthetic behavioral-health sessions. Never data/eval_only (AnnoMI stays
    # on this Mac) and never data/clinic (reserved for doctor intake).
    for d in synth; do
      "${SSH[@]}" "ubuntu@$IP" "mkdir -p scribeski/data/$d"
      rsync -az -e "${SSH[*]}" --include='*/' --include='transcript.txt' --include='truth.json' --exclude='*' \
        "data/$d/" "ubuntu@$IP:scribeski/data/$d/"
    done
    rsync -az -e "${SSH[*]}" tools/distill/gold_ids.json "ubuntu@$IP:scribeski/tools/distill/"
    ;;
  run)
    "${SSH[@]}" "ubuntu@$IP" "cd scribeski && source .venv/bin/activate 2>/dev/null; $2"
    ;;
  get)
    case "$3" in /*) DEST="$3" ;; *) DEST="$CALLER/$3" ;; esac
    rsync -az -e "${SSH[*]}" "ubuntu@$IP:scribeski/$2" "$DEST"
    ;;
esac
