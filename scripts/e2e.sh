#!/bin/sh
# End-to-end capture → transcript check, and the zero-recording proof (BUILD_PLAN P2.7).
#
#   scripts/e2e.sh [--minutes 2] [--engine parakeet|speechanalyzer] [--retain]
#
# Renders a synthetic two-voice session, plays the client side with afplay (tapped, muted so
# the room stays quiet) next to a distractor app that must NOT be heard, injects the worker
# side from file, and transcribes live with the Debug app. Then asserts:
#   - WER per track under the gate, no transcriber errors, no gaps;
#   - the distractor never reached the client track (capture isolation);
#   - zero recording: the app wrote kilobytes, not audio (proc_pid_rusage), and no file over
#     64 KB appeared in the data folder, temp folder, or caches during the run;
#   - with --retain: the encrypted audio copy covers every transcript segment and decrypts.
#
# Needs: Xcode, the Parakeet model (or --engine speechanalyzer), and the Debug app allowed to
# capture audio once (System Settings → Privacy & Security → Screen & System Audio
# Recording). On a CI runner that permission has to come from an MDM profile.
set -eu
cd "$(dirname "$0")/.."

MINUTES=2
ENGINE=parakeet
RETAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --retain) RETAIN=--retain; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
WER_GATE="${WER_GATE:-0.10}"
OUT=.build/e2e
SYNTH="$OUT/synth-$MINUTES"
APP=.build/xcode/Build/Products/Debug/Scribeski.app
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$OUT"

echo "== synthetic session ($MINUTES min)"
[ -f "$SYNTH/reference.json" ] || swift scripts/synth-audio.swift fixtures/sample-session.txt "$SYNTH" --minutes "$MINUTES"

echo "== build (Debug)"
xcodebuild -project App/Scribeski.xcodeproj -scheme Scribeski -configuration Debug -derivedDataPath .build/xcode \
  build >"$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | head; exit 1; }

MARK="$OUT/.started"
touch "$MARK"
sleep 1
SECONDS_TOTAL=$(python3 -c "import json;r=json.load(open('$SYNTH/reference.json'));print(int(max(l['end'] for l in r))+4)")
REPORT="$(pwd)/$OUT/report.json"
rm -f "$REPORT" "$REPORT.vault.json"
echo "== live transcription ($SECONDS_TOTAL s, $ENGINE${RETAIN:+, retained})"
ENGINE_ARGS=""
[ "$ENGINE" = parakeet ] && ENGINE_ARGS="--engine parakeet"
# shellcheck disable=SC2086
open -W -n "$APP" --args --transcribe-probe - "$SECONDS_TOTAL" "$REPORT" $ENGINE_ARGS \
  --client-file "$(pwd)/$SYNTH/client.wav" --worker-file "$(pwd)/$SYNTH/worker.wav" \
  --distractor-file "$(pwd)/$SYNTH/distractor.wav" --reference "$(pwd)/$SYNTH/reference.json" --silent $RETAIN
[ -f "$REPORT" ] || { echo "no report: did the app get audio capture permission?" >&2; exit 1; }

echo "== files written during the run"
BIG=$( { for d in "$HOME/Library/Application Support/Scribeski" "$(getconf DARWIN_USER_TEMP_DIR)" \
               "$HOME/Library/Caches/com.looski.scribeski"; do
           [ -d "$d" ] && find "$d" -type f -newer "$MARK" -size +64k 2>/dev/null
         done; } | grep -v -e "/e2e/" -e "scribeski-retain-" || true)

python3 - "$REPORT" "$WER_GATE" "$RETAIN" "$BIG" <<'PY'
import json, sys
report_path, gate, retain, big = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
r = json.load(open(report_path))
failures = []
def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok: failures.append(what)
if "error" in r:
    print("  FAIL  probe error:", r["error"]); sys.exit(1)
t = r["transcript"]
for track, w in (r.get("wer") or {}).items():
    check(w <= gate, f"{track} WER {w:.1%} (gate {gate:.0%})")
check(not r["transcriberErrors"], f"transcriber errors: {len(r['transcriberErrors'])}")
check(not t.get("gaps"), f"gaps: {len(t.get('gaps') or [])}")
leaked = [s["text"] for s in t["segments"] if "distractor" in s["text"].lower()]
check(not leaked, "distractor absent from the transcript" + (f" (heard: {leaked[0]!r})" if leaked else ""))
written = r["diskBytesWritten"]
limit = 50_000_000 if retain else 1_000_000
check(written < limit, f"bytes written during capture: {written:,} (limit {limit:,}{', audio copy on' if retain else ''})")
check(not big.strip(), "no file over 64 KB appeared in data, temp, or caches" + (f":\n{big}" if big.strip() else ""))
if retain:
    v = json.load(open(report_path + ".vault.json"))
    check(v["segments"] > 0 and v["segments_with_audio"] == v["segments"],
          f"audio copy covers {v['segments_with_audio']}/{v['segments']} segments")
print(f"  engine {r['engine']}, {len(t['segments'])} segments, stop→transcript {r['stopToTranscript']:.1f} s")
sys.exit(1 if failures else 0)
PY
