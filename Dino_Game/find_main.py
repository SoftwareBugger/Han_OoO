#!/usr/bin/env python3
import re
import sys
from pathlib import Path

# Heuristic: match a *definition* of main (not just a prototype)
# - starts at line beginning (allow whitespace)
# - return type-ish tokens then main(
# - and eventually a '{' either on same line or a later line
main_sig = re.compile(r'^\s*(?:int|void)\s+main\s*\(', re.M)

def has_main_def(text: str) -> bool:
    m = main_sig.search(text)
    if not m:
        return False
    # If "{" is on same line or within the next few lines, treat as definition.
    # (Avoid false positives from prototypes.)
    start = m.start()
    snippet = text[start:start + 400]
    return "{" in snippet

def main(argv):
    out = []
    for f in argv[1:]:
        p = Path(f)
        try:
            txt = p.read_text(errors="ignore")
        except Exception:
            continue
        if has_main_def(txt):
            out.append(f)
    sys.stdout.write(" ".join(out))

if __name__ == "__main__":
    main(sys.argv)
