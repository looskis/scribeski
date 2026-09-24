# tools/distill — P1.9 classifier-tier experiment

Result and decision: `eval/classifier-2026-09-23.md` (rejected). Gates: `CRITERIA.md`, written
before anything was scored.

| file | what |
|---|---|
| `common.py` | field scope (63 choice fields), transcript/synthetic loaders, hash-stable val split, scorer mirroring `Scorer.swift` |
| `bge_baseline.py` | frozen bge-m3 window retrieval + shared option-scoring heads (Mac) |
| `lm.py` | one-pass classifier: transcript + all 98 questions, answers read from letter logits at each `Answer:`; `train` / `predict` |
| `evaluate.py` | temperature + abstention threshold fit on val, then corpus / held-out scoring |
| `mlx_score.py` | converts a checkpoint to MLX (4/8-bit), scores and times it on this Mac |
| `gpu.py`, `remote.sh` | Lambda launch/terminate (state in `out/gpu/state.json`), sync/run/fetch |

```bash
uv venv tools/distill/.venv --python 3.12 && source tools/distill/.venv/bin/activate
uv pip install torch transformers sentence-transformers scikit-learn accelerate mlx mlx-lm
S="../../data/synth/pilot ../../data/synth/pilot2 ../../data/synth/batch-1 ../../data/synth/batch-2"
python bge_baseline.py --synth $S --epochs 60 --lr 1e-3 --test
python gpu.py launch --want gpu_1x_h100_pcie,gpu_1x_h100_sxm5 && ./remote.sh sync
./remote.sh run "cd tools/distill && python lm.py train --model Qwen/Qwen3-1.7B --synth $S --out out/q17 --epochs 6"
python gpu.py terminate          # billing runs until this
python mlx_score.py --hf out/q17/epoch3 --bits 8 --synth $S --heldout
python evaluate.py out/q17/pred-epoch3-mlx8.json --synth $S --heldout
```

`fields.json` is exported from `tools/synth/fields.mjs`; regenerate it if the field spec changes.
The corpus and held-out pair have now scored this model family. Use a fresh held-out set for
the next round.
