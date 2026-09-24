"""Frozen bge-m3 retrieval + small trained heads (the cheap baseline, runs on the Mac).

Per session: embed every 3-line window of the transcript once. Per field: retrieve the top-k
windows for the field's question, pool them with a learned attention, and score each option
(plus BLANK) with a shared MLP over [context⊙option, option, context] and similarity
features. Checkbox options are independent sigmoids. One model for all fields, so ~63 labels
per session all train the same weights.

    python bge_baseline.py --synth ../../data/synth/{pilot,pilot2,batch-1,batch-2} [--test]

Model selection (epochs, threshold) uses the synthetic val split only. --test scores the
corpus once with the chosen settings.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from common import (CHECKBOX, EXCLUSIVE, FIELDS, ITEM_TEXT, ITEMS, ROOT, SCOPE, eval_fingerprint,
                    eval_sets, load_synth, options, report, score, split, summarize, unsafe_list)

OUT = Path(__file__).parent / "out" / "bge"
EMB = OUT / "emb"
ANCHOR = {"0": "not at all, zero days", "1": "several days, a few days out of the last two weeks",
          "2": "more than half the days", "3": "nearly every day"}


def query_text(f):
    if f in ITEMS:
        return f"In the past two weeks, how often has the client been bothered by: {ITEM_TEXT[f]}"
    return f"What does the client say about {FIELDS[f]['topic']}?"


def option_text(f, o):
    if f in ITEMS:
        return f"{ITEM_TEXT[f]}: {ANCHOR[o]}"
    d = FIELDS[f]["desc"].get(o) or o.replace("_", " ").lower()
    return f"{FIELDS[f]['topic']}: the client {d}"


class Embedder:
    def __init__(self):
        from sentence_transformers import SentenceTransformer

        self.m = SentenceTransformer("BAAI/bge-m3", device="mps")
        self.m.max_seq_length = 256

    def enc(self, texts):
        return self.m.encode(texts, batch_size=64, normalize_embeddings=True, convert_to_numpy=True).astype(np.float32)


def windows(lines, w=1):
    return ["\n".join(lines[max(0, i - w): i + w + 1]) for i in range(len(lines))]


def session_emb(emb: Embedder, sid: str, lines: list[str]) -> np.ndarray:
    p = EMB / f"{sid}.npy"
    if p.exists():
        return np.load(p)
    x = emb.enc(windows(lines))
    np.save(p, x)
    return x


class Head(nn.Module):
    def __init__(self, d=1024, h=256, k=16):
        super().__init__()
        self.k = k
        self.att_scale = nn.Parameter(torch.tensor(20.0))
        self.opt = nn.Sequential(nn.Linear(3 * d + 4, h), nn.GELU(), nn.Dropout(0.2), nn.Linear(h, 1))
        self.blank = nn.Sequential(nn.Linear(2 * d + 4, h), nn.GELU(), nn.Dropout(0.2), nn.Linear(h, 1))
        self.bias = nn.ParameterDict({f.replace(".", "_"): nn.Parameter(torch.zeros(len(options(f)) + 1)) for f in SCOPE})

    def forward(self, W, q, O, f):
        """W: (n,d) windows; q: (d,) query; O: (m,d) options. Returns m+1 logits (last = BLANK)."""
        s = W @ q
        k = min(self.k, W.shape[0])
        top, idx = s.topk(k)
        Wk = W[idx]
        a = F.softmax(top * self.att_scale, 0)
        c = a @ Wk  # (d,)
        so = O @ Wk.T  # (m,k)
        so_max = so.max(1).values
        so_top3 = so.topk(min(3, k), dim=1).values.mean(1)
        so_att = so @ a
        feats = torch.stack([so_max, so_top3, so_att, so_max - top[0]], 1)
        cm = c.expand(O.shape[0], -1)
        lo = self.opt(torch.cat([cm * O, O, cm, feats], 1)).squeeze(1)
        bfeat = torch.stack([top[0], top[: min(5, k)].mean(), top.mean(), so_max.max()])
        lb = self.blank(torch.cat([c, q, bfeat])).reshape(1)
        return torch.cat([lo, lb]) + self.bias[f.replace(".", "_")]


def target(f, label):
    opts = options(f)
    if f in CHECKBOX:
        t = torch.zeros(len(opts))
        for v in label or []:
            if v in opts:
                t[opts.index(v)] = 1
        return t
    if label is None:
        return torch.tensor(len(opts))
    return torch.tensor(opts.index(str(label)))


def predict(logits, f, T=1.0, thresh=0.0):
    """Returns (value, confidence). Abstains (None) below thresh."""
    opts = options(f)
    if f in CHECKBOX:
        p = torch.sigmoid(logits[:-1] / T)
        chosen = [o for o, pi in zip(opts, p.tolist()) if pi > 0.5]
        conf = float(torch.where(p > 0.5, p, 1 - p).min())
        if any(o in EXCLUSIVE for o in chosen) and len(chosen) > 1:
            chosen = [o for o in chosen if o not in EXCLUSIVE]
        if conf < thresh and chosen:
            return None, conf
        return (sorted(chosen) or None), conf
    p = F.softmax(logits / T, 0)
    i = int(p.argmax())
    conf = float(p[i])
    if i == len(opts) or conf < thresh:
        return None, conf
    return opts[i], conf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--synth", nargs="+", required=True)
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--test", action="store_true")
    ap.add_argument("--heldout", action="store_true")
    args = ap.parse_args()
    EMB.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(0)

    sessions = load_synth([Path(d) for d in args.synth])
    train, val = split(sessions)
    print(f"{len(sessions)} sessions: {len(train)} train, {len(val)} val")
    emb = Embedder()
    t0 = time.time()
    E = {s.id: torch.from_numpy(session_emb(emb, s.id, s.transcript.lines)) for s in sessions}
    print(f"embedded in {time.time() - t0:.0f}s")
    Q = {f: torch.from_numpy(emb.enc([query_text(f)])[0]) for f in SCOPE}
    O = {f: torch.from_numpy(emb.enc([option_text(f, o) for o in options(f)])) for f in SCOPE}

    def examples(ss):
        return [(s.id, f, lab) for s in ss for f, lab in s.labels.items()]

    tr_ex, va_ex = examples(train), examples(val)
    print(f"{len(tr_ex)} train labels, {len(va_ex)} val labels")
    model = Head()
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-2)

    def loss_of(sid, f, lab):
        lg = model(E[sid], Q[f], O[f], f)
        if f in CHECKBOX:
            return F.binary_cross_entropy_with_logits(lg[:-1], target(f, lab))
        return F.cross_entropy(lg.unsqueeze(0), target(f, lab).unsqueeze(0))

    def val_metrics(T=1.0, thresh=0.0):
        model.eval()
        ok = unsafe = blank = 0
        with torch.no_grad():
            for sid, f, lab in va_ex:
                v, _ = predict(model(E[sid], Q[f], O[f], f), f, T, thresh)
                want = lab if lab not in ([], None) else None
                if v == want or (isinstance(v, list) and want and sorted(v) == sorted(want)):
                    ok += 1
                elif v is None:
                    blank += 1
                else:
                    unsafe += 1
        n = len(va_ex)
        return ok / n, unsafe / n, blank / n

    best, best_state = None, None
    rng = np.random.default_rng(0)
    for ep in range(args.epochs):
        model.train()
        order = rng.permutation(len(tr_ex))
        tot = 0.0
        for j in range(0, len(order), 32):
            opt.zero_grad()
            loss = sum(loss_of(*tr_ex[i]) for i in order[j:j + 32]) / len(order[j:j + 32])
            loss.backward()
            opt.step()
            tot += float(loss.detach()) * len(order[j:j + 32])
        acc, uns, bl = val_metrics()
        print(f"epoch {ep + 1}: train loss {tot / len(tr_ex):.3f}  val acc {acc:.3f} unsafe {uns:.3f} blank {bl:.3f}")
        if best is None or acc > best:
            best, best_state = acc, {k: v.clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state)

    # Threshold on val: the lowest-unsafe point that keeps ≥ 95% of the best accuracy.
    grid = []
    for th in [0.0, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95]:
        acc, uns, bl = val_metrics(1.0, th)
        grid.append((th, acc, uns, bl))
        print(f"  thresh {th:.2f}: val acc {acc:.3f} unsafe {uns:.3f} blank {bl:.3f}")
    top = max(g[1] for g in grid)
    thresh = min((g for g in grid if g[1] >= 0.95 * top), key=lambda g: g[2])[0]
    print(f"chosen threshold {thresh} (val acc {best:.3f} unfiltered)")
    torch.save({"state": model.state_dict(), "thresh": thresh}, OUT / "head.pt")

    # Per-mode val accuracy: which disclosure modes does it get?
    model.eval()
    by_mode = {}
    with torch.no_grad():
        for s in val:
            for f, lab in s.labels.items():
                v, _ = predict(model(E[s.id], Q[f], O[f], f), f, 1.0, thresh)
                want = lab if lab not in ([], None) else None
                good = v == want or (isinstance(v, list) and want and sorted(v) == sorted(want))
                m = s.modes.get(f, "?")
                a, n = by_mode.get(m, (0, 0))
                by_mode[m] = (a + bool(good), n + 1)
    print("val accuracy by mode:", {m: f"{a}/{n}" for m, (a, n) in sorted(by_mode.items())})

    if args.test or args.heldout:
        for held in ([False] if args.test else []) + ([True] if args.heldout else []):
            per, t_all = {}, 0.0
            for tr, exp in eval_sets(held):
                t0 = time.time()
                W = torch.from_numpy(emb.enc(windows(tr.lines)))
                with torch.no_grad():
                    pred = {f: predict(model(W, Q[f], O[f], f), f, 1.0, thresh)[0] for f in SCOPE}
                t_all += time.time() - t0
                per[tr.id] = score(pred, exp)
                (OUT / f"pred-{tr.id}.json").write_text(json.dumps(pred, indent=1))
            name = "held-out" if held else "corpus"
            md = report(f"bge-m3 baseline — {name}", per)
            print(md)
            print(f"wall: {t_all / len(per):.1f} s/session (embedding + heads, MPS)")
            print(unsafe_list(per))
            (OUT / f"report-{name}.md").write_text(md + "\n\nUnsafe:\n" + unsafe_list(per) + f"\n\nfingerprint: {json.dumps(eval_fingerprint(held))}\n")


if __name__ == "__main__":
    main()
