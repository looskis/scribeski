"""Shared pieces for the P1.9 classifier experiment: field specs, transcripts, datasets, scoring.

Scope: the choice fields the classifier tier answers (tools/synth/fields.mjs + PHQ-9/GAD-7
items). Text, narrative, derived and clinician-only fields stay with the reasoning tier.

Scoring mirrors Sources/Extraction/Scorer.swift, restricted to that scope, and splits every
failure the way eval/extraction-2026-09-22.md does:
  unsafe     = a wrong value, or any value where the field must stay blank
  safe blank = left empty where a value was expected (visible; the worker fills it)
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = json.loads((Path(__file__).parent / "fields.json").read_text())
FIELDS: dict = SPEC["FIELDS"]
ITEM_TEXT: dict = SPEC["ITEM_TEXT"]
ITEMS = [f"phq9_{i}" for i in range(1, 10)] + [f"gad7_{i}" for i in range(1, 8)]
# Supplied by the app (the worker picks intake vs follow-up), never asked of the classifier.
APP_SUPPLIED = {"session_type"}
SCOPE = [f for f in FIELDS if f not in APP_SUPPLIED] + ITEMS
CHECKBOX = {k for k, v in FIELDS.items() if v["kind"] == "checkbox"}
EXCLUSIVE = {"NONE", "NONE_REPORTED"}

# Discovered, not listed: the corpus is being revised (session-02-es was removed 2026-09-22).
CORPUS = ["sample-session"] + sorted(
    p.stem for p in (ROOT / "fixtures/corpus").glob("session-*.txt")
    if (ROOT / f"fixtures/corpus/expected-{p.stem[len('session-'):]}.json").exists()
)
HELDOUT = sorted(p.stem for p in (ROOT / "fixtures/corpus/heldout").glob("heldout-*.txt"))


def eval_fingerprint(heldout=False) -> dict:
    """sha256 prefix of every transcript + expected file scored, for the report."""
    import hashlib

    out = {}
    for tr, exp in eval_sets(heldout):
        out[tr.id] = hashlib.sha256((tr.text + json.dumps(exp, sort_keys=True)).encode()).hexdigest()[:12]
    return out


def options(field: str) -> list[str]:
    if field in ITEMS:
        return ["0", "1", "2", "3"]
    return FIELDS[field]["options"]


# ---------------------------------------------------------------------------------------------
# Transcripts

LINE = re.compile(r"^\[(\d+):(\d+)\]\s*([A-Z_ ]+?):\s*(.*)$")


@dataclass
class Transcript:
    id: str
    header: dict
    lines: list[str]  # "SPEAKER: text", timestamps stripped

    @property
    def text(self) -> str:
        return "\n".join(self.lines)


def read_transcript(path: Path, id: str | None = None) -> Transcript:
    header, lines = {}, []
    for raw in path.read_text().splitlines():
        if raw.startswith("#"):
            m = re.match(r"#\s*([a-z_]+):\s*(.*)", raw)
            if m:
                header[m.group(1)] = m.group(2)
            continue
        m = LINE.match(raw.strip())
        if m:
            lines.append(f"{m.group(3).strip()}: {m.group(4).strip()}")
        elif raw.strip():
            lines.append(raw.strip())
    return Transcript(id or path.stem, header, lines)


# ---------------------------------------------------------------------------------------------
# Synthetic training sessions


@dataclass
class Session:
    id: str
    transcript: Transcript
    labels: dict  # field -> label (str | list | None); only teacher-agreed labels
    group: str = ""  # restyled variants share their original's group (train/val split unit)
    modes: dict = field(default_factory=dict)
    all_labels: dict = field(default_factory=dict)  # including disagreements (for analysis)


def load_synth(dirs: list[Path]) -> list[Session]:
    out = []
    for d in dirs:
        for truth_path in sorted(d.glob("*/truth.json")):
            t = json.loads(truth_path.read_text())
            tr = read_transcript(truth_path.parent / "transcript.txt", t["id"])
            labels, modes, all_labels = {}, {}, {}
            for f, v in t["labels"].items():
                if f not in SCOPE:
                    continue
                lab = v["label"]
                if f in CHECKBOX:
                    lab = sorted(lab) if lab else []
                all_labels[f] = lab
                modes[f] = v["mode"]
                if v["agree"]:
                    labels[f] = lab
            out.append(Session(t["id"], tr, labels, t.get("origin", t["id"]), modes, all_labels))
    return out


def is_val(sid: str, val_frac=0.15) -> bool:
    """Stable by session id, so adding sessions never moves an existing one across the split."""
    import hashlib

    return int(hashlib.sha256(sid.encode()).hexdigest()[:8], 16) % 1000 < val_frac * 1000


# The gold test set (hand-reviewed real conversations, tools/distill/gold_ids.json): held out
# of training (they are validation-split groups) AND of the validation set used for thresholds.
_GOLD_PATH = Path(__file__).parent / "gold_ids.json"
GOLD = set(json.loads(_GOLD_PATH.read_text())) if _GOLD_PATH.exists() else set()


def split(sessions: list[Session], val_frac=0.15) -> tuple[list[Session], list[Session]]:
    g = lambda s: s.group or s.id
    assert not any(x in GOLD and not is_val(x, val_frac) for x in map(g, sessions)), "a gold group landed in train"
    return ([s for s in sessions if not is_val(g(s), val_frac)],
            [s for s in sessions if is_val(g(s), val_frac) and g(s) not in GOLD])


def gold_sessions(sessions: list[Session]) -> list[Session]:
    """Only the originals (not restyled variants) of the gold groups."""
    return [s for s in sessions if s.id in GOLD]


# ---------------------------------------------------------------------------------------------
# Eval sessions (hand-written ground truth)


def eval_sets(heldout=False) -> list[tuple[Transcript, dict]]:
    names = HELDOUT if heldout else CORPUS
    out = []
    for n in names:
        if n == "sample-session":
            tp, ep = ROOT / "fixtures/sample-session.txt", ROOT / "fixtures/expected-extraction.json"
        elif n.startswith("heldout"):
            tp, ep = ROOT / f"fixtures/corpus/heldout/{n}.txt", ROOT / f"fixtures/corpus/heldout/expected-{n}.json"
        else:
            tp, ep = ROOT / f"fixtures/corpus/{n}.txt", ROOT / f"fixtures/corpus/expected-{n[len('session-'):]}.json"
        out.append((read_transcript(tp, n), json.loads(ep.read_text())))
    return out


def gemma_predictions(run_dir: Path, name: str) -> dict | None:
    p = run_dir / f"{name}.json"
    if not p.exists():
        return None
    pred = {}
    for r in json.loads(p.read_text()):
        if r["key"] in SCOPE:
            pred[r["key"]] = r.get("value") if r.get("status") in ("filled", "derived") else None
    return pred


# ---------------------------------------------------------------------------------------------
# Scoring


def _vals(v) -> list[str]:
    if v is None or v == "":
        return []
    if isinstance(v, list):
        return [str(x) for x in v]
    return [str(v)]


@dataclass
class Check:
    key: str
    bucket: str
    expected: object
    actual: object
    outcome: str  # ok | unsafe | blank
    risk: bool


def score(pred: dict, expected: dict) -> list[Check]:
    risk = set(expected.get("risk_fields", []))
    checks = []

    def add(k, bucket, want, outcome):
        checks.append(Check(k, bucket, want, pred.get(k), outcome, k in risk))

    for k, want in expected.get("must_fill", {}).items():
        if k not in SCOPE:
            continue
        got = _vals(pred.get(k))
        wantv = _vals(want)
        if sorted(got) == sorted(wantv) and got:
            add(k, "must_fill", want, "ok")
        else:
            add(k, "must_fill", want, "blank" if not got else "unsafe")
    for k, lst in expected.get("acceptable", {}).items():
        if k not in SCOPE:
            continue
        got = _vals(pred.get(k))
        ok = any((o is None and not got) or (o is not None and got == [str(o)]) for o in lst)
        add(k, "acceptable", lst, "ok" if ok else ("blank" if not got else "unsafe"))
    for k, spec in expected.get("checkbox_constraints", {}).items():
        if k not in SCOPE:
            continue
        got = set(_vals(pred.get(k)))
        inc, exc = set(spec.get("must_include", [])), set(spec.get("must_exclude", []))
        if got & exc:
            outcome = "unsafe"
        elif inc <= got:
            outcome = "ok"
        else:
            outcome = "blank"
        add(k, "checkbox_constraints", spec, outcome)
    for k in expected.get("must_leave_blank", []):
        if k not in SCOPE:
            continue
        add(k, "must_leave_blank", None, "ok" if not _vals(pred.get(k)) else "unsafe")
    return checks


def summarize(checks: list[Check]) -> dict:
    n = len(checks)
    ok = sum(c.outcome == "ok" for c in checks)
    unsafe = [c for c in checks if c.outcome == "unsafe"]
    blank = [c for c in checks if c.outcome == "blank"]
    return {
        "checks": n,
        "ok": ok,
        "accuracy": ok / n if n else 0.0,
        "unsafe": len(unsafe),
        "unsafe_risk": sum(c.risk for c in unsafe),
        "safe_blank": len(blank),
        "blank_violations": sum(c.bucket == "must_leave_blank" for c in unsafe),
    }


def report(name: str, per_session: dict[str, list[Check]]) -> str:
    rows = [f"### {name}", "", "| session | checks | ok | accuracy | unsafe | unsafe (risk) | safe blank | blank violations |", "|---|---|---|---|---|---|---|---|"]
    allc = []
    for s, cs in per_session.items():
        m = summarize(cs)
        allc += cs
        rows.append(f"| {s} | {m['checks']} | {m['ok']} | {m['accuracy']:.1%} | {m['unsafe']} | {m['unsafe_risk']} | {m['safe_blank']} | {m['blank_violations']} |")
    m = summarize(allc)
    rows.append(f"| **all** | {m['checks']} | {m['ok']} | **{m['accuracy']:.1%}** | **{m['unsafe']}** | **{m['unsafe_risk']}** | {m['safe_blank']} | {m['blank_violations']} |")
    return "\n".join(rows)


def unsafe_list(per_session: dict[str, list[Check]]) -> str:
    lines = []
    for s, cs in per_session.items():
        for c in cs:
            if c.outcome == "unsafe":
                lines.append(f"- {s} · `{c.key}`{' (risk)' if c.risk else ''} [{c.bucket}] expected {json.dumps(c.expected)} got {json.dumps(c.actual)}")
    return "\n".join(lines) or "- none"
