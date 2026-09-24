"""Package the training conversations as a Hugging Face dataset (CC BY 4.0).

    python3 tools/synth/export_dataset.py [--out dist/scribeski-intake-dialogues]

Includes: complete synthetic behavioral-health sessions (data/synth/*, config "intake").
With --clinic-dir (e.g. ~/Downloads/scribeski-gp-data), also the CC BY 4.0 GP conversations
("clinic") and their restyled variants ("clinic_restyled"), meant for a doctor-intake model.
Excludes: incomplete sessions, unlabelled public dialogues, raw downloads (link to the
originals instead), AnnoMI (no license), and the eval corpus under fixtures/ (never shipped).

Every label value is a list of strings ([] = not established / blank) so Arrow gets one type.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIELDS = json.loads((ROOT / "tools/distill/fields.json").read_text())["FIELDS"]
ITEMS = [f"phq9_{i}" for i in range(1, 10)] + [f"gad7_{i}" for i in range(1, 8)]
SCOPE = list(FIELDS) + ITEMS
LINE = re.compile(r"^\[(\d+:\d+)\]\s*([A-Z_ ]+?):\s*(.*)$")

# PII-shaped strings that synthetic text must never contain (fictional numbers are 555-01xx).
PHONE = re.compile(r"\(?\b(\d{3})\)?[\s.-]?(\d{3})[\s.-]?(\d{4})\b")
EMAIL = re.compile(r"\b[\w.+-]+@([\w-]+\.)+[a-z]{2,}\b", re.I)
SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")


def is_val(group: str) -> bool:  # identical to tools/distill/common.is_val
    return int(hashlib.sha256(group.encode()).hexdigest()[:8], 16) % 1000 < 150


def values(v) -> list[str]:
    if v is None or v == "":
        return []
    return [str(x) for x in v] if isinstance(v, list) else [str(v)]


def transcript(path: Path):
    header, turns = {}, []
    for raw in path.read_text().splitlines():
        if raw.startswith("#"):
            m = re.match(r"#\s*([a-z_]+):\s*(.*)", raw)
            if m:
                header[m.group(1)] = m.group(2)
            continue
        m = LINE.match(raw.strip())
        if m:
            turns.append({"time": m.group(1), "speaker": m.group(2).strip(), "text": m.group(3).strip()})
    return header, turns


def pii_hits(turns) -> list[str]:
    hits = []
    for t in turns:
        for m in PHONE.finditer(t["text"]):
            if not (m.group(2) == "555" and m.group(3).startswith("01")):
                hits.append(f"phone {m.group(0)}")
        for m in EMAIL.finditer(t["text"]):
            if not m.group(0).lower().endswith(("example.com", "example.org", "example.net")):
                hits.append(f"email {m.group(0)}")
        hits += [f"ssn-like {m.group(0)}" for m in SSN.finditer(t["text"])]
    return hits


def record(kind: str, session_dir: Path, batch: str) -> dict | None:
    truth_p = session_dir / "truth.json"
    if not truth_p.exists():
        return None
    truth = json.loads(truth_p.read_text())
    header, turns = transcript(session_dir / "transcript.txt")
    if not turns:
        return None
    group = truth.get("origin", truth["id"])
    labels = []
    for f in SCOPE:
        v = truth["labels"].get(f)
        if v is None:
            continue
        labels.append({
            "field": f,
            "value": values(v["label"]),
            "agreed": bool(v["agree"]),
            "mode": v.get("mode", ""),
            "acceptable": [x if x is not None else "" for x in v.get("acceptable") or []],
        })
    prov: dict = {"batch": batch}
    if kind == "synthetic":
        sheet = json.loads((session_dir / "sheet.json").read_text())
        prov.update(generator="synth-v2" if "scenario" in sheet else "synth-v1", writer=truth.get("writer"), teacher=truth.get("teacher"),
                    seed=truth.get("seed"), session_type=sheet["session_type"], modality=sheet["modality"], wpm=sheet["wpm"],
                    scenario=sheet.get("scenario"), instruments=sheet["instruments"])
        language = sheet["language"]
        source = prov["generator"]
    elif kind == "public":
        prov.update(teachers=truth.get("teachers"), note=header.get("note", ""))
        language, source = "en", truth.get("source", batch)
    else:
        prov.update(origin=group, style=truth.get("style"), writer=truth.get("writer"), teacher=truth.get("teacher"), note=header.get("note", ""))
        language, source = (truth.get("style") or {}).get("language", "en"), f"restyled-{truth.get('source', batch)}"
    return {
        "id": truth["id"], "group": group, "kind": kind, "source": source,
        "split": "validation" if is_val(group) else "train", "language": language,
        "duration_minutes": int(header.get("duration_minutes") or 0),
        "transcript": turns, "labels": labels,
        "provenance_json": json.dumps(prov, ensure_ascii=False),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dist/scribeski-intake-dialogues")
    ap.add_argument("--clinic-dir", default=None, help="GP data folder (converted/, restyled/) to add the clinic configs; omitted by default")
    args = ap.parse_args()
    out = ROOT / args.out
    if out.exists():
        shutil.rmtree(out)
    (out / "data").mkdir(parents=True)

    plan = [("synthetic", d) for d in sorted((ROOT / "data/synth").iterdir()) if d.is_dir()]
    if args.clinic_dir:
        clinic = Path(args.clinic_dir).expanduser()
        plan += [("public", d) for d in sorted((clinic / "converted").iterdir()) if d.is_dir()]
        plan += [("restyled", d) for d in sorted((clinic / "restyled").iterdir()) if d.is_dir()]

    rows: dict[str, dict[str, list]] = {}
    skipped, flagged = Counter(), []
    for kind, batch_dir in plan:
        for s in sorted(p for p in batch_dir.iterdir() if p.is_dir()):
            r = record(kind, s, batch_dir.name)
            if r is None:
                skipped[f"{kind}/{batch_dir.name}"] += 1
                continue
            if kind != "public":  # LLM-written text: no real-looking phone numbers, emails, SSNs
                hits = pii_hits(r["transcript"])
                if hits:
                    flagged.append((r["id"], hits[:3]))
                    skipped[f"{kind} with PII-shaped strings"] += 1
                    continue
            rows.setdefault(kind, {}).setdefault(r["split"], []).append(r)

    files, counts = {}, {}
    FOLDER = {"synthetic": "intake", "public": "clinic", "restyled": "clinic_restyled"}
    for kind, splits in rows.items():
        (out / "data" / FOLDER[kind]).mkdir(parents=True, exist_ok=True)
        for split, rs in splits.items():
            p = out / "data" / FOLDER[kind] / f"{split}.jsonl"
            p.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rs))
            files[str(p.relative_to(out))] = hashlib.sha256(p.read_bytes()).hexdigest()
            counts[f"{FOLDER[kind]}/{split}"] = len(rs)

    (out / "schema").mkdir()
    schema = {f: {"kind": FIELDS[f]["kind"], "topic": FIELDS[f]["topic"], "options": FIELDS[f]["options"], "descriptions": FIELDS[f]["desc"]} for f in FIELDS}
    schema.update({f: {"kind": "questionnaire_item", "options": ["0", "1", "2", "3"], "topic": f} for f in ITEMS})
    (out / "schema/fields.json").write_text(json.dumps(schema, indent=1, ensure_ascii=False))

    by = Counter()
    minutes = Counter()
    for kind, splits in rows.items():
        for rs in splits.values():
            for r in rs:
                by[(kind, r["source"], r["language"])] += 1
                minutes[kind] += r["duration_minutes"]
    code = hashlib.sha256(b"".join(p.read_bytes() for p in sorted((ROOT / "tools/synth").glob("*.[mp][jy]*")) if p.suffix in (".mjs", ".py"))).hexdigest()
    manifest = {
        "name": out.name, "created": dt.date.today().isoformat(), "license": "CC-BY-4.0",
        "counts": counts, "by_source": {f"{k}/{s}/{l}": n for (k, s, l), n in sorted(by.items())},
        "minutes": dict(minutes), "files_sha256": files,
        "generator_code_sha256": code, "generator_note": "hash of tools/synth at export time; synth-v1 sessions were written by an earlier revision (see provenance_json.batch)",
        "skipped": dict(skipped), "pii_flagged": flagged,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    table = ["| subset | source | language | conversations |", "|---|---|---|---|"]
    table += [f"| {k} | {s} | {l} | {n} |" for (k, s, l), n in sorted(by.items())]
    table += ["", f"Train / validation: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + ".",
              f"Total transcript length ≈ {sum(minutes.values()):,} minutes."]
    card = (ROOT / "tools/synth/dataset_card.md").read_text().replace("<!-- COUNTS -->", "\n".join(table))
    if not args.clinic_dir:  # intake-only release: drop the clinic configs and text
        card = re.sub(r"- config_name: clinic.*?(?=\n---)", "", card, flags=re.S)
        card = re.sub(r"<!-- CLINIC -->.*?<!-- /CLINIC -->\n?", "", card, flags=re.S)
    card = card.replace("<!-- CLINIC -->\n", "").replace("<!-- /CLINIC -->\n", "")
    (out / "README.md").write_text(card)
    bib = (ROOT / "tools/synth/CITATION.bib").read_text()
    if not args.clinic_dir:  # intake-only release: only this dataset's own entry
        bib = bib.split("% Sources")[0].rstrip() + "\n"
    (out / "CITATION.bib").write_text(bib)
    try:
        lic = urllib.request.urlopen(urllib.request.Request("https://creativecommons.org/licenses/by/4.0/legalcode.txt", headers={"User-Agent": "curl/8"}), timeout=30).read()
        (out / "LICENSE").write_bytes(lic)
    except Exception as e:  # keep going; the card links the license
        (out / "LICENSE").write_text("Creative Commons Attribution 4.0 International (CC BY 4.0)\nhttps://creativecommons.org/licenses/by/4.0/legalcode\n")
        print("license text not fetched:", e)
    print(json.dumps({k: manifest[k] for k in ("counts", "minutes", "skipped")}, indent=1))
    print(f"PII-shaped strings flagged in {len(flagged)} LLM-written sessions (excluded)")
    for f in flagged[:10]:
        print("  ", f)
    print(f"→ {out}")


if __name__ == "__main__":
    main()
