"""Lambda Cloud helper for the P1.9 fine-tune: launch one GPU, wait, report IP, terminate.

    python gpu.py types                         # capacity + prices
    python gpu.py launch --want gpu_1x_h100_sxm5,gpu_1x_h100_pcie [--poll-minutes 120]
    python gpu.py status
    python gpu.py terminate                     # terminates the instance in state.json, removes its SSH key

State (instance id, ip, key name) lives in out/gpu/state.json so a crashed session can still
terminate. Billing runs until terminate — always terminate.
"""
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
API = "https://cloud.lambda.ai/api/v1"
STATE = Path(__file__).parent / "out" / "gpu" / "state.json"


def key() -> str:
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith("LAMBDALABS_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit("LAMBDALABS_API_KEY missing from .env")


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{key()}:".encode()).decode())
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "curl/8.7.1")  # the default Python UA is refused at the edge
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return {"error": json.loads(body or b"{}").get("error", {"code": e.code})}
        except json.JSONDecodeError:
            return {"error": {"code": e.code, "body": body[:200].decode(errors="replace")}}


def load_state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save_state(s):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(s, indent=1))


def types():
    d = call("GET", "/instance-types")["data"]
    return {name: ([r["name"] for r in v["regions_with_capacity_available"]], v["instance_type"]["price_cents_per_hour"] / 100) for name, v in d.items()}


def ensure_key(keydir: Path) -> str:
    st = load_state()
    if st.get("key_name"):
        return st["key_name"]
    keydir.mkdir(parents=True, exist_ok=True)
    priv = keydir / "id_ed25519"
    if not priv.exists():
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-C", "scribeski-distill", "-f", str(priv)], check=True, capture_output=True)
    name = f"scribeski-distill-{int(time.time())}"
    r = call("POST", "/ssh-keys", {"name": name, "public_key": (keydir / "id_ed25519.pub").read_text().strip()})
    if "error" in r:
        sys.exit(f"ssh key: {r}")
    st.update(key_name=name, key_id=r["data"]["id"], key_path=str(priv))
    save_state(st)
    return name


def launch(want: list[str], poll_minutes: int, keydir: Path):
    st = load_state()
    if st.get("instance_id"):
        sys.exit(f"already have instance {st['instance_id']} — terminate it first")
    kname = ensure_key(keydir)
    deadline = time.time() + poll_minutes * 60
    while True:
        caps = types()
        for t in want:
            regions, price = caps.get(t, ([], 0))
            if regions:
                r = call("POST", "/instance-operations/launch", {"region_name": regions[0], "instance_type_name": t, "ssh_key_names": [kname], "quantity": 1, "name": "scribeski-distill"})
                if "error" in r:
                    print(f"launch {t} in {regions[0]} failed: {r['error']}", flush=True)
                    continue
                iid = r["data"]["instance_ids"][0]
                st = load_state()
                st.update(instance_id=iid, type=t, region=regions[0], price=price, launched=time.time())
                save_state(st)
                print(f"launched {t} (${price}/h) in {regions[0]}: {iid}", flush=True)
                return wait_active()
        if time.time() > deadline:
            sys.exit(f"no capacity for {want} after {poll_minutes} min")
        print(f"{time.strftime('%H:%M')} no capacity for {want}; retrying in 60s", flush=True)
        time.sleep(60)


def wait_active():
    st = load_state()
    while True:
        d = call("GET", f"/instances/{st['instance_id']}").get("data", {})
        if d.get("status") == "active" and d.get("ip"):
            st["ip"] = d["ip"]
            save_state(st)
            print(f"active: ubuntu@{d['ip']}  (ssh -i {st['key_path']} ubuntu@{d['ip']})", flush=True)
            return d["ip"]
        if d.get("status") in ("terminated", "unhealthy"):
            sys.exit(f"instance {d.get('status')}")
        time.sleep(15)


def terminate():
    st = load_state()
    if st.get("instance_id"):
        r = call("POST", "/instance-operations/terminate", {"instance_ids": [st["instance_id"]]})
        print("terminate:", r)
        hours = (time.time() - st.get("launched", time.time())) / 3600
        print(f"ran ~{hours:.2f} h ≈ ${hours * st.get('price', 0):.2f}")
        for _ in range(40):
            d = call("GET", f"/instances/{st['instance_id']}").get("data", {})
            if d.get("status") in ("terminated", None) or "error" in d:
                break
            time.sleep(15)
        print("status now:", call("GET", f"/instances/{st['instance_id']}").get("data", {}).get("status", "gone"))
        st.pop("instance_id", None)
        st.pop("ip", None)
    if st.get("key_id"):
        print("remove ssh key:", call("DELETE", f"/ssh-keys/{st['key_id']}"))
        st.pop("key_id", None)
        st.pop("key_name", None)
    save_state(st)
    print("running instances:", [(i["id"], i["status"]) for i in call("GET", "/instances").get("data", [])])


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["types", "launch", "status", "terminate"])
    ap.add_argument("--want", default="gpu_1x_h100_sxm5,gpu_1x_h100_pcie")
    ap.add_argument("--poll-minutes", type=int, default=120)
    ap.add_argument("--keydir", default=str(Path(__file__).parent / "out" / "gpu" / "ssh"))
    a = ap.parse_args()
    if a.cmd == "types":
        for n, (regs, p) in sorted(types().items()):
            if "1x" in n:
                print(f"{n:24s} ${p:.2f}/h  {regs}")
    elif a.cmd == "launch":
        launch(a.want.split(","), a.poll_minutes, Path(a.keydir))
    elif a.cmd == "status":
        st = load_state()
        print(st)
        if st.get("instance_id"):
            print(call("GET", f"/instances/{st['instance_id']}").get("data", {}).get("status"))
    else:
        terminate()
