#!/usr/bin/env python3
import argparse
import glob
import os
import re
import sys
import tempfile
from typing import List, Optional


# IMPORTANT: keep the same imports as your original hex2trace.py
from rv32i_tests_gen import simulate_commit_trace_from_hex, write_commit_trace

VALID_RV32I_OPCODES = {
    0x37,  # LUI
    0x17,  # AUIPC
    0x6F,  # JAL
    0x67,  # JALR
    0x63,  # BRANCH
    0x03,  # LOAD
    0x23,  # STORE
    0x13,  # OP-IMM
    0x33,  # OP
    0x0F,  # MISC-MEM
    0x73,  # SYSTEM
}

def parse_hex_words(path: str) -> List[int]:
    words: List[int] = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            line = line.split("#", 1)[0].strip()
            line = line.split("//", 1)[0].strip()
            if not line:
                continue
            if not re.fullmatch(r"[0-9a-fA-F]+", line):
                raise RuntimeError(f"{path}: unsupported hex line format: {line!r}")
            words.append(int(line, 16) & 0xFFFFFFFF)
    return words

def looks_like_code_word(w: int) -> bool:
    op = w & 0x7F
    if op not in VALID_RV32I_OPCODES:
        return False
    if w in (0x00000000, 0xFFFFFFFF):
        return False
    return True

def decide_is_legacy_app_at_0(app_words: List[int], app_base_words: int) -> bool:
    """
    Legacy tests: code starts at word 0.
    SoC apps: code starts at word app_base_words (0x2000/4=2048).
    """
    code0 = (len(app_words) > 0) and looks_like_code_word(app_words[0])
    codeb = (len(app_words) > app_base_words) and looks_like_code_word(app_words[app_base_words])
    return bool(code0 and not codeb)

def write_merged_hex(boot_words: List[int], app_words: List[int], app_base_words: int) -> str:
    total_words = max(len(boot_words), app_base_words + len(app_words))
    merged = [0] * total_words
    for i, w in enumerate(boot_words):
        merged[i] = w
    for i, w in enumerate(app_words):
        merged[app_base_words + i] = w

    fd, path = tempfile.mkstemp(prefix="hex2trace_merged_", suffix=".hex")
    os.close(fd)
    with open(path, "w") as f:
        for w in merged:
            f.write(f"{w:08x}\n")
    return path

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("hex_glob", nargs="?", default=None,
                    help="Hex file or glob (default: sw/build/*.hex)")
    ap.add_argument("max_steps", nargs="?", type=int, default=3_000_000,
                    help="Max simulation steps (default: 3000000)")
    ap.add_argument("--boot", default=None,
                    help="Boot hex loaded at 0x0 (optional). If provided, SoC apps are merged.")
    ap.add_argument("--app-base", default="0x2000",
                    help="App load base in bytes (default: 0x2000)")
    ap.add_argument("--include-boot", action="store_true",
                    help="Also generate trace for boot.hex itself (normally skipped)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    default_glob = os.path.join(here, "build", "*.hex")
    pattern = args.hex_glob if args.hex_glob is not None else default_glob

    app_base = int(args.app_base, 0)
    if (app_base % 4) != 0:
        raise RuntimeError("--app-base must be 4-byte aligned")
    app_base_words = app_base // 4

    hex_paths = sorted(glob.glob(pattern))
    if not hex_paths:
        print(f"No .hex files matched: {pattern}")
        sys.exit(1)

    out_dir = os.path.join(here, "golden_traces")
    os.makedirs(out_dir, exist_ok=True)

    boot_words: Optional[List[int]] = None
    boot_norm = os.path.normpath(args.boot) if args.boot else None
    if args.boot:
        boot_words = parse_hex_words(args.boot)

    index_path = os.path.join(out_dir, "index.txt")
    with open(index_path, "w") as idx:
        idx.write(f"# pattern={pattern}\n")
        idx.write(f"# max_steps={args.max_steps}\n")
        if args.boot:
            idx.write(f"# boot={args.boot}\n")
            idx.write(f"# app_base=0x{app_base:08x}\n")
        idx.write("# name  trace_file  final_x31\n")

        for hp in hex_paths:
            if (not args.include_boot) and boot_norm and os.path.normpath(hp) == boot_norm:
                continue

            name = os.path.splitext(os.path.basename(hp))[0]
            out_trace = os.path.join(out_dir, f"{name}.truth")

            app_words = parse_hex_words(hp)

            # Decide whether to run as legacy or merged SoC image
            sim_hex = hp
            note = "(no boot)"
            merged_temp = None

            if boot_words is not None:
                if decide_is_legacy_app_at_0(app_words, app_base_words):
                    sim_hex = hp
                    note = "(legacy app@0x0; boot ignored)"
                else:
                    merged_temp = write_merged_hex(boot_words, app_words, app_base_words)
                    sim_hex = merged_temp
                    note = f"(merged boot={args.boot} @0x0, app_base=0x{app_base:08x})"

            print(f"[hex2trace] {name}: {hp} -> {out_trace}")
            print(f"           {note}")

            trace, regs = simulate_commit_trace_from_hex(sim_hex, max_steps=args.max_steps)

            # IMPORTANT: CommitEntry list -> file using the project's serializer
            write_commit_trace(out_trace, trace)

            final_x31 = regs[31] & 0xFFFFFFFF
            idx.write(f"{name}  {os.path.basename(out_trace)}  0x{final_x31:08x}\n")

            if merged_temp:
                try:
                    os.remove(merged_temp)
                except OSError:
                    pass

    print(f"Done. Wrote traces to: {out_dir}")
    print(f"Index: {index_path}")

if __name__ == "__main__":
    main()
