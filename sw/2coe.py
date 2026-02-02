#!/usr/bin/env python3
import argparse
from pathlib import Path

def hex_to_coe(hex_path, out_dir, radix=16, word_width=None):
    hex_path = Path(hex_path)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    coe_path = out_dir / (hex_path.stem + ".coe")

    values = []
    with open(hex_path, "r") as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue

            if line.lower().startswith("0x"):
                line = line[2:]

            if word_width:
                line = line.zfill(word_width)

            try:
                int(line, radix)
            except ValueError:
                raise ValueError(f"{hex_path}: invalid hex on line {i+1}: {line}")

            values.append(line.lower())

    with open(coe_path, "w") as f:
        f.write(f"; Generated from {hex_path.name}\n")
        f.write(f"memory_initialization_radix={radix};\n")
        f.write("memory_initialization_vector=\n")
        for i, v in enumerate(values):
            f.write(v + (",\n" if i != len(values) - 1 else "\n"))
        f.write(";\n")

    print(f"[OK] {hex_path.name} → {coe_path}")

def main():
    parser = argparse.ArgumentParser(description="Convert hex files to Xilinx .coe")
    parser.add_argument("hex_files", nargs="+", help="Input .hex files (wildcards OK)")
    parser.add_argument("out_dir", help="Output directory for .coe files")
    parser.add_argument("--width", type=int, default=None, help="Hex word width (e.g. 8 for 32-bit)")
    args = parser.parse_args()

    for hex_file in args.hex_files:
        hex_to_coe(hex_file, args.out_dir, word_width=args.width)

if __name__ == "__main__":
    main()
