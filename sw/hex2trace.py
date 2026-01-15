import os, sys

# Add repo root to sys.path (works no matter where you run from)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, REPO_ROOT)

from test.rv32i_tests_gen import simulate_commit_trace_from_hex, write_commit_trace


trace, regs = simulate_commit_trace_from_hex("prog.hex", max_steps=200000)
write_commit_trace("golden_trace.txt", trace)
print("final x31 =", hex(regs[31]))
