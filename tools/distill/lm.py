"""Distilled classifier tier: a small causal LM that answers every field in ONE forward pass.

Prompt = rules + the whole transcript + every question, each ending in "Answer:". No answers
are written into the prompt, so questions are independent and there is no decoding: the
logits at each "Answer:" position, restricted to that question's option letters, are the
answer distribution (scored, not generated). Checkbox fields become one yes/no question per
option. "Z" is always "not established" (blank).

Training: loss = -log Σ p(acceptable letters) at labelled positions only; only the letter
rows of the (tied) LM head are ever computed, so 32k-token sessions fit easily.

    python lm.py train --model Qwen/Qwen3-1.7B --synth DIR... --out OUT [--max-len 32768]
    python lm.py predict --model OUT --out OUT            # val + corpus (+ --heldout)
"""
from __future__ import annotations

import argparse
import json
import math
import random
import time
from dataclasses import dataclass
from pathlib import Path

import torch
import torch.nn.functional as F

from common import (CHECKBOX, EXCLUSIVE, FIELDS, ITEM_TEXT, ITEMS, SCOPE, eval_sets, load_synth, options, split)

LETTERS = "ABCDEFGH"
BLANK = "Z"

RULES = """You fill a behavioural-health intake form from a session transcript. For each question, answer with one letter.
- Answer about the CLIENT's own current situation (for referrals, crisis resources and safety plans: what the worker actually did in this session).
- Z = not established: never discussed, only hypothetical/conditional/future, about someone else, left unresolved, or the client declined (use a DECLINED option where there is one).
- If something is corrected later, the final version counts.
- A passing mention counts: an aside or a detail inside a story establishes a fact when it clearly describes the client's current situation.
- If what was said fits none of the options (e.g. active suicidal thoughts but a plan never asked about), answer Z so a person reviews it.
- Lines starting with "[family member]" or "[another clinician]" are said by someone other than the client.
- Questionnaire items (PHQ-9, GAD-7) only if the worker administers that questionnaire; past two weeks: 0 not at all, 1 several days (2-6 of 14), 2 more than half the days (8-11), 3 nearly every day (12-14).
- Don't infer one field from another, from names, family roles, or the language being spoken."""

ANCHOR = {"0": "not at all", "1": "several days", "2": "more than half the days", "3": "nearly every day"}


@dataclass
class Question:
    qid: str          # field, or field:OPTION for checkbox yes/no
    field: str
    text: str
    letters: str      # letters this question may be answered with, incl. Z where applicable
    values: list      # value for each letter (None for Z / "no")


def questions() -> list[Question]:
    qs = []
    for f in SCOPE:
        if f in ITEMS:
            inst = "PHQ-9" if f.startswith("phq9") else "GAD-7"
            opts = options(f)
            body = " ".join(f"{LETTERS[i]}) {o} {ANCHOR[o]}" for i, o in enumerate(opts))
            qs.append(Question(f, f, f"{inst} item {f.split('_')[1]} \"{ITEM_TEXT[f]}\": {body} Z) not asked", LETTERS[: len(opts)] + BLANK, opts + [None]))
        elif f in CHECKBOX:
            for o in options(f):
                d = FIELDS[f]["desc"].get(o, o)
                qs.append(Question(f"{f}:{o}", f, f"{FIELDS[f]['topic']} — {d}? A) yes B) no or not established", "AB", [o, None]))
        else:
            opts = [o for o in options(f)]
            body = " ".join(f"{LETTERS[i]}) {FIELDS[f]['desc'].get(o) or o.replace('_', ' ').lower()}" for i, o in enumerate(opts))
            qs.append(Question(f, f, f"{FIELDS[f]['topic']}: {body} Z) not established", LETTERS[: len(opts)] + BLANK, opts + [None]))
    return qs


QS = questions()


def allowed_letters(q: Question, label, acceptable=None) -> str | None:
    """Letters that count as correct for a label; None = unlabelled (no loss)."""
    if q.field in CHECKBOX:
        opt = q.qid.split(":", 1)[1]
        return "A" if opt in (label or []) else "B"
    accept = acceptable if acceptable is not None else [label]
    out = ""
    for v in accept:
        v = None if v is None else str(v)
        if v in q.values:
            out += q.letters[q.values.index(v)]
    return out or None


def build(transcript_lines: list[str], qs: list[Question], tok, max_len: int):
    """Token ids + the index of each question's last prompt token (where its answer is read)."""
    head = tok.apply_chat_template(
        [{"role": "system", "content": RULES}, {"role": "user", "content": "TRANSCRIPT:\n" + "\n".join(transcript_lines)}],
        tokenize=False, add_generation_prompt=True, enable_thinking=False)
    q_parts = [f"Q{i + 1}. {q.text}\nAnswer:" for i, q in enumerate(qs)]
    q_ids = [tok(("\n" if i else "") + p, add_special_tokens=False)["input_ids"] for i, p in enumerate(q_parts)]
    q_len = sum(len(x) for x in q_ids)
    head_ids = tok(head, add_special_tokens=False)["input_ids"]
    budget = max_len - q_len
    assert budget > 2048, f"max_len {max_len} leaves only {budget} tokens for the transcript (questions take {q_len})"
    if len(head_ids) > budget:  # drop from the middle of the transcript, keep rules + both ends
        keep = budget - 16
        cut = tok("\n[…]\n", add_special_tokens=False)["input_ids"]
        head_ids = head_ids[: keep // 2] + cut + head_ids[-(keep - keep // 2):]
    ids, pos = list(head_ids), []
    for x in q_ids:
        ids += x
        pos.append(len(ids) - 1)
    return ids, pos


def letter_ids(tok) -> dict[str, int]:
    out = {}
    for L in LETTERS + BLANK:
        t = tok(" " + L, add_special_tokens=False)["input_ids"]
        assert len(t) == 1, (L, t)
        out[L] = t[0]
    return out


def score_positions(model, ids, pos, qs, lid, device):
    """Forward once; return per-question log-probs over its own letters."""
    x = torch.tensor([ids], device=device)
    h = model.model(input_ids=x).last_hidden_state[0]  # (T, d)
    W = model.get_output_embeddings().weight
    out = []
    hp = h[torch.tensor(pos, device=device)]
    for i, q in enumerate(qs):
        rows = torch.tensor([lid[L] for L in q.letters], device=device)
        logits = (hp[i] @ W[rows].T).float()
        out.append(F.log_softmax(logits, -1))
    return out


# ---------------------------------------------------------------------------------------------


def load_model(name, device, train=False):
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tok = AutoTokenizer.from_pretrained(name)
    # Training keeps fp32 master weights (bf16 can't represent 1e-5-sized updates) under bf16 autocast.
    kw = dict(dtype=torch.float32 if (train and device == "cuda") else torch.bfloat16)
    if device == "cuda":
        try:
            import flash_attn  # noqa: F401

            kw["attn_implementation"] = "flash_attention_2"
        except ImportError:
            kw["attn_implementation"] = "sdpa"
    model = AutoModelForCausalLM.from_pretrained(name, **kw).to(device)
    if train:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.config.use_cache = False
    return tok, model


def train(args):
    device = "cuda" if torch.cuda.is_available() else "mps"
    sessions = load_synth([Path(d) for d in args.synth])
    tr, va = split(sessions)
    print(f"{len(sessions)} sessions: {len(tr)} train, {len(va)} val", flush=True)
    tok, model = load_model(args.model, device, train=True)
    lid = letter_ids(tok)
    acc_map = acceptable_map(args.synth)

    def targets(s):
        out = []
        for q in QS:
            if q.field not in s.labels:
                out.append(None)
                continue
            out.append(allowed_letters(q, s.labels[q.field], acc_map.get((s.id, q.field))))
        return out

    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=args.lr, weight_decay=0.0, betas=(0.9, 0.95))
    per_epoch = len(epoch_order(tr, random.Random(1), args.mts_frac))
    steps = int(args.epochs * per_epoch) // args.accum
    print(f"~{per_epoch} sessions per epoch", flush=True)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda k: min(1.0, (k + 1) / max(1, int(0.06 * steps))) * 0.5 * (1 + math.cos(math.pi * min(1.0, k / max(1, steps)))))
    rnd = random.Random(0)
    t0, step, seen = time.time(), 0, 0
    model.train()
    for ep in range(args.epochs):
        # Blend: every synthetic and long public session each epoch; only a fraction of the
        # 1.7k short, mostly-blank MTS-Dialog snippets so they don't swamp the signal.
        order = epoch_order(tr, rnd, args.mts_frac)
        for i in order:
            s = tr[i]
            perm = list(range(len(QS)))
            rnd.shuffle(perm)  # question order varies in training; fixed at inference
            qs = [QS[j] for j in perm]
            all_t = targets(s)
            tg = [all_t[j] for j in perm]
            ids, pos = build(s.transcript.lines, qs, tok, args.max_len)
            with torch.autocast(device_type=device, dtype=torch.bfloat16, enabled=device == "cuda"):
                lps = score_positions(model, ids, pos, qs, lid, device)
            losses = [-torch.logsumexp(lp[[q.letters.index(L) for L in t]], 0) for lp, q, t in zip(lps, qs, tg) if t]
            loss = torch.stack(losses).mean() / args.accum
            loss.backward()
            seen += 1
            if seen % args.accum == 0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step()
                sched.step()
                opt.zero_grad(set_to_none=True)
                step += 1
            if seen % 5 == 0:
                print(f"ep {ep + 1} seen {seen} step {step}/{steps} loss {loss.item() * args.accum:.4f} len {len(ids)} lr {sched.get_last_lr()[0]:.2e} {time.time() - t0:.0f}s", flush=True)
        # Saved in bf16 (half the size); training continues on the fp32 weights.
        sd = {k: v.to(torch.bfloat16) for k, v in model.state_dict().items()}
        model.save_pretrained(Path(args.out) / f"epoch{ep + 1}", state_dict=sd)
        tok.save_pretrained(Path(args.out) / f"epoch{ep + 1}")
        model.config.save_pretrained(Path(args.out) / f"epoch{ep + 1}")
    print(f"trained in {time.time() - t0:.0f}s", flush=True)


def epoch_order(tr, rnd, mts_frac):
    """One epoch: every original (synthetic, public); only `mts_frac` of the short MTS-Dialog
    snippets; and ONE randomly chosen restyled variant per conversation (a different one each
    epoch), so variants add style diversity without multiplying cost."""
    variants = {}
    order = []
    for i, s in enumerate(tr):
        if s.group and s.group != s.id:
            variants.setdefault(s.group, []).append(i)
        elif not s.id.startswith("mts-") or rnd.random() < mts_frac:
            order.append(i)
    order += [rnd.choice(v) for v in variants.values()]
    rnd.shuffle(order)
    return order


def acceptable_map(dirs):
    """(session id, field) → acceptable list from truth.json, where the sampler gave one."""
    m = {}
    for d in dirs:
        for p in Path(d).glob("*/truth.json"):
            t = json.loads(p.read_text())
            for f, v in t["labels"].items():
                if v.get("acceptable"):
                    m[(t["id"], f)] = v["acceptable"]
    return m


def to_prediction(lps: list, qs: list[Question], T=1.0) -> dict:
    """Per field: probabilities over values (None = blank). Checkbox: per-option P(yes)."""
    out = {}
    for lp, q in zip(lps, qs):
        p = F.softmax(lp / T, -1).tolist()
        if q.field in CHECKBOX:
            out.setdefault(q.field, {})[q.qid.split(":", 1)[1]] = p[0]
        else:
            out[q.field] = {("" if v is None else v): pi for v, pi in zip(q.values, p)}
    return out


def predict(args):
    device = "cuda" if torch.cuda.is_available() else "mps"
    tok, model = load_model(args.model, device)
    model.eval()
    lid = letter_ids(tok)
    res = {}

    def run(name, lines):
        t0 = time.time()
        ids, pos = build(lines, QS, tok, args.max_len)
        with torch.no_grad():
            lps = score_positions(model, ids, pos, QS, lid, device)
        if device == "cuda":
            torch.cuda.synchronize()
        res[name] = {"probs": to_prediction([lp.cpu() for lp in lps], QS), "tokens": len(ids), "seconds": time.time() - t0}
        print(f"{name}: {len(ids)} tokens, {time.time() - t0:.2f}s", flush=True)

    if args.synth:
        _, va = split(load_synth([Path(d) for d in args.synth]))
        for s in va:
            run("val/" + s.id, s.transcript.lines)
    for tr, _ in eval_sets(False):
        run("corpus/" + tr.id, tr.lines)
    if args.heldout:
        for tr, _ in eval_sets(True):
            run("heldout/" + tr.id, tr.lines)
    if args.synth:
        from common import gold_sessions
        for s in gold_sessions(load_synth([Path(d) for d in args.synth])):
            run("gold/" + s.id, s.transcript.lines)
    for d in args.extra_dirs:
        from common import read_transcript
        for p in sorted(Path(d).glob("*/transcript.txt")):
            run("gold/" + p.parent.name, read_transcript(p).lines)
    Path(args.out).mkdir(parents=True, exist_ok=True)
    (Path(args.out) / args.pred_name).write_text(json.dumps(res))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["train", "predict"])
    ap.add_argument("--model", required=True)
    ap.add_argument("--synth", nargs="*", default=[])
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-len", type=int, default=32768)
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=1e-5)
    ap.add_argument("--accum", type=int, default=4)
    ap.add_argument("--heldout", action="store_true")
    ap.add_argument("--mts-frac", type=float, default=0.3)
    ap.add_argument("--extra-dirs", nargs="*", default=[])
    ap.add_argument("--pred-name", default="predictions.json")
    a = ap.parse_args()
    train(a) if a.cmd == "train" else predict(a)
