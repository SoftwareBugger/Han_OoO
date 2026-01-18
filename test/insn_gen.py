#!/usr/bin/env python3
# insn_gen.py
# Generate a readmemh hex file for RV32I (32-bit instructions)
#
# More complete stress program for frontend/decode:
# - ALU I/R types
# - shifts, compares (signed/unsigned)
# - branches (taken/not-taken, fwd/back)
# - jal/jalr
# - lw/sw (basic)
#
# Output: prog.hex (one 32-bit word per line, hex)

from typing import List

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

def encode_S(opcode, funct3, rs1, rs2, imm):
    imm12  = mask(imm, 12)
    imm_hi = (imm12 >> 5) & 0x7F
    imm_lo = imm12 & 0x1F
    return ((imm_hi         << 25) |
            (mask(rs2,5)    << 20) |
            (mask(rs1,5)    << 15) |
            (mask(funct3,3) << 12) |
            (imm_lo         << 7)  |
            mask(opcode,7))

def encode_B(opcode, funct3, rs1, rs2, imm):
    # imm is byte offset; must be multiple of 2.
    imm13 = mask(imm, 13)
    b12   = (imm13 >> 12) & 1
    b11   = (imm13 >> 11) & 1
    b10_5 = (imm13 >> 5)  & 0x3F
    b4_1  = (imm13 >> 1)  & 0xF
    return ((b12            << 31) |
            (b10_5          << 25) |
            (mask(rs2,5)    << 20) |
            (mask(rs1,5)    << 15) |
            (mask(funct3,3) << 12) |
            (b4_1           << 8)  |
            (b11            << 7)  |
            mask(opcode,7))

def encode_U(opcode, rd, imm20):
    return ((mask(imm20,20) << 12) |
            (mask(rd,5)     << 7)  |
            mask(opcode,7))

def encode_J(opcode, rd, imm):
    # imm is byte offset; must be multiple of 2
    imm21  = mask(imm, 21)
    j20    = (imm21 >> 20) & 1
    j10_1  = (imm21 >> 1)  & 0x3FF
    j11    = (imm21 >> 11) & 1
    j19_12 = (imm21 >> 12) & 0xFF
    return ((j20            << 31) |
            (j19_12         << 12) |
            (j11            << 20) |
            (j10_1          << 21) |
            (mask(rd,5)     << 7)  |
            mask(opcode,7))

# -------------------------
# RV32I convenience wrappers
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

# Branches
def BEQ(rs1, rs2, off):  return encode_B(0x63, 0x0, rs1, rs2, off)
def BNE(rs1, rs2, off):  return encode_B(0x63, 0x1, rs1, rs2, off)
def BLT(rs1, rs2, off):  return encode_B(0x63, 0x4, rs1, rs2, off)
def BGE(rs1, rs2, off):  return encode_B(0x63, 0x5, rs1, rs2, off)
def BLTU(rs1, rs2, off): return encode_B(0x63, 0x6, rs1, rs2, off)
def BGEU(rs1, rs2, off): return encode_B(0x63, 0x7, rs1, rs2, off)

# Jumps / upper immediates
def LUI(rd, imm20):    return encode_U(0x37, rd, imm20)
def AUIPC(rd, imm20):  return encode_U(0x17, rd, imm20)
def JAL(rd, off):      return encode_J(0x6F, rd, off)
def JALR(rd, rs1, imm):return encode_I(0x67, rd, 0x0, rs1, imm)

# Loads/stores (only LW/SW here; extend if you want)
def LW(rd, rs1, imm):  return encode_I(0x03, rd, 0x2, rs1, imm)
def SW(rs2, rs1, imm): return encode_S(0x23, 0x2, rs1, rs2, imm)

def write_hex(path: str, words: List[int]):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")


def write_asm(path: str, words: List[int], labels: dict, asm_lines: List[str]):
    """Write a simple annotated listing: PC: HEX    assembly"""
    pc_to_labels = {}
    for name, pc in labels.items():
        pc_to_labels.setdefault(pc, []).append(name)
    with open(path, "w") as f:
        for i, (w, asm) in enumerate(zip(words, asm_lines)):
            pc = 4 * i
            if pc in pc_to_labels:
                for name in sorted(pc_to_labels[pc]):
                    f.write(f"{name}:\n")
            f.write(f"{pc:08x}: {w & 0xFFFFFFFF:08x}    {asm}\n")

# -------------------------
# Small "assembler" helpers for labels
# -------------------------
class Asm:
    def __init__(self):
        self.words: List[int] = []
        self.asm_lines: List[str] = []   # 1:1 with words
        self.labels = {}      # name -> pc
        self.fixups = []      # (idx, kind, args...)

    @property
    def pc(self) -> int:
        return 4 * len(self.words)

    def label(self, name: str):
        self.labels[name] = self.pc

    def emit(self, w: int, asm: str):
        self.words.append(w & 0xFFFFFFFF)
        self.asm_lines.append(asm)

    # Branch to label (patched later)
    def emit_b(self, which: str, rs1: int, rs2: int, label: str):
        idx = len(self.words)
        self.emit(NOP(), f"{which.lower()} x{rs1}, x{rs2}, {label}")  # placeholder word
        self.fixups.append((idx, "B", which, rs1, rs2, label))

    # JAL to label (patched later)
    def emit_jal(self, rd: int, label: str):
        idx = len(self.words)
        self.emit(NOP(), f"jal x{rd}, {label}")  # placeholder word
        self.fixups.append((idx, "JAL", rd, label))

    def patch(self):
        for fx in self.fixups:
            idx = fx[0]
            kind = fx[1]
            pc_here = 4 * idx
            if kind == "B":
                _, _, which, rs1, rs2, label = fx
                target = self.labels[label]
                off = target - pc_here
                if off % 2 != 0:
                    raise ValueError(f"Branch offset not 2-byte aligned: {label} off={off}")
                ins = {
                    "BEQ": BEQ, "BNE": BNE, "BLT": BLT, "BGE": BGE, "BLTU": BLTU, "BGEU": BGEU
                }[which](rs1, rs2, off)
                self.words[idx] = ins
            elif kind == "JAL":
                _, _, rd, label = fx
                target = self.labels[label]
                off = target - pc_here
                if off % 2 != 0:
                    raise ValueError(f"JAL offset not 2-byte aligned: {label} off={off}")
                self.words[idx] = JAL(rd, off)
            else:
                raise ValueError(f"Unknown fixup kind {kind}")


def main():
    a = Asm()

    # ------------------------------------------------------------
    # 0) Basic register init + negative immediates
    # ------------------------------------------------------------
    # x1=1, x2=2, x3=3
    a.emit(ADDI(1, 0, 1),    "addi x1, x0, 1")
    a.emit(ADDI(2, 0, 2),    "addi x2, x0, 2")
    a.emit(ADDI(3, 0, 3),    "addi x3, x0, 3")

    # x6 = -1, x7 = -2048 (sign-ext edge)
    a.emit(ADDI(6, 0, -1),    "addi x6, x0, -1")
    a.emit(ADDI(7, 0, -2048), "addi x7, x0, -2048")

    # ------------------------------------------------------------
    # 1) I-type ALU ops
    # ------------------------------------------------------------
    a.emit(ANDI(8, 6, 0x0FF),   "andi x8, x6, 0xff")
    a.emit(ORI(9,  0, 0x123),   "ori  x9, x0, 0x123")
    a.emit(XORI(10, 9, 0x055),  "xori x10, x9, 0x55")
    a.emit(SLTI(11, 7, 0),      "slti x11, x7, 0")
    a.emit(SLTIU(12, 7, 0),     "sltiu x12, x7, 0")
    a.emit(SLLI(13, 1, 3),      "slli x13, x1, 3")
    a.emit(SRLI(14, 13, 1),     "srli x14, x13, 1")
    a.emit(SRAI(15, 7, 4),      "srai x15, x7, 4")

    # ------------------------------------------------------------
    # 2) R-type ALU ops
    # ------------------------------------------------------------
    a.emit(ADD(16, 1, 2),       "add  x16, x1, x2")
    a.emit(SUB(17, 2, 1),       "sub  x17, x2, x1")
    a.emit(AND(18, 6, 9),       "and  x18, x6, x9")
    a.emit(OR(19,  1, 9),       "or   x19, x1, x9")
    a.emit(XOR(20, 1, 2),       "xor  x20, x1, x2")
    a.emit(SLL(21, 1, 2),       "sll  x21, x1, x2")
    a.emit(SRL(22, 6, 2),       "srl  x22, x6, x2")
    a.emit(SRA(23, 7, 2),       "sra  x23, x7, x2")
    a.emit(SLT(24, 7, 0),       "slt  x24, x7, x0")
    a.emit(SLTU(25, 7, 0),      "sltu x25, x7, x0")

    # ------------------------------------------------------------
    # 3) Branches: not-taken and taken (fwd)
    # ------------------------------------------------------------
    # if x1 == x2 (1==2) NOT taken -> fallthrough
    a.emit_b("BEQ", 1, 2, "br_not_taken_target")
    a.emit(ADDI(26, 0, 0x111),  "addi x26, x0, 0x111")
    a.emit_jal(0, "after_br_not_taken")
    a.label("br_not_taken_target")
    a.emit(ADDI(26, 0, 0x999),  "addi x26, x0, 0x999")
    a.label("after_br_not_taken")

    # if x1 != x2 (1!=2) taken -> jump over next
    a.emit_b("BNE", 1, 2, "br_taken_target")
    a.emit(ADDI(27, 0, 0x222),  "addi x27, x0, 0x222")
    a.label("br_taken_target")
    a.emit(ADDI(27, 0, 0x333),  "addi x27, x0, 0x333")

    # ------------------------------------------------------------
    # 4) Small counted loop using backward branch
    # ------------------------------------------------------------
    # x28 = 5; x29 = 0; loop: x29 += 1; x28 -= 1; while (x28 != 0)
    a.emit(ADDI(28, 0, 5),      "addi x28, x0, 5")
    a.emit(ADDI(29, 0, 0),      "addi x29, x0, 0")
    a.label("loop_top")
    a.emit(ADDI(29, 29, 1),     "addi x29, x29, 1")
    a.emit(ADDI(28, 28, -1),    "addi x28, x28, -1")
    a.emit_b("BNE", 28, 0, "loop_top")

    # ------------------------------------------------------------
    # 5) AUIPC/LUI sanity + JAL/JALR
    # ------------------------------------------------------------
    a.emit(LUI(30, 0x12345),    "lui   x30, 0x12345")
    a.emit(AUIPC(31, 0x00001),  "auipc x31, 0x1")

    # JAL link test: x5 gets return address
    a.emit_jal(5, "jal_target")
    a.emit(ADDI(6, 0, 0x777),   "addi x6, x0, 0x777")
    a.label("jal_target")
    a.emit(ADDI(6, 0, 0x888),   "addi x6, x0, 0x888")

    # JALR test:
    a.emit(AUIPC(4, 0),         "auipc x4, 0x0")
    a.emit(ADDI(4, 4, 8),       "addi  x4, x4, 8")
    a.emit(JALR(0, 4, 0),       "jalr  x0, x4, 0")
    a.emit(ADDI(7, 0, 0xAAA),   "addi x7, x0, 0xaaa")
    a.label("jalr_target")
    a.emit(ADDI(7, 0, 0xBBB),   "addi x7, x0, 0xbbb")

    # ------------------------------------------------------------
    # 6) Simple LW/SW pattern (assumes dmem exists at address 0)
    # ------------------------------------------------------------
    a.emit(ADDI(10, 0, 0),      "addi x10, x0, 0")
    a.emit(SW(1, 10, 0),        "sw   x1, 0(x10)")
    a.emit(SW(2, 10, 4),        "sw   x2, 4(x10)")
    a.emit(SW(3, 10, 8),        "sw   x3, 8(x10)")
    a.emit(LW(11, 10, 0),       "lw   x11, 0(x10)")
    a.emit(LW(12, 10, 4),       "lw   x12, 4(x10)")
    a.emit(LW(13, 10, 8),       "lw   x13, 8(x10)")

    # ------------------------------------------------------------
    # 7) End: infinite loop
    # ------------------------------------------------------------
    a.label("done")
    a.emit(JAL(0, 0),           "jal  x0, 0")

    # Patch label-based branches/jumps
    a.patch()

    # Pad to reduce accidental out-of-range fetch behavior
    for _ in range(32):
        a.emit(NOP(), "nop")

    write_hex("prog.hex", a.words)
    write_asm("prog.S", a.words, a.labels, a.asm_lines)
    print("Wrote prog.hex and prog.S with", len(a.words), "words")


if __name__ == "__main__":
    main()
