#!/usr/bin/env python3
import argparse
from pathlib import Path

def bin_to_words_le(b: bytes) -> list[int]:
    # pad to multiple of 4
    if len(b) % 4:
        b += b"\x00" * (4 - (len(b) % 4))
    words = []
    for i in range(0, len(b), 4):
        words.append(int.from_bytes(b[i:i+4], "little", signed=False))
    return words

def words_to_hex_lines(words: list[int]) -> str:
    return "\n".join(f"{w:08x}" for w in words) + ("\n" if words else "")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("in_bin")
    ap.add_argument("out_hex")
    ap.add_argument("--strip-trailing-zeros", action="store_true",
                    help="Remove trailing 0x00000000 words (common for padded memories)")
    ap.add_argument("--limit", type=int, default=0,
                    help="Only write first N words (0 = all)")
    ap.add_argument("--selfcheck", action="store_true",
                    help="Also write a .sha256 file for the input bin to help cross-machine comparison")
    args = ap.parse_args()

    in_bin = Path(args.in_bin)
    out_hex = Path(args.out_hex)

    b = in_bin.read_bytes()
    words = bin_to_words_le(b)

    if args.strip_trailing_zeros:
        while words and words[-1] == 0:
            words.pop()

    if args.limit and args.limit > 0:
        words = words[:args.limit]

    out_hex.write_text(words_to_hex_lines(words), encoding="ascii", newline="\n")

    print(f"Wrote {out_hex} words={len(words)} bytes_in={len(b)}")

    if args.selfcheck:
        import hashlib
        h = hashlib.sha256(b).hexdigest()
        (out_hex.with_suffix(out_hex.suffix + ".bin.sha256")).write_text(h + "\n", encoding="ascii")
        print(f"Wrote {out_hex}.bin.sha256")

if __name__ == "__main__":
    main()
