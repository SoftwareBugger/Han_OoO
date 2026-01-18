#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

def bin_to_hex_words(in_path: Path, out_path: Path) -> int:
    data = in_path.read_bytes()
    if len(data) % 4:
        data += b"\x00" * (4 - (len(data) % 4))

    with out_path.open("w") as f:
        for i in range(0, len(data), 4):
            w = struct.unpack_from("<I", data, i)[0]
            f.write(f"{w:08x}\n")

    return len(data) // 4

def main():
    if len(sys.argv) != 3:
        print("Usage: hexify.py <in.bin> <out.hex>")
        sys.exit(2)

    in_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    nwords = bin_to_hex_words(in_path, out_path)
    print(f"Wrote {out_path} words={nwords}")

if __name__ == "__main__":
    main()
