#!/usr/bin/env python3
import json
import re
import argparse
from typing import Dict, List, Optional, Tuple

# -----------------------------
# Parsing
# -----------------------------

GOLD_LINE_RE = re.compile(
    r"^\s*(\d+)\s+([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+(x\d+)\s+([0-9a-fA-F]{8})\s+(.*)$"
)

def parse_gold_trace(path: str) -> List[Dict]:
    out = []
    with open(path, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            m = GOLD_LINE_RE.match(line)
            if not m:
                continue
            cyc = int(m.group(1))
            pc  = int(m.group(2), 16)
            inst = int(m.group(3), 16)
            rd  = int(m.group(4)[1:])   # x01 -> 1
            data = int(m.group(5), 16)
            asm = m.group(6)
            out.append({
                "idx": len(out),
                "cycle": cyc,
                "pc": pc,
                "inst": inst,
                "rd": rd,
                "data": data,
                "asm": asm,
                "raw": line,
            })
    return out

def _hex_to_int(x) -> int:
    if isinstance(x, int):
        return x
    if isinstance(x, str):
        x = x.strip()
        if x.startswith("0x") or x.startswith("0X"):
            return int(x, 16)
        # allow bare hex like "00000004"
        try:
            return int(x, 16)
        except ValueError:
            return int(x)
    return int(x)

def parse_commit_jsonl(path: str) -> Tuple[List[Dict], int]:
    out = []
    bad = 0
    with open(path, "r") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                bad += 1
                continue

            # filter for commits
            if obj.get("type") not in (None, "commit"):
                continue
            if int(obj.get("valid", 1)) == 0:
                continue

            pc = _hex_to_int(obj.get("pc", 0))
            data = _hex_to_int(obj.get("data", 0))

            uses_rd = int(obj.get("uses_rd", 0))
            rd_arch = int(obj.get("rd_arch", 0))
            rd = rd_arch if uses_rd else 0

            out.append({
                "idx": len(out),
                "cycle": obj.get("cycle", None),
                "pc": pc,
                "rd": rd,
                "data": data,
                "is_branch": int(obj.get("is_branch", 0)),
                "mispredict": int(obj.get("mispredict", 0)),
                "epoch": obj.get("epoch", None),
                "global_epoch": obj.get("global_epoch", None),
                "raw": obj,
                "lineno": lineno,
            })
    return out, bad

# -----------------------------
# Diffing
# -----------------------------

def key(rec: Dict) -> Tuple[int, int, int]:
    return (rec["pc"], rec["rd"], rec["data"])

def fmt_pc(pc: int) -> str:
    return f"0x{pc:08x}"

def fmt_rd(rd: int) -> str:
    return f"x{rd}"

def show_window(gold: List[Dict], sim: List[Dict], center: int, radius: int) -> str:
    lines = []
    start = max(0, center - radius)
    end   = min(len(gold), center + radius + 1)
    for i in range(start, end):
        g = gold[i]
        s = sim[i] if i < len(sim) else None
        lines.append(f"[{i:4d}] GOLD pc={fmt_pc(g['pc'])} rd={fmt_rd(g['rd']):>4} data=0x{g['data']:08x}  asm={g['asm']}")
        if s is None:
            lines.append(f"      SIM  <no entry>")
        else:
            lines.append(f"      SIM  pc={fmt_pc(s['pc'])} rd={fmt_rd(s['rd']):>4} data=0x{s['data']:08x}  cycle={s['cycle']}")
    return "\n".join(lines)

def diff_first(gold: List[Dict], sim: List[Dict]) -> Optional[int]:
    n = min(len(gold), len(sim))
    for i in range(n):
        if key(gold[i]) != key(sim[i]):
            return i
    # if all common prefix matches but lengths differ
    if len(sim) != len(gold):
        return n
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, help="golden trace txt")
    ap.add_argument("--sim", required=True, help="commit.jsonl")
    ap.add_argument("--radius", type=int, default=6, help="context window size")
    args = ap.parse_args()

    gold = parse_gold_trace(args.gold)
    sim, bad = parse_commit_jsonl(args.sim)

    print(f"Gold commits: {len(gold)}")
    print(f"Sim  commits: {len(sim)} (bad json lines skipped={bad})")

    i = diff_first(gold, sim)
    if i is None:
        print("✅ Perfect match (same length, identical (pc,rd,data) sequence).")
        return

    if i == min(len(gold), len(sim)) and len(sim) < len(gold):
        last = sim[-1] if sim else None
        print("\n❌ SIM ENDED EARLY (processor likely blocked).")
        if last:
            print(f"Last SIM commit idx={last['idx']} pc={fmt_pc(last['pc'])} rd={fmt_rd(last['rd'])} data=0x{last['data']:08x} cycle={last['cycle']}")
        nxt = gold[i] if i < len(gold) else None
        if nxt:
            print(f"Next GOLD expected idx={i} pc={fmt_pc(nxt['pc'])} rd={fmt_rd(nxt['rd'])} data=0x{nxt['data']:08x} asm={nxt['asm']}")
        print("\nContext:")
        print(show_window(gold, sim, max(0, i-1), args.radius))
        return

    print(f"\n❌ FIRST MISMATCH at commit idx={i}")
    g = gold[i] if i < len(gold) else None
    s = sim[i] if i < len(sim) else None
    if g:
        print(f"GOLD: pc={fmt_pc(g['pc'])} rd={fmt_rd(g['rd'])} data=0x{g['data']:08x} asm={g['asm']}")
    if s:
        print(f" SIM: pc={fmt_pc(s['pc'])} rd={fmt_rd(s['rd'])} data=0x{s['data']:08x} cycle={s['cycle']} lineno={s['lineno']}")
    print("\nContext:")
    print(show_window(gold, sim, i, args.radius))

if __name__ == "__main__":
    main()
