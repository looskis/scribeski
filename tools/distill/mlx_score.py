"""Score a fine-tuned checkpoint on this Mac with MLX: the deployable (quantized) model, timed.

Same prompt and letter-logit readout as lm.py; writes the same predictions.json schema, so
evaluate.py scores it unchanged.

    python mlx_score.py --hf out/q17-r1/epoch3 --bits 4 --synth ../../data/synth/* [--heldout]
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import mlx.core as mx
import numpy as np

from common import eval_sets, load_synth, split
from lm import QS, build, letter_ids, to_prediction


def convert(hf: Path, bits: int) -> Path:
    from mlx_lm import convert as mlx_convert

    out = hf.parent / f"{hf.name}-mlx{bits}"
    cfg_path = hf / "config.json"
    cfg = json.loads(cfg_path.read_text())
    if "rope_theta" not in cfg and "rope_parameters" in cfg:  # transformers 5 layout → what mlx-lm reads
        cfg["rope_theta"] = cfg["rope_parameters"]["rope_theta"]
        cfg_path.write_text(json.dumps(cfg, indent=2))
    if not out.exists():
        mlx_convert(str(hf), str(out), quantize=bits < 16, q_bits=bits, q_group_size=64, dtype="bfloat16")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hf", required=True)
    ap.add_argument("--bits", type=int, default=4)
    ap.add_argument("--synth", nargs="*", default=[])
    ap.add_argument("--heldout", action="store_true")
    ap.add_argument("--max-len", type=int, default=32768)
    ap.add_argument("--dir", nargs="*", default=[], help="also score every <dir>/*/transcript.txt as gold/<name>")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    from mlx_lm import load
    from transformers import AutoTokenizer

    hf = Path(args.hf)
    path = convert(hf, args.bits)
    t0 = time.time()
    model, _ = load(str(path))
    tok = AutoTokenizer.from_pretrained(str(hf))
    load_s = time.time() - t0
    lid = letter_ids(tok)
    all_letters = sorted(set("".join(q.letters for q in QS)))
    rows = mx.array([lid[L] for L in all_letters])
    col = {L: i for i, L in enumerate(all_letters)}
    import torch

    res = {}

    def run(name, lines):
        t0 = time.time()
        ids, pos = build(lines, QS, tok, args.max_len)
        h = model.model(mx.array([ids]))[0]            # (T, d), final-normed hidden states
        W = model.model.embed_tokens(rows)              # tied LM head rows for the letters (dequantized)
        logits = (h[mx.array(pos)] @ W.T).astype(mx.float32)
        mx.eval(logits)
        secs = time.time() - t0
        L = np.array(logits)
        lps = []
        for i, q in enumerate(QS):
            z = torch.tensor([L[i, col[c]] for c in q.letters])
            lps.append(torch.log_softmax(z, -1))
        res[name] = {"probs": to_prediction(lps, QS), "tokens": len(ids), "seconds": secs}
        print(f"{name}: {len(ids)} tokens, {secs:.2f}s", flush=True)

    run("warmup", eval_sets(False)[0][0].lines)
    del res["warmup"]
    if args.dir and not args.synth:  # pre-fill mode: only the extra transcripts
        pass
    if args.synth:
        _, va = split(load_synth([Path(d) for d in args.synth]))
        for s in va:
            run("val/" + s.id, s.transcript.lines)
    for tr, _ in eval_sets(False):
        run("corpus/" + tr.id, tr.lines)
    if args.heldout:
        for tr, _ in eval_sets(True):
            run("heldout/" + tr.id, tr.lines)
    from common import read_transcript
    for d in args.dir:
        tag = Path(d).name  # e.g. annomi (round-2 dev gold) or annomi_r3 (round-3 test)
        for p in sorted(Path(d).glob("*/transcript.txt")):
            run(f"{tag}/" + p.parent.name, read_transcript(p).lines)
    out = Path(args.out) if args.out else hf.parent / f"pred-{hf.name}-mlx{args.bits}.json"
    out.write_text(json.dumps(res))
    secs = [v["seconds"] for k, v in res.items() if k.startswith("corpus/")]
    print(f"model load {load_s:.1f}s; corpus forward mean {np.mean(secs):.2f}s, max {np.max(secs):.2f}s → {out}")


if __name__ == "__main__":
    main()
