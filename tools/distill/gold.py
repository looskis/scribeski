"""Score predictions against the human-reviewed gold set (review page db export).

    python gold.py --reviews out/gold/reviews --pred out/q17-r3/pred-epoch2-mlx8.json [--pred2 ...]

Gold for a session: every field the reviewer answered (listed or added) takes that answer;
every other field is "not established". Outcomes per field: ok, unsafe (a wrong value, or any
value where gold is blank), blank (left empty where gold has a value; a multi-select that
misses options but adds nothing wrong also counts as blank).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import CHECKBOX, SCOPE
from evaluate import decide, temper

RISK = {"si_ideation", "si_frequency", "si_plan", "si_intent", "si_means", "si_prior_attempts", "hi_ideation", "hi_plan", "safety_plan"}


def load_gold(reviews_dir: Path) -> dict[str, dict]:
    gold = {}
    for p in sorted(reviews_dir.rglob("*.json")):
        body = json.loads(p.read_text())
        body = body.get("data", body)
        if not body.get("item") or not body.get("done"):
            continue
        g = {f: [] for f in SCOPE}
        for f, dec in (body.get("fields") or {}).items():
            if f in g:
                g[f] = list(dec.get("value") or [])
        gold[body["item"]] = g
    return gold


def outcome(f, pred, want):
    got = [] if pred in (None, []) else (pred if isinstance(pred, list) else [str(pred)])
    if f in CHECKBOX:
        if set(got) - set(want):
            return "unsafe"
        return "ok" if set(got) == set(want) else "blank"
    if not got:
        return "ok" if not want else "blank"
    return "ok" if want and got == want else "unsafe"


def score(pred_path: Path, gold: dict, T: float, thresh: float, key=lambda i: f"gold/{i}"):
    res = json.loads(pred_path.read_text())
    tot = {"ok": 0, "unsafe": 0, "blank": 0}
    est = [0, 0]
    risk_unsafe, unsafe_list, secs = 0, [], []
    for item, g in gold.items():
        r = res.get(key(item))
        if r is None:
            continue
        secs.append(r.get("seconds", 0))
        pred = decide(temper(r["probs"], T), thresh)
        for f in SCOPE:
            o = outcome(f, pred.get(f), g[f])
            tot[o] += 1
            if g[f]:
                est[1] += 1
                est[0] += o == "ok"
            if o == "unsafe":
                risk_unsafe += f in RISK
                unsafe_list.append(f"{item} · {f}: gold {g[f] or 'blank'} got {pred.get(f)}")
    n = sum(tot.values())
    return {"sessions": len(secs), "answers": n, "accuracy": tot["ok"] / max(1, n), "unsafe": tot["unsafe"], "unsafe_rate": tot["unsafe"] / max(1, n),
            "risk_unsafe": risk_unsafe, "established_ok": est[0], "established": est[1], "established_acc": est[0] / max(1, est[1]),
            "mean_seconds": sum(secs) / max(1, len(secs)), "unsafe_list": unsafe_list}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--reviews", required=True)
    ap.add_argument("--pred", nargs="+", required=True)
    ap.add_argument("--T", type=float, default=1.0)
    ap.add_argument("--thresh", type=float, default=0.95)
    a = ap.parse_args()
    gold = load_gold(Path(a.reviews))
    print(f"{len(gold)} reviewed sessions")
    for p in a.pred:
        s = score(Path(p), gold, a.T, a.thresh)
        print(f"{p}: {s['sessions']} sessions, accuracy {s['accuracy']:.1%}, unsafe {s['unsafe']} ({s['unsafe_rate']:.2%}), risk unsafe {s['risk_unsafe']}, "
              f"established {s['established_ok']}/{s['established']} ({s['established_acc']:.0%}), {s['mean_seconds']:.1f}s/session")
