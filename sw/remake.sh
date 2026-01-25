#!/usr/bin/env bash
set -euo pipefail

# Always run from the script's directory (so paths are stable)
cd "$(dirname "$0")"

# Optional: clear sim trace
rm -f "C:/RTL/Han_OoO/test/periph.jsonl" || true

# ---- Pick a RISC-V toolchain prefix that exists on your machine ----
if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
  CROSS="riscv64-unknown-elf"
elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
  CROSS="riscv32-unknown-elf"
elif command -v riscv32-xilinx-elf-gcc >/dev/null 2>&1; then
  CROSS="riscv32-xilinx-elf"
else
  echo "ERROR: No RISC-V GCC found in PATH."
  echo "Tried: riscv64-unknown-elf-gcc, riscv32-unknown-elf-gcc, riscv32-xilinx-elf-gcc"
  exit 1
fi

echo "[remake] Using CROSS=$CROSS"

# Build (stop immediately if it fails)
make clean
make CROSS="$CROSS"

# Convert generated hex -> coe outputs (only if hex exists)
shopt -s nullglob
hex_files=(build/*.hex)
shopt -u nullglob

if ((${#hex_files[@]} == 0)); then
  echo "ERROR: No build/*.hex produced. Build failed or Makefile didn't generate hex."
  exit 1
fi

python3 2coe.py "${hex_files[@]}" coe_file/
python3 hex2banks_coe.py "${hex_files[@]}" coe_banks/

echo "[remake] Done."
