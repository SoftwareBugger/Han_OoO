#!/usr/bin/env python3
"""
hex2banks_coe.py

Split a hex memory image into 8 byte-lane COE files (bank0..bank7).

Mapping:
  byte 0 -> bank0
  byte 1 -> bank1
  ...
  byte 7 -> bank7
  byte 8 -> bank0
  ...

Input formats supported:
  1) Plain 32-bit-per-line hex: each line like "DEADBEEF" (optionally with 0x prefix)
  2) $readmemh-style address directives: lines like "@00001000" set the NEXT write address
     (interpreted as BYTE address unless --addr-unit word is used)

Endianness:
  For each 32-bit word line, you can choose whether the line represents:
    --endian little  : bytes = [b0, b1, b2, b3] from least significant to most (default)
    --endian big     : bytes = [b3, b2, b1, b0]

Outputs:
  <out_dir>/<stem>_bank0.coe ... <stem>_bank7.coe

COE format:
  memory_initialization_radix=16;
  memory_initialization_vector=
  00,
  1f,
  ...
  ab;
"""

from __future__ import annotations
import argparse
import glob
import os
import re
from pathlib import Path
from typing import List, Tuple

HEX_RE = re.compile(r'^[0-9a-fA-F]+$')

def parse_word32_line_to_bytes(line_hex: str, endian: str) -> List[int]:
    s = line_hex.strip()
    if s.startswith("0x") or s.startswith("0X"):
        s = s[2:]
    # allow shorter than 8? left-pad to 8
    if len(s) > 8:
        raise ValueError(f"Expected <=8 hex chars for 32-bit word, got {len(s)}: {s}")
    s = s.zfill(8)
    word = int(s, 16)
    b0 = (word >> 0) & 0xFF
    b1 = (word >> 8) & 0xFF
    b2 = (word >> 16) & 0xFF
    b3 = (word >> 24) & 0xFF
    if endian == "little":
        return [b0, b1, b2, b3]
    else:
        return [b3, b2, b1, b0]

def write_coe_byte_file(path: Path, byte_values: List[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        n = len(byte_values)
        for i, b in enumerate(byte_values):
            sep = "," if i != n - 1 else ";"
            f.write(f"{b:02x}{sep}\n")

def read_hex_image_as_byte_stream(
    hex_path: Path,
    endian: str,
    addr_unit: str,
) -> List[int]:
    """
    Returns a byte stream where directives can create holes (filled with 0).
    addr_unit:
      - "byte": @ADDR interpreted as byte address (default)
      - "word": @ADDR interpreted as 32-bit word address (ADDR*4 bytes)
    """
    mem: List[int] = []
    cur_byte_addr = 0

    def ensure_len(byte_addr: int) -> None:
        nonlocal mem
        if byte_addr > len(mem):
            mem.extend([0] * (byte_addr - len(mem)))

    with hex_path.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            # strip comments (common styles)
            line = line.split("//", 1)[0].split("#", 1)[0].strip()
            if not line:
                continue

            if line.startswith("@"):
                addr_hex = line[1:].strip()
                if not addr_hex or not HEX_RE.match(addr_hex):
                    raise ValueError(f"{hex_path}: bad address directive: {raw.rstrip()}")
                addr = int(addr_hex, 16)
                if addr_unit == "word":
                    addr *= 4
                cur_byte_addr = addr
                ensure_len(cur_byte_addr)
                continue

            # Accept pure hex tokens; if line has multiple tokens, split and parse each
            tokens = line.replace(",", " ").split()
            for tok in tokens:
                tok = tok.strip()
                if tok.startswith("0x") or tok.startswith("0X"):
                    tok2 = tok[2:]
                else:
                    tok2 = tok
                if not tok2:
                    continue
                if not HEX_RE.match(tok2):
                    # ignore weird tokens rather than crashing hard
                    raise ValueError(f"{hex_path}: non-hex token '{tok}' in line: {raw.rstrip()}")
                # Treat each token as one 32-bit word (<=8 hex chars)
                bytes_ = parse_word32_line_to_bytes(tok2, endian=endian)
                ensure_len(cur_byte_addr)
                # write bytes into mem at current address
                ensure_len(cur_byte_addr + len(bytes_))
                for b in bytes_:
                    mem[cur_byte_addr] = b
                    cur_byte_addr += 1

    return mem

def split_into_8_banks(byte_stream: List[int]) -> List[List[int]]:
    banks = [[] for _ in range(8)]
    for idx, b in enumerate(byte_stream):
        banks[idx % 8].append(b)
    return banks

def process_one(hex_file: Path, out_dir: Path, endian: str, addr_unit: str) -> None:
    byte_stream = read_hex_image_as_byte_stream(hex_file, endian=endian, addr_unit=addr_unit)
    banks = split_into_8_banks(byte_stream)

    stem = hex_file.stem
    for i in range(8):
        out_path = out_dir / f"{stem}_bank{i}.coe"
        write_coe_byte_file(out_path, banks[i])
    print(f"[ok] {hex_file} -> {out_dir}/{stem}_bank0..7.coe  (bytes={len(byte_stream)})")

def expand_inputs(inputs: List[str]) -> List[Path]:
    files: List[Path] = []
    for pat in inputs:
        matches = glob.glob(pat)
        if matches:
            files.extend(Path(m) for m in matches)
        else:
            # allow direct path without glob expansion
            p = Path(pat)
            if p.exists():
                files.append(p)
            else:
                raise FileNotFoundError(f"No matches for: {pat}")
    # de-dup while preserving order
    seen = set()
    uniq: List[Path] = []
    for p in files:
        rp = str(p.resolve())
        if rp not in seen:
            seen.add(rp)
            uniq.append(p)
    return uniq

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+",
                    help="Input .hex file(s) or globs (e.g. build/*.hex)")
    ap.add_argument("-o", "--out-dir", default="coe_banks",
                    help="Output directory (default: coe_banks)")
    ap.add_argument("--endian", choices=["little", "big"], default="little",
                    help="How to interpret each 32-bit hex word line (default: little)")
    ap.add_argument("--addr-unit", choices=["byte", "word"], default="byte",
                    help="Meaning of @ADDR directives (default: byte)")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    in_files = expand_inputs(args.inputs)
    for hf in in_files:
        process_one(hf, out_dir=out_dir, endian=args.endian, addr_unit=args.addr_unit)

if __name__ == "__main__":
    main()
