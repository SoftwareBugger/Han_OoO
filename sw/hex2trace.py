import os, sys, glob

# Add repo root to sys.path (works no matter where you run from)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, REPO_ROOT)

from test.rv32i_tests_gen import simulate_commit_trace_from_hex, write_commit_trace

def main():
    # Where your .hex live (default: sw/build/*.hex)
    here = os.path.dirname(os.path.abspath(__file__))
    default_glob = os.path.join(here, "build", "*.hex")

    pattern = sys.argv[1] if len(sys.argv) >= 2 else default_glob
    max_steps = int(sys.argv[2]) if len(sys.argv) >= 3 else 300000

    hex_paths = sorted(glob.glob(pattern))
    if not hex_paths:
        print(f"No .hex files matched: {pattern}")
        sys.exit(1)

    out_dir = os.path.join(here, "golden_traces")
    os.makedirs(out_dir, exist_ok=True)

    index_path = os.path.join(out_dir, "index.txt")
    with open(index_path, "w") as idx:
        idx.write(f"# pattern={pattern}\n")
        idx.write(f"# max_steps={max_steps}\n")
        idx.write("# name  trace_file  final_x31\n")

        for hp in hex_paths:
            name = os.path.splitext(os.path.basename(hp))[0]
            out_trace = os.path.join(out_dir, f"{name}.truth")

            print(f"[hex2trace] {name}: {hp} -> {out_trace}")

            trace, regs = simulate_commit_trace_from_hex(hp, max_steps=max_steps)
            write_commit_trace(out_trace, trace)

            final_x31 = regs[31] & 0xFFFFFFFF
            idx.write(f"{name}  {os.path.basename(out_trace)}  0x{final_x31:08x}\n")

    print(f"Done. Wrote traces to: {out_dir}")
    print(f"Index: {index_path}")

if __name__ == "__main__":
    main()
