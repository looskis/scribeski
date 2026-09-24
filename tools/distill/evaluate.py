"""Turn lm.py probabilities into answers and score them.

Temperature and the abstention threshold are fit on the synthetic val split only (same rule as
the bge baseline: the lowest-unsafe threshold that keeps ≥ 95% of the best val accuracy). The
corpus / held-out are then scored once with those settings.

    python evaluate.py out/qwen17b/predictions.json --synth ../../data/synth/* [--heldout]
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from common import (CHECKBOX, EXCLUSIVE, SCOPE, eval_fingerprint, eval_sets, load_synth, report, score, split,
                    summarize, unsafe_list)

GRID = [0.0, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95]


def temper(probs: dict, T: float) -> dict:
    if T == 1.0:
        return probs
    out = {}
    for f, d in probs.items():
        if f in CHECKBOX:
            out[f] = {o: 1 / (1 + math.exp(-(math.log(max(p, 1e-9)) - math.log(max(1 - p, 1e-9))) / T)) for o, p in d.items()}
        else:
            z = {k: math.log(max(p, 1e-12)) / T for k, p in d.items()}
            m = max(z.values())
            s = sum(math.exp(v - m) for v in z.values())
            out[f] = {k: math.exp(v - m) / s for k, v in z.items()}
    return out


def decide(probs: dict, thresh: float) -> dict:
    pred = {}
    for f in SCOPE:
        d = probs.get(f)
        if d is None:
            pred[f] = None
        elif f in CHECKBOX:
            chosen = [o for o, p in d.items() if p >= max(0.5, thresh)]
            if len(chosen) > 1:
                chosen = [o for o in chosen if o not in EXCLUSIVE]
            pred[f] = sorted(chosen) or None
        else:
            v, p = max(d.items(), key=lambda kv: kv[1])
            pred[f] = None if v == "" or p < thresh else v
    return pred


def label_match(v, lab, acceptable=None):
    if lab == []:
        lab = None
    accept = acceptable if acceptable is not None else [lab]
    for a in accept:
        if a in ([], None) and v in (None, []):
            return True
        if isinstance(v, list) and isinstance(a, list) and sorted(v) == sorted(a):
            return True
        if v is not None and not isinstance(v, list) and a is not None and str(a) == str(v):
            return True
    return False


def val_eval(res, val, thresh, T, acc_map):
    ok = unsafe = blank = 0
    by_mode = {}
    for s in val:
        key = "val/" + s.id
        if key not in res:
            continue
        pred = decide(temper(res[key]["probs"], T), thresh)
        for f, lab in s.labels.items():
            v = pred.get(f)
            good = label_match(v, lab, acc_map.get((s.id, f)))
            if good:
                ok += 1
            elif v in (None, []):
                blank += 1
            else:
                unsafe += 1
            m = s.modes.get(f, "?")
            a, n = by_mode.get(m, (0, 0))
            by_mode[m] = (a + good, n + 1)
    n = max(1, ok + unsafe + blank)
    return ok / n, unsafe / n, blank / n, by_mode


def nll(res, val, T, acc_map):
    """Mean NLL of the acceptable answers, select fields only (for temperature fitting)."""
    tot, n = 0.0, 0
    for s in val:
        key = "val/" + s.id
        if key not in res:
            continue
        probs = temper(res[key]["probs"], T)
        for f, lab in s.labels.items():
            if f in CHECKBOX or f not in probs:
                continue
            accept = acc_map.get((s.id, f)) or [lab]
            p = sum(probs[f].get("" if a is None else str(a), 0.0) for a in accept)
            tot -= math.log(max(p, 1e-9))
            n += 1
    return tot / max(1, n)


def invariance(res, val, T, thresh):
    """Share of fields where every version (original + restyled variants) of the same
    conversation gets the same answer. The classifier should not care how people talk."""
    groups = {}
    for s in val:
        if "val/" + s.id in res:
            groups.setdefault(s.group or s.id, []).append(decide(temper(res["val/" + s.id]["probs"], T), thresh))
    same = total = n = 0
    for preds in groups.values():
        if len(preds) < 2:
            continue
        n += 1
        for f in SCOPE:
            vals = {json.dumps(p.get(f), sort_keys=True) for p in preds}
            same += len(vals) == 1
            total += 1
    return (same / total, n) if total else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pred")
    ap.add_argument("--synth", nargs="+", required=True)
    ap.add_argument("--heldout", action="store_true")
    ap.add_argument("--name", default=None)
    args = ap.parse_args()
    from lm import acceptable_map

    res = json.loads(Path(args.pred).read_text())
    _, val = split(load_synth([Path(d) for d in args.synth]))
    acc_map = acceptable_map(args.synth)

    T = min([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], key=lambda t: nll(res, val, t, acc_map))
    grid = []
    for th in GRID:
        acc, uns, bl, _ = val_eval(res, val, th, T, acc_map)
        grid.append((th, acc, uns, bl))
        print(f"  thresh {th:.2f}: val acc {acc:.3f} unsafe {uns:.3f} blank {bl:.3f}")
    top = max(g[1] for g in grid)
    thresh = min((g for g in grid if g[1] >= 0.95 * top), key=lambda g: g[2])[0]
    acc, uns, bl, by_mode = val_eval(res, val, thresh, T, acc_map)
    print(f"T={T} threshold={thresh}: val acc {acc:.3f} unsafe {uns:.3f} blank {bl:.3f}")
    print("val by mode:", {m: f"{a}/{n}" for m, (a, n) in sorted(by_mode.items())})

    inv = invariance(res, val, T, thresh)
    if inv:
        print(f"style invariance: {inv[0]:.1%} of fields answered identically across variants ({inv[1]} conversations with ≥2 versions)")

    name = args.name or Path(args.pred).parent.name
    out_md = [f"## {name}", f"T={T}, threshold={thresh} (fit on synthetic val: acc {acc:.3f}, unsafe {uns:.3f}, blank {bl:.3f})",
              "val by mode: " + ", ".join(f"{m} {a}/{n}" for m, (a, n) in sorted(by_mode.items())), ""]
    for held in [False] + ([True] if args.heldout else []):
        per, secs, toks = {}, [], []
        prefix = "heldout/" if held else "corpus/"
        for tr, exp in eval_sets(held):
            r = res.get(prefix + tr.id)
            if r is None:
                continue
            per[tr.id] = score(decide(temper(r["probs"], T), thresh), exp)
            secs.append(r["seconds"])
            toks.append(r["tokens"])
        label = "held-out" if held else "corpus"
        md = report(f"{name} — {label}", per)
        print(md)
        print(f"forward pass: mean {sum(secs) / len(secs):.2f}s, {sum(toks) / len(toks):.0f} tokens/session (on the machine that ran predict)")
        print(unsafe_list(per))
        out_md += [md, "", f"forward pass: mean {sum(secs) / len(secs):.2f}s/session ({sum(toks) / len(toks):.0f} tokens)", "", "Unsafe:", unsafe_list(per),
                   "", f"fingerprint: `{json.dumps(eval_fingerprint(held))}`", ""]
    (Path(args.pred).parent / f"report-{Path(args.pred).stem}.md").write_text("\n".join(out_md))


if __name__ == "__main__":
    main()
