#!/usr/bin/env python3
"""check_redirect.py

Checks *control-flow* of your frontend trace:
- Detects REDIRECT events in fetch_trace.log
- Verifies that within MAX_LAT decoded uops, a line appears with PC==redirect_target

It does NOT care about op/rs1/rs2/imm at all (use your existing check_log.py for that).

Usage:
  python check_redirect.py fetch_trace.log
"""

import re
import sys
from dataclasses import dataclass

MAX_LAT = 3  # must match tb_fetch_redirect.sv

RE_PC = re.compile(r"\bPC=([0-9a-fA-F]{8})\b")
RE_REDIRECT = re.compile(r"^REDIRECT\s+to=([0-9a-fA-F]{8})\s*$")

@dataclass
class Pending:
    tgt: int
    budget: int


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "fetch_trace.log"

    pend: Pending | None = None
    total_uops = 0
    redirects = 0

    with open(path, "r") as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()

            m = RE_REDIRECT.match(line)
            if m:
                tgt = int(m.group(1), 16)
                if pend is not None:
                    print(f"ERROR: redirect at line {ln} while previous redirect still pending (tgt={pend.tgt:08x}).")
                    return 2
                pend = Pending(tgt=tgt, budget=MAX_LAT)
                redirects += 1
                continue

            m = RE_PC.search(line)
            if not m:
                continue

            pc = int(m.group(1), 16)
            total_uops += 1

            if pend is not None:
                if pc == pend.tgt:
                    # success
                    pend = None
                else:
                    pend.budget -= 1
                    if pend.budget < 0:
                        print(f"FAIL: Did not observe redirected PC={pend.tgt:08x} within {MAX_LAT} decoded uops after redirect")
                        return 1

    if pend is not None:
        print(f"FAIL: log ended while redirect to PC={pend.tgt:08x} still pending")
        return 1

    print(f"✓ Redirect behavior looks OK ({redirects} redirect events checked, {total_uops} decoded uops scanned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
