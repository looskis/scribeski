"""Convert permissively licensed public clinical dialogues into scribeski transcripts.

Only CC BY 4.0 sources (attribution in each transcript header and ~/Downloads/scribeski-gp-data/converted/ATTRIBUTION.md):
  - PriMock57   (Papadopoulos Korfiatis et al., 2022)  57 mock primary-care consultations, spoken
  - ACI-BENCH   (Yim et al., 2023)                     207 doctor–patient encounters
  - MTS-Dialog  (Ben Abacha et al., 2023)              1,701 short doctor–patient dialogues

These are primary-care visits, not behavioral-health intakes: most form fields will be blank,
but social history (who they live with, work, alcohol, tobacco, drugs, medications) comes up.
They have no labels for our form; tools/synth/label_public.mjs adds teacher labels.

    python tools/synth/import_public.py        # ~/Downloads/scribeski-gp-data/raw → .../converted/<source>/<id>/transcript.txt
"""
from __future__ import annotations

import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = Path.home() / "Downloads/scribeski-gp-data/raw"
OUT = Path.home() / "Downloads/scribeski-gp-data/converted"  # GP data lives outside the repo (2026-09-23)

WORKER = {"doctor", "clinician", "dr"}
CLIENT = {"patient"}


def speaker(tag: str) -> tuple[str, str]:
    """(WORKER|CLIENT, prefix). Anyone else stays on the CLIENT channel but is marked."""
    t = tag.strip().lower().replace("[", "").replace("]", "").strip()
    if t in WORKER:
        return "WORKER", ""
    if t in CLIENT:
        return "CLIENT", ""
    if "clinic" in t:  # Guest_clinician (and its misspelling): a second clinician
        return "WORKER", "[another clinician] "
    if t == "patient_guest" or "family" in t:
        return "CLIENT", "[family member] "
    return "CLIENT", f"[{t.replace('_', ' ')}] "


def detok(s: str) -> str:
    """ACI-BENCH is tokenized ('i'm doing okay , how are you ?')."""
    s = re.sub(r"\s+([,.?!;:])", r"\1", s)
    s = re.sub(r"\s+'", "'", s)
    return re.sub(r"\s+", " ", s).strip()


def write(source: str, id: str, rows: list[tuple[str, str, float | None]], note: str, wpm=150):
    d = OUT / source / id
    d.mkdir(parents=True, exist_ok=True)
    t, out = 4.0, []
    for who, text, start in rows:
        if not text.strip():
            continue
        ts = start if start is not None else t
        out.append(f"[{int(ts // 60):02d}:{int(ts % 60):02d}] {who}: {text.strip()}")
        t = ts + len(text.split()) / wpm * 60 + 0.8
    header = [
        "# scribeski transcript fixture v1",
        "# session_date: 2026-01-01",
        "# started_at: 2026-01-01T10:00:00-08:00",
        "# modality: in_person",
        f"# duration_minutes: {max(1, round(t / 60))}",
        f"# note: PUBLIC DATA, {note}",
    ]
    (d / "transcript.txt").write_text("\n".join(header + out) + "\n")


def aci():
    n = 0
    for f in sorted((SRC / "aci").glob("*.csv")):
        for r in csv.DictReader(open(f, encoding="utf-8")):
            rows = []
            for line in r["dialogue"].splitlines():
                m = re.match(r"^\s*(\[(?:doctor|patient|patient_guest)\])\s*(.*)$", line)
                if not m:
                    if rows:  # continuation of the previous turn
                        rows[-1] = (rows[-1][0], rows[-1][1] + " " + detok(line), None)
                    continue
                who, pre = speaker(m.group(1))
                rows.append((who, pre + detok(m.group(2)), None))
            write("aci", f"{f.stem}-{r['encounter_id']}", rows, "ACI-BENCH (Yim et al. 2023), CC BY 4.0")
            n += 1
    return n


def mts():
    n = 0
    for f in sorted((SRC / "mts").glob("*.csv")):
        for r in csv.DictReader(open(f, encoding="utf-8")):
            rows = []
            for line in r["dialogue"].splitlines():
                m = re.match(r"^\s*([A-Za-z_ ]+?)\s*:\s*(.*)$", line)
                if m:
                    who, pre = speaker(m.group(1))
                    rows.append((who, pre + m.group(2).strip(), None))
                elif rows and line.strip():
                    rows[-1] = (rows[-1][0], rows[-1][1] + " " + line.strip(), None)
            split = f.stem.replace("MTS-Dialog-", "").replace("-MEDIQA", "").lower()
            write("mts", f"{split}-{r['ID']}-{r['section_header'].replace('/', '_')}", rows,
                  f"MTS-Dialog (Ben Abacha et al. 2023), CC BY 4.0; section {r['section_header']}")
            n += 1
    return n


def textgrid(path: Path) -> list[tuple[float, str]]:
    out, xmin = [], None
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("xmin ="):
            xmin = float(line.split("=")[1])
        elif line.startswith("text ="):
            text = line.split("=", 1)[1].strip().strip('"')
            text = re.sub(r"<UNIN/>", "[inaudible]", text)
            text = re.sub(r"</?UNSURE>", "", text)
            text = re.sub(r"<[^>]+>", "", text).strip()
            if text and xmin is not None:
                out.append((xmin, text))
    return out


def primock():
    n = 0
    for doc in sorted((SRC / "primock57").glob("*_doctor.TextGrid")):
        pat = doc.with_name(doc.name.replace("_doctor", "_patient"))
        rows = [(t, "WORKER", s) for t, s in textgrid(doc)] + [(t, "CLIENT", s) for t, s in textgrid(pat)]
        rows.sort()
        write("primock57", doc.stem.replace("_doctor", ""), [(w, s, t) for t, w, s in rows],
              "PriMock57 (Papadopoulos Korfiatis et al. 2022), CC BY 4.0; mock consultation, real speech")
        n += 1
    return n


if __name__ == "__main__":
    counts = {"aci": aci(), "mts": mts(), "primock57": primock()}
    (OUT / "ATTRIBUTION.md").write_text(
        "# Public data used for training (all CC BY 4.0)\n\n"
        "- **PriMock57**: Papadopoulos Korfiatis et al., *PriMock57: A Dataset Of Primary Care Mock Consultations*, ACL 2022. https://github.com/babylonhealth/primock57\n"
        "- **ACI-BENCH**: Yim et al., *Aci-bench: a Novel Ambient Clinical Intelligence Dataset for Benchmarking Automatic Visit Note Generation*, Scientific Data 2023. https://github.com/wyim/aci-bench\n"
        "- **MTS-Dialog**: Ben Abacha et al., *An Empirical Study of Clinical Note Generation from Doctor-Patient Encounters*, EACL 2023. https://github.com/abachaa/MTS-Dialog\n\n"
        "Converted to scribeski's transcript format (speaker mapping, detokenization, timestamps estimated where absent).\n")
    print(counts)
