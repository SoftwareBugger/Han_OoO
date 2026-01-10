#!/usr/bin/env python3
# rv32i_tests_gen.py
# Small, deterministic RV32I test programs (arith/logic/shift/compare) that emit:
#   - <out>.hex   : one 32-bit word per line, hex (readmemh style)
#   - <out>.S     : PC + hex + assembly listing for debug + per-insn ground-truth comment
#   - <out>.truth : ground-truth log (final regs + per-insn effects)
#
# Usage:
#   python rv32i_tests_gen.py --list
#   python rv32i_tests_gen.py --test add_sub --out prog
#   python rv32i_tests_gen.py --test chain --out chain_prog
#
# Based on the encoding helpers from insn_gen.py (user-provided).  fileciteturn0file0

from __future__ import annotations
from dataclasses import dataclass
from typing import List, Dict, Callable, Tuple, Optional
import argparse

def mask(n, bits): return n & ((1 << bits) - 1)

def encode_R(opcode, rd, funct3, rs1, rs2, funct7):
    return ((mask(funct7,7) << 25) |
            (mask(rs2,5)   << 20) |
            (mask(rs1,5)   << 15) |
            (mask(funct3,3)<< 12) |
            (mask(rd,5)    << 7)  |
            mask(opcode,7))

def encode_I(opcode, rd, funct3, rs1, imm):
    imm12 = mask(imm, 12)
    return ((imm12          << 20) |
            (mask(rs1,5)    << 15) |
            (mask(funct3,3) << 12) |
            (mask(rd,5)     << 7)  |
            mask(opcode,7))

# -------------------------
# RV32I instruction encoders
# -------------------------
def NOP(): return encode_I(0x13, 0, 0x0, 0, 0)  # addi x0,x0,0

# I-type ALU
def ADDI(rd, rs1, imm):  return encode_I(0x13, rd, 0x0, rs1, imm)
def SLTI(rd, rs1, imm):  return encode_I(0x13, rd, 0x2, rs1, imm)
def SLTIU(rd, rs1, imm): return encode_I(0x13, rd, 0x3, rs1, imm)
def XORI(rd, rs1, imm):  return encode_I(0x13, rd, 0x4, rs1, imm)
def ORI(rd, rs1, imm):   return encode_I(0x13, rd, 0x6, rs1, imm)
def ANDI(rd, rs1, imm):  return encode_I(0x13, rd, 0x7, rs1, imm)
def SLLI(rd, rs1, sh):   return encode_I(0x13, rd, 0x1, rs1, sh)  # funct7=0 implicit
def SRLI(rd, rs1, sh):   return encode_I(0x13, rd, 0x5, rs1, sh)  # funct7=0 implicit
def SRAI(rd, rs1, sh):   return encode_I(0x13, rd, 0x5, rs1, (0x20 << 5) | (sh & 0x1F))

# R-type ALU
def ADD(rd, rs1, rs2):  return encode_R(0x33, rd, 0x0, rs1, rs2, 0x00)
def SUB(rd, rs1, rs2):  return encode_R(0x33, rd, 0x0, rs1, rs2, 0x20)
def SLL(rd, rs1, rs2):  return encode_R(0x33, rd, 0x1, rs1, rs2, 0x00)
def SLT(rd, rs1, rs2):  return encode_R(0x33, rd, 0x2, rs1, rs2, 0x00)
def SLTU(rd, rs1, rs2): return encode_R(0x33, rd, 0x3, rs1, rs2, 0x00)
def XOR(rd, rs1, rs2):  return encode_R(0x33, rd, 0x4, rs1, rs2, 0x00)
def SRL(rd, rs1, rs2):  return encode_R(0x33, rd, 0x5, rs1, rs2, 0x00)
def SRA(rd, rs1, rs2):  return encode_R(0x33, rd, 0x5, rs1, rs2, 0x20)
def OR(rd, rs1, rs2):   return encode_R(0x33, rd, 0x6, rs1, rs2, 0x00)
def AND(rd, rs1, rs2):  return encode_R(0x33, rd, 0x7, rs1, rs2, 0x00)

# -------------------------
# Output helpers
# -------------------------
def write_hex(path: str, words: List[int]):
    """Pure readmemh content: one 32-bit word per line."""
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")

def write_asm_with_gt(path: str, asm_lines: List[str], words: List[int], gt_lines: List[str]):
    with open(path, "w") as f:
        pc = 0
        for a, w, gt in zip(asm_lines, words, gt_lines):
            # Ground-truth appended as a comment; keep the listing readable.
            f.write(f"{pc:08x}: {w:08x}    {a:<28s}  # {gt}\n")
            pc += 4

def write_truth(path: str, truth_lines: List[str], final_regs: List[int]):
    with open(path, "w") as f:
        for line in truth_lines:
            f.write(line + "\n")
        f.write("\nFINAL REGFILE (x0..x31):\n")
        for i in range(32):
            f.write(f"x{i:02d} = 0x{final_regs[i] & 0xFFFFFFFF:08x}\n")

# -------------------------
# Ground-truth model (subset RV32I used by these tests)
# -------------------------
def sext(val: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    val &= (1 << bits) - 1
    return (val ^ sign) - sign

def u32(x: int) -> int:
    return x & 0xFFFFFFFF

def s32(x: int) -> int:
    x = u32(x)
    return x - 0x100000000 if x & 0x80000000 else x

@dataclass
class Meta:
    op: str
    rd: int = 0
    rs1: int = 0
    rs2: int = 0
    imm: int = 0  # also used for shamt in I-shifts

def simulate(words: List[int], meta: List[Meta], asm_lines: List[str]):
    regs = [0] * 32
    gt_lines: List[str] = []
    truth_lines: List[str] = []
    pc = 0

    for i, (w, m, asm) in enumerate(zip(words, meta, asm_lines)):
        op = m.op
        rd, rs1, rs2, imm = m.rd, m.rs1, m.rs2, m.imm

        def r(idx: int) -> int:
            return 0 if idx == 0 else regs[idx]

        old = regs[rd] if rd != 0 else 0

        new_val: Optional[int] = None
        expr: str = ""

        if op == "NOP":
            expr = "x0 stays 0"

        elif op == "ADDI":
            a = r(rs1)
            imm_se = sext(imm, 12)
            new_val = u32(a + imm_se)
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} + {imm_se:+d})"

        elif op == "ANDI":
            a = r(rs1)
            imm_u = imm & 0xFFF
            new_val = u32(a & imm_u)
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} & 0x{imm_u:03x})"

        elif op == "ORI":
            a = r(rs1)
            imm_u = imm & 0xFFF
            new_val = u32(a | imm_u)
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} | 0x{imm_u:03x})"

        elif op == "XORI":
            a = r(rs1)
            imm_u = imm & 0xFFF
            new_val = u32(a ^ imm_u)
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} ^ 0x{imm_u:03x})"

        elif op == "SLTI":
            a = s32(r(rs1))
            imm_se = sext(imm, 12)
            new_val = 1 if a < imm_se else 0
            expr = f"x{rd}=0x{new_val:08x} (s32(0x{u32(r(rs1)):08x}) < {imm_se})"

        elif op == "SLTIU":
            a = u32(r(rs1))
            imm_u = u32(sext(imm, 12))  # spec: imm is sign-extended then treated as unsigned
            new_val = 1 if a < imm_u else 0
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} <u 0x{imm_u:08x})"

        elif op == "SLLI":
            a = u32(r(rs1))
            sh = imm & 0x1F
            new_val = u32(a << sh)
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} << {sh})"

        elif op == "SRLI":
            a = u32(r(rs1))
            sh = imm & 0x1F
            new_val = u32(a >> sh)
            expr = f"x{rd}=0x{new_val:08x} (0x{a:08x} >> {sh})"

        elif op == "SRAI":
            a = s32(r(rs1))
            sh = imm & 0x1F
            new_val = u32(a >> sh)
            expr = f"x{rd}=0x{new_val:08x} (s32(0x{u32(r(rs1)):08x}) >>> {sh})"

        elif op in ("ADD","SUB","SLL","SRL","SRA","XOR","OR","AND","SLT","SLTU"):
            a_u = u32(r(rs1))
            b_u = u32(r(rs2))
            a_s = s32(r(rs1))
            b_s = s32(r(rs2))
            if op == "ADD":
                new_val = u32(a_u + b_u)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} + 0x{b_u:08x})"
            elif op == "SUB":
                new_val = u32(a_u - b_u)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} - 0x{b_u:08x})"
            elif op == "SLL":
                sh = b_u & 0x1F
                new_val = u32(a_u << sh)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} << (0x{b_u:08x}&31={sh}))"
            elif op == "SRL":
                sh = b_u & 0x1F
                new_val = u32(a_u >> sh)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} >> (0x{b_u:08x}&31={sh}))"
            elif op == "SRA":
                sh = b_u & 0x1F
                new_val = u32(a_s >> sh)
                expr = f"x{rd}=0x{new_val:08x} (s32(0x{a_u:08x}) >>> (0x{b_u:08x}&31={sh}))"
            elif op == "XOR":
                new_val = u32(a_u ^ b_u)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} ^ 0x{b_u:08x})"
            elif op == "OR":
                new_val = u32(a_u | b_u)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} | 0x{b_u:08x})"
            elif op == "AND":
                new_val = u32(a_u & b_u)
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} & 0x{b_u:08x})"
            elif op == "SLT":
                new_val = 1 if a_s < b_s else 0
                expr = f"x{rd}=0x{new_val:08x} (s32(0x{a_u:08x}) < s32(0x{b_u:08x}))"
            elif op == "SLTU":
                new_val = 1 if a_u < b_u else 0
                expr = f"x{rd}=0x{new_val:08x} (0x{a_u:08x} <u 0x{b_u:08x})"
        else:
            raise ValueError(f"simulate: unsupported op {op}")

        # Commit writeback (sequential model). x0 is hardwired to 0.
        if new_val is not None and rd != 0:
            regs[rd] = u32(new_val)

        # Keep x0 pinned.
        regs[0] = 0

        # Assemble per-line ground truth strings
        if rd == 0 and op not in ("NOP",):
            # explicit note that write is discarded
            gt = f"write x0 discarded; {expr.replace('x0=', 'x0 would be=') if expr else op}"
        else:
            gt = expr if expr else op

        gt_lines.append(gt)

        # Richer log line in .truth (includes old->new for rd)
        if new_val is not None and rd != 0:
            truth_lines.append(f"{pc:08x}: {asm:<28s}  | x{rd} {old & 0xFFFFFFFF:08x} -> {regs[rd]:08x} ; {gt}")
        else:
            truth_lines.append(f"{pc:08x}: {asm:<28s}  | (no arch write) ; {gt}")

        pc += 4

    return gt_lines, truth_lines, regs

# -------------------------
# Tiny assembler with auto-printed assembly + structured meta for GT
# -------------------------
def x(r: int) -> str:
    return f"x{r}"

class Asm:
    def __init__(self):
        self.words: List[int] = []
        self.asm:   List[str] = []
        self.meta:  List[Meta] = []

    def emit(self, w: int, asm: str, meta: Meta):
        self.words.append(w & 0xFFFFFFFF)
        self.asm.append(asm)
        self.meta.append(meta)

    # I-type
    def addi(self, rd, rs1, imm): self.emit(ADDI(rd, rs1, imm), f"addi {x(rd)}, {x(rs1)}, {imm}", Meta("ADDI", rd, rs1, 0, imm))
    def andi(self, rd, rs1, imm):
        s = f"andi {x(rd)}, {x(rs1)}, 0x{imm & 0xFFF:x}" if imm >= 0 else f"andi {x(rd)}, {x(rs1)}, {imm}"
        self.emit(ANDI(rd, rs1, imm), s, Meta("ANDI", rd, rs1, 0, imm))
    def ori (self, rd, rs1, imm):
        s = f"ori  {x(rd)}, {x(rs1)}, 0x{imm & 0xFFF:x}" if imm >= 0 else f"ori  {x(rd)}, {x(rs1)}, {imm}"
        self.emit(ORI(rd, rs1, imm), s, Meta("ORI", rd, rs1, 0, imm))
    def xori(self, rd, rs1, imm):
        s = f"xori {x(rd)}, {x(rs1)}, 0x{imm & 0xFFF:x}" if imm >= 0 else f"xori {x(rd)}, {x(rs1)}, {imm}"
        self.emit(XORI(rd, rs1, imm), s, Meta("XORI", rd, rs1, 0, imm))
    def slti(self, rd, rs1, imm): self.emit(SLTI(rd, rs1, imm), f"slti {x(rd)}, {x(rs1)}, {imm}", Meta("SLTI", rd, rs1, 0, imm))
    def sltiu(self, rd, rs1, imm): self.emit(SLTIU(rd, rs1, imm), f"sltiu {x(rd)}, {x(rs1)}, {imm}", Meta("SLTIU", rd, rs1, 0, imm))
    def slli(self, rd, rs1, sh):  self.emit(SLLI(rd, rs1, sh),  f"slli {x(rd)}, {x(rs1)}, {sh}", Meta("SLLI", rd, rs1, 0, sh))
    def srli(self, rd, rs1, sh):  self.emit(SRLI(rd, rs1, sh),  f"srli {x(rd)}, {x(rs1)}, {sh}", Meta("SRLI", rd, rs1, 0, sh))
    def srai(self, rd, rs1, sh):  self.emit(SRAI(rd, rs1, sh),  f"srai {x(rd)}, {x(rs1)}, {sh}", Meta("SRAI", rd, rs1, 0, sh))

    # R-type
    def add(self, rd, rs1, rs2):  self.emit(ADD(rd, rs1, rs2),  f"add  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("ADD", rd, rs1, rs2, 0))
    def sub(self, rd, rs1, rs2):  self.emit(SUB(rd, rs1, rs2),  f"sub  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("SUB", rd, rs1, rs2, 0))
    def _and(self, rd, rs1, rs2): self.emit(AND(rd, rs1, rs2),  f"and  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("AND", rd, rs1, rs2, 0))
    def _or(self, rd, rs1, rs2):  self.emit(OR(rd, rs1, rs2),   f"or   {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("OR",  rd, rs1, rs2, 0))
    def _xor(self, rd, rs1, rs2): self.emit(XOR(rd, rs1, rs2),  f"xor  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("XOR", rd, rs1, rs2, 0))
    def sll(self, rd, rs1, rs2):  self.emit(SLL(rd, rs1, rs2),  f"sll  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("SLL", rd, rs1, rs2, 0))
    def srl(self, rd, rs1, rs2):  self.emit(SRL(rd, rs1, rs2),  f"srl  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("SRL", rd, rs1, rs2, 0))
    def sra(self, rd, rs1, rs2):  self.emit(SRA(rd, rs1, rs2),  f"sra  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("SRA", rd, rs1, rs2, 0))
    def slt(self, rd, rs1, rs2):  self.emit(SLT(rd, rs1, rs2),  f"slt  {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("SLT", rd, rs1, rs2, 0))
    def sltu(self, rd, rs1, rs2): self.emit(SLTU(rd, rs1, rs2), f"sltu {x(rd)}, {x(rs1)}, {x(rs2)}", Meta("SLTU", rd, rs1, rs2, 0))

    def nop(self): self.emit(NOP(), "addi x0, x0, 0", Meta("NOP"))

    # -------------------------
    # Branchless "assert" helpers (encode mismatches into x31)
    # x31 becomes a sticky bitfield of failures (0 means pass).
    # We avoid branches/memory so this works in very small cores.
    def _accum_fail_bit(self, bitpos: int, diff_reg: int):
        # x20 = (diff_reg != 0) using sltu x20, x0, diff_reg
        # x21 = x20 << bitpos
        # x31 |= x21
        self.sltu(20, 0, diff_reg)
        self.slli(21, 20, bitpos)
        self._or(31, 31, 21)

    def assert_eq(self, bitpos: int, r_a: int, r_b: int, label: str = ""):
        # diff = a ^ b; if diff!=0 then set bitpos in x31
        # (label is for human readability in the .S file; no semantic effect)
        self._xor(22, r_a, r_b)   # x22 = a ^ b
        self._accum_fail_bit(bitpos, 22)
        if label:
            # emit a no-op to carry the comment in the listing (optional)
            self.emit(NOP(), f"addi x0, x0, 0  # ASSERT {label}", Meta("NOP"))

# -------------------------
# Test programs (no branches, no memory)
# -------------------------
def prog_add_sub(a: Asm):
    # x1=5; x2=7; x3=x1+x2=12; x4=x2-x1=2; x5=x4+x3=14
    a.addi(1, 0, 5)
    a.addi(2, 0, 7)
    a.add(3, 1, 2)
    a.sub(4, 2, 1)
    a.add(5, 4, 3)
    a.nop()

def prog_logic(a: Asm):
    # x1=0x55; x2=0x0f; x3=and=0x05; x4=or=0x5f; x5=xor=0x5a
    a.addi(1, 0, 0x55)
    a.addi(2, 0, 0x0F)
    a._and(3, 1, 2)
    a._or(4, 1, 2)
    a._xor(5, 1, 2)
    a.nop()

def prog_compare(a: Asm):
    # Signed vs unsigned compare
    a.addi(1, 0, -1)     # 0xffffffff
    a.addi(2, 0, 1)
    a.slt(3, 1, 2)       # 1
    a.sltu(4, 1, 2)      # 0
    a.nop()

def prog_shifts(a: Asm):
    a.addi(1, 0, 1)
    a.slli(2, 1, 5)      # 32
    a.srli(3, 2, 2)      # 8
    a.srai(4, 2, 2)      # 8
    a.addi(5, 0, -8)     # 0xfffffff8
    a.srai(6, 5, 1)      # -4
    a.srli(7, 5, 1)      # 0x7ffffffc
    a.nop()

def prog_chain(a: Asm):
    # Long dependency chain to stress wakeup/CDB/PRF
    a.addi(1, 0, 1)
    a.addi(2, 1, 1)
    a.addi(3, 2, 1)
    a.addi(4, 3, 1)
    a.addi(5, 4, 1)
    a.addi(6, 5, 1)
    a.addi(7, 6, 1)
    a.addi(8, 7, 1)
    a.nop()

def prog_ooo_pressure(a: Asm):
    # Independent ops that can issue out-of-order, then join
    a.addi(1, 0, 5)
    a.addi(2, 0, 6)
    a.addi(3, 0, 7)
    a.addi(4, 0, 8)
    a.add(5, 1, 2)      # 11
    a.add(6, 3, 4)      # 15
    a.add(7, 5, 6)      # 26
    a.nop()

def prog_x0_immutability(a: Asm):
    # Verify x0 stays 0 even if targeted as rd, and that ops using x0 behave correctly.
    a.addi(0, 0, 123)     # should do nothing
    a.addi(1, 0, 5)       # x1 = 5
    a.addi(0, 1, 7)       # should do nothing (attempt to write x0)
    a.add(2, 0, 1)        # x2 = 0 + 5 = 5
    a.sub(3, 0, 1)        # x3 = 0 - 5 = -5 (0xFFFFFFFB)
    a._or(4, 0, 1)        # x4 = 5
    a._and(5, 0, 1)       # x5 = 0
    a.nop()

def prog_imm12_edges(a: Asm):
    # Exercise sign-extension + boundary immediates in I-type ALU
    # imm range for RV32I I-type is [-2048, 2047]
    a.addi(1, 0, 2047)    # x1 = 0x000007FF
    a.addi(2, 0, -2048)   # x2 = 0xFFFFF800
    a.addi(3, 1, -1)      # x3 = 2046
    a.addi(4, 2, 1)       # x4 = -2047 (0xFFFFF801)
    a.andi(5, 2, 0x7FF)   # x5 = 0x00000000 (since x2 has low 11 bits = 0)
    a.ori (6, 0, 0x7FF)   # x6 = 0x000007FF
    a.xori(7, 6, -1)      # x7 = x6 ^ 0xFFF (imm masked)
    a.nop()

def prog_var_shifts(a: Asm):
    # Use R-type shifts where shamt comes from rs2[4:0]
    a.addi(1, 0, 1)       # x1 = 1
    a.addi(2, 0, 31)      # x2 = 31
    a.sll(3, 1, 2)        # x3 = 1 << 31 = 0x80000000
    a.addi(4, 0, 1)       # x4 = 1
    a.srl(5, 3, 4)        # x5 = 0x40000000
    a.sra(6, 3, 4)        # x6 = 0xC0000000 (arith shift keeps sign)
    a.addi(7, 0, 32)      # x7 = 32 -> masked to 0 in shamt[4:0]
    a.sll(8, 1, 7)        # x8 = 1 << 0 = 1
    a.nop()

def prog_waw_war_hazards(a: Asm):
    # Back-to-back redefinitions of the same architectural register + dependent reads.
    a.addi(1, 0, 10)      # x1 = 10
    a.addi(1, 1, 1)       # x1 = 11 (WAW on x1)
    a.addi(2, 1, 2)       # x2 = 13 (must see latest x1)
    a.addi(1, 0, 3)       # x1 = 3  (WAW again)
    a.add(3, 2, 1)        # x3 = 16 (must see x2=13 and latest x1=3)
    a.sub(4, 2, 1)        # x4 = 10
    a.nop()

def prog_compare_matrix(a: Asm):
    # Mixed signed/unsigned compare corner cases without branches.
    # We'll encode results into a small bitfield in x10.
    a.addi(1, 0, -1)      # a = 0xFFFFFFFF
    a.addi(2, 0, 1)       # b = 1
    a.slt(3, 1, 2)        # 1
    a.sltu(4, 1, 2)       # 0
    a.slt(5, 2, 1)        # 0
    a.sltu(6, 2, 1)       # 1

    a.addi(10, 0, 0)      # x10 = 0
    a.slli(4, 4, 1)       # bit1 -> position 1
    a.slli(5, 5, 2)       # bit2 -> position 2
    a.slli(6, 6, 3)       # bit3 -> position 3
    a._or(10, 10, 3)      # bit0
    a._or(10, 10, 4)
    a._or(10, 10, 5)
    a._or(10, 10, 6)
    # expected x10 = 0b1001 = 9
    a.nop()

def prog_alu_fuzz_deterministic(a: Asm):
    # Deterministic metamorphic ALU "fuzz" with no branches/memory.
    # x31 accumulates mismatch bits; expect x31 == 0.
    a.addi(31, 0, 0)

    # Seed base values
    a.addi(1, 0, 0x135)      # 0x00000135
    a.addi(2, 0, -123)       # 0xFFFFFF85
    a.addi(3, 0, 0x7ff)      # 0x000007FF
    a.addi(5, 0, 1)

    # (a ^ b) ^ b == a
    a._xor(6, 1, 2)
    a._xor(7, 6, 2)
    a.assert_eq(0, 7, 1, "(a^b)^b==a")

    # ORI imm=0 must be identity
    a.ori(8, 1, 0)
    a.assert_eq(1, 8, 1, "ORI imm=0")

    # SLLI == SLL when rs2=imm
    a.slli(9, 1, 13)
    a.addi(10, 0, 13)
    a.sll(11, 1, 10)
    a.assert_eq(2, 9, 11, "SLLI vs SLL")

    # SRLI == SRL when rs2=imm
    a.srli(12, 2, 7)
    a.addi(10, 0, 7)
    a.srl(13, 2, 10)
    a.assert_eq(3, 12, 13, "SRLI vs SRL")

    # SRAI == SRA when rs2=imm (negative operand)
    a.srai(14, 2, 5)
    a.addi(10, 0, 5)
    a.sra(15, 2, 10)
    a.assert_eq(4, 14, 15, "SRAI vs SRA (neg)")

    # (a+b)-b == a
    a.add(16, 1, 3)
    a.sub(17, 16, 3)
    a.assert_eq(5, 17, 1, "(a+b)-b==a")

    # x0 sink sanity
    a.addi(0, 1, 7)          # discarded
    a.add(18, 0, 1)          # must equal x1
    a.assert_eq(6, 18, 1, "x0 write discarded")

    # Masking: shift by 32 -> shift by 0
    a.addi(19, 0, 32)
    a.sll(20, 5, 19)         # 1 << 0 = 1
    a.assert_eq(7, 20, 5, "shamt masking 32->0")

    a.nop()

def prog_imm_signext_crosscheck(a: Asm):
    # Stress immediate sign-extension and SLTI/SLTIU semantics.
    # Accumulate mismatches into x31. Expect x31 == 0.
    a.addi(31, 0, 0)

    # (x + (-1)) == (x - 1)
    a.addi(1, 0, 100)
    a.addi(2, 1, -1)        # 99
    a.addi(3, 0, 1)
    a.sub(4, 1, 3)          # 99
    a.assert_eq(0, 2, 4, "ADDI -1 == SUB 1")

    # SLTI signed: (-5 < 0) == 1
    a.addi(5, 0, -5)
    a.slti(6, 5, 0)         # 1
    a.addi(7, 0, 1)
    a.assert_eq(1, 6, 7, "SLTI signed (-5<0)")

    # SLTIU uses sign-extended imm treated unsigned: imm=-1 => 0xFFFF_FFFF
    a.addi(8, 0, 1)
    a.sltiu(9, 8, -1)       # expect 1
    a.addi(7, 0, 1)
    a.assert_eq(2, 9, 7, "SLTIU imm=-1 (unsigned)")

    a.nop()

def prog_shift_crosscheck(a: Asm):
    # Cross-check imm vs reg shift behavior and masking.
    # Accumulate mismatch bits into x31. Expect x31 == 0 if ALU is correct.
    a.addi(31, 0, 0)        # failure accumulator

    a.addi(1, 0, 0x123)     # op_a positive
    a.addi(2, 0, 5)
    a.slli(3, 1, 5)
    a.sll(4, 1, 2)
    a.assert_eq(0, 3, 4, "SLLI==SLL sh=5")

    a.addi(2, 0, 7)
    a.srli(5, 1, 7)
    a.srl(6, 1, 2)
    a.assert_eq(1, 5, 6, "SRLI==SRL sh=7")

    a.addi(7, 0, -8)        # negative: 0xFFFFFFF8
    a.addi(2, 0, 3)
    a.srai(8, 7, 3)
    a.sra(9, 7, 2)
    a.assert_eq(2, 8, 9, "SRAI==SRA sh=3 (neg)")

    a.addi(10, 0, 1)
    a.addi(11, 0, 32)       # masked to 0 in RV32
    a.sll(12, 10, 11)       # should be 1
    a.addi(13, 0, 1)
    a.assert_eq(3, 12, 13, "SLL mask rs2[4:0]")

    a.nop()

TESTS: Dict[str, Tuple[str, Callable[[Asm], None]]] = {
    "add_sub": ("ADD/SUB + short deps (x1..x5 expected 5,7,12,2,14)", prog_add_sub),
    "logic":   ("AND/OR/XOR basic (x3=0x05 x4=0x5f x5=0x5a)", prog_logic),
    "compare": ("SLT vs SLTU signed/unsigned compare", prog_compare),
    "shifts":  ("SLLI/SRLI/SRAI + SRLI vs SRAI on negative", prog_shifts),
    "chain":   ("Long ADDI dependency chain (x8 should be 8)", prog_chain),
    "ooo":     ("Independent adds then join (x7 should be 26)", prog_ooo_pressure),
    "x0":      ("x0 immutability + ops with x0 (x0 stays 0)", prog_x0_immutability),
    "imm_edge":("imm12 boundaries/sign-ext (-2048..2047)", prog_imm12_edges),
    "vshift":  ("variable shifts via rs2 shamt masking", prog_var_shifts),
    "hazard":  ("WAW/WAR hazard stress on same rd", prog_waw_war_hazards),
    "cmpmat":  ("compare matrix packed into x10 (expect x10=9)", prog_compare_matrix),
    "fuzz":    ("Deterministic ALU fuzz + self-checks (expect x31=0)", prog_alu_fuzz_deterministic),
    "imm_se":  ("Immediate sign-extension + SLTI/SLTIU cross-checks (expect x31=0)", prog_imm_signext_crosscheck),
    "shift_cc":("Shift imm vs reg cross-checks (expect x31=0)", prog_shift_crosscheck),
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="List available tests")
    ap.add_argument("--test", type=str, default="add_sub", help="Which test to generate")
    ap.add_argument("--out", type=str, default="prog", help="Output prefix (writes <out>.hex, <out>.S, <out>.truth)")
    ap.add_argument("--pad", type=int, default=16, help="NOP padding words to append")
    args = ap.parse_args()

    if args.list:
        for k, (desc, _) in TESTS.items():
            print(f"{k:8s} - {desc}")
        return

    if args.test not in TESTS:
        raise SystemExit(f"Unknown --test '{args.test}'. Use --list.")

    a = Asm()
    TESTS[args.test][1](a)

    # NOP pad to avoid accidental fetch OOB in simple cores
    for _ in range(max(0, args.pad)):
        a.nop()

    # Ground-truth for this program (sequential reference)
    gt_lines, truth_lines, final_regs = simulate(a.words, a.meta, a.asm)

    write_hex(f"{args.out}.hex", a.words)
    write_asm_with_gt(f"{args.out}.S", a.asm, a.words, gt_lines)
    write_truth(f"{args.out}.truth", truth_lines, final_regs)

    print(f"Wrote {args.out}.hex, {args.out}.S, {args.out}.truth ({len(a.words)} words) for test '{args.test}'")

if __name__ == "__main__":
    main()
