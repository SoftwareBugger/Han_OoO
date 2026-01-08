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

# -------------------------
# Small "assembler" helpers for labels
# -------------------------
class Asm:
    def __init__(self):
        self.words: List[int] = []
        self.labels = {}      # name -> pc
        self.fixups = []      # (idx, kind, args...)

    @property
    def pc(self) -> int:
        return 4 * len(self.words)

    def label(self, name: str):
        self.labels[name] = self.pc

    def emit(self, w: int):
        self.words.append(w & 0xFFFFFFFF)

    # Branch to label (patched later)
    def emit_b(self, which: str, rs1: int, rs2: int, label: str):
        idx = len(self.words)
        self.emit(NOP())  # placeholder
        self.fixups.append((idx, "B", which, rs1, rs2, label))

    # JAL to label (patched later)
    def emit_jal(self, rd: int, label: str):
        idx = len(self.words)
        self.emit(NOP())  # placeholder
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
    a.emit(ADDI(1, 0, 1))
    a.emit(ADDI(2, 0, 2))
    a.emit(ADDI(3, 0, 3))

    # x6 = -1, x7 = -2048 (sign-ext edge)
    a.emit(ADDI(6, 0, -1))
    a.emit(ADDI(7, 0, -2048))

    # ------------------------------------------------------------
    # 1) I-type ALU ops
    # ------------------------------------------------------------
    a.emit(ANDI(8, 6, 0x0FF))   # x8  = x6 & 0x0ff
    a.emit(ORI(9,  0, 0x123))   # x9  = 0x123
    a.emit(XORI(10, 9, 0x055))  # x10 = x9 ^ 0x55
    a.emit(SLTI(11, 7, 0))      # x11 = (x7 < 0) signed -> should be 1
    a.emit(SLTIU(12, 7, 0))     # x12 = (x7 < 0) unsigned -> should be 0
    a.emit(SLLI(13, 1, 3))      # x13 = 1 << 3 = 8
    a.emit(SRLI(14, 13, 1))     # x14 = 4
    a.emit(SRAI(15, 7, 4))      # arithmetic shift negative

    # ------------------------------------------------------------
    # 2) R-type ALU ops
    # ------------------------------------------------------------
    a.emit(ADD(16, 1, 2))       # 1+2=3
    a.emit(SUB(17, 2, 1))       # 1
    a.emit(AND(18, 6, 9))       # (-1) & 0x123
    a.emit(OR(19,  1, 9))       # 1 | 0x123
    a.emit(XOR(20, 1, 2))       # 3
    a.emit(SLL(21, 1, 2))       # 1 << 2 = 4
    a.emit(SRL(22, 6, 2))       # logical shift of -1
    a.emit(SRA(23, 7, 2))       # arithmetic shift of -2048
    a.emit(SLT(24, 7, 0))       # (-2048 < 0) signed
    a.emit(SLTU(25, 7, 0))      # unsigned compare

    # ------------------------------------------------------------
    # 3) Branches: not-taken and taken (fwd)
    # ------------------------------------------------------------
    # if x1 == x2 (1==2) NOT taken -> fallthrough
    a.emit_b("BEQ", 1, 2, "br_not_taken_target")
    a.emit(ADDI(26, 0, 0x111))  # executed
    a.emit_jal(0, "after_br_not_taken")
    a.label("br_not_taken_target")
    a.emit(ADDI(26, 0, 0x999))  # should be skipped
    a.label("after_br_not_taken")

    # if x1 != x2 (1!=2) taken -> jump over next
    a.emit_b("BNE", 1, 2, "br_taken_target")
    a.emit(ADDI(27, 0, 0x222))  # should be skipped
    a.label("br_taken_target")
    a.emit(ADDI(27, 0, 0x333))  # executed

    # ------------------------------------------------------------
    # 4) Small counted loop using backward branch
    # ------------------------------------------------------------
    # x28 = 5; x29 = 0; loop: x29 += 1; x28 -= 1; while (x28 != 0)
    a.emit(ADDI(28, 0, 5))
    a.emit(ADDI(29, 0, 0))
    a.label("loop_top")
    a.emit(ADDI(29, 29, 1))
    a.emit(ADDI(28, 28, -1))
    a.emit_b("BNE", 28, 0, "loop_top")

    # ------------------------------------------------------------
    # 5) AUIPC/LUI sanity + JAL/JALR
    # ------------------------------------------------------------
    # x30 = some upper immediate, x31 = PC-relative
    a.emit(LUI(30, 0x12345))
    a.emit(AUIPC(31, 0x00001))  # PC + (1<<12)

    # JAL link test: x5 gets return address
    a.emit_jal(5, "jal_target")
    a.emit(ADDI(6, 0, 0x777))   # should be skipped due to jump
    a.label("jal_target")
    a.emit(ADDI(6, 0, 0x888))   # executed

    # JALR test:
    # Put address of 'jalr_target' into x4 using AUIPC + ADDI (rough, but deterministic)
    # We'll do: x4 = PC + 8 (so it points to label after two insns)
    a.emit(AUIPC(4, 0))         # x4 = this PC
    a.emit(ADDI(4, 4, 8))       # x4 = PC+8
    a.emit(JALR(0, 4, 0))       # jump to PC+8 (skips next)
    a.emit(ADDI(7, 0, 0xAAA))   # should be skipped
    a.label("jalr_target")
    a.emit(ADDI(7, 0, 0xBBB))   # executed

    # ------------------------------------------------------------
    # 6) Simple LW/SW pattern (assumes dmem exists at address 0)
    # ------------------------------------------------------------
    # x10 = 0 base
    a.emit(ADDI(10, 0, 0))
    # store x1..x3 to [0],[4],[8]
    a.emit(SW(1, 10, 0))
    a.emit(SW(2, 10, 4))
    a.emit(SW(3, 10, 8))
    # load back into x11..x13
    a.emit(LW(11, 10, 0))
    a.emit(LW(12, 10, 4))
    a.emit(LW(13, 10, 8))

    # ------------------------------------------------------------
    # 7) End: infinite loop
    # ------------------------------------------------------------
    a.label("done")
    a.emit(JAL(0, 0))

    # Patch label-based branches/jumps
    a.patch()

    # Pad to reduce accidental out-of-range fetch behavior
    a.words += [NOP()] * 32

    write_hex("prog.hex", a.words)
    print("Wrote prog.hex with", len(a.words), "words")

if __name__ == "__main__":
    main()
