#!/usr/bin/env python3
# rv32i_selfcheck_tests.py
# Self-checking RV32I tests with commit trace golden reference generator

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

def encode_U(opcode, rd, imm20):
    return ((mask(imm20, 20) << 12) |
            (mask(rd, 5)     << 7)  |
            mask(opcode, 7))

def encode_B(opcode, funct3, rs1, rs2, imm13):
    """Branch encoding - imm13 is signed byte offset (must be even)"""
    imm = mask(imm13, 13)
    imm_12   = (imm >> 12) & 0x1
    imm_10_5 = (imm >> 5)  & 0x3F
    imm_4_1  = (imm >> 1)  & 0xF
    imm_11   = (imm >> 11) & 0x1
    return (
        (imm_12 << 31) |
        (imm_10_5 << 25) |
        (mask(rs2, 5) << 20) |
        (mask(rs1, 5) << 15) |
        (mask(funct3, 3) << 12) |
        (imm_4_1 << 8) |
        (imm_11 << 7) |
        mask(opcode, 7)
    )

def encode_J(opcode, rd, imm21):
    """JAL encoding - imm21 is signed byte offset (must be even)"""
    imm = mask(imm21, 21)
    imm_20    = (imm >> 20) & 0x1
    imm_10_1  = (imm >> 1)  & 0x3FF
    imm_11    = (imm >> 11) & 0x1
    imm_19_12 = (imm >> 12) & 0xFF
    return (
        (imm_20 << 31) |
        (imm_10_1 << 21) |
        (imm_11 << 20) |
        (imm_19_12 << 12) |
        (mask(rd, 5) << 7) |
        mask(opcode, 7)
    )

# Stores (opcode 0100011 = 0x23)  S-type encoding helper:
def encode_S(opcode, funct3, rs1, rs2, imm12):
    imm = mask(imm12, 12)
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0  = imm & 0x1F
    return (
        (imm_11_5 << 25) |
        (mask(rs2, 5) << 20) |
        (mask(rs1, 5) << 15) |
        (mask(funct3, 3) << 12) |
        (imm_4_0 << 7) |
        mask(opcode, 7)
    )


# Patchers for label fixups
def patch_B(word: int, imm13: int) -> int:
    opcode = word & 0x7F
    rs1    = (word >> 15) & 0x1F
    rs2    = (word >> 20) & 0x1F
    funct3 = (word >> 12) & 0x7
    return encode_B(opcode, funct3, rs1, rs2, imm13)

def patch_J(word: int, imm21: int) -> int:
    opcode = word & 0x7F
    rd     = (word >> 7) & 0x1F
    return encode_J(opcode, rd, imm21)

# -------------------------
# RV32I instruction encoders
# -------------------------
def NOP(): return encode_I(0x13, 0, 0x0, 0, 0)

# U-type
def LUI(rd, imm20):   return encode_U(0x37, rd, imm20)
def AUIPC(rd, imm20): return encode_U(0x17, rd, imm20)

# I-type ALU
def ADDI(rd, rs1, imm):  return encode_I(0x13, rd, 0x0, rs1, imm)
def SLTI(rd, rs1, imm):  return encode_I(0x13, rd, 0x2, rs1, imm)
def SLTIU(rd, rs1, imm): return encode_I(0x13, rd, 0x3, rs1, imm)
def XORI(rd, rs1, imm):  return encode_I(0x13, rd, 0x4, rs1, imm)
def ORI(rd, rs1, imm):   return encode_I(0x13, rd, 0x6, rs1, imm)
def ANDI(rd, rs1, imm):  return encode_I(0x13, rd, 0x7, rs1, imm)
def SLLI(rd, rs1, sh):   return encode_I(0x13, rd, 0x1, rs1, sh)
def SRLI(rd, rs1, sh):   return encode_I(0x13, rd, 0x5, rs1, sh)
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
def BEQ(rs1, rs2, imm):  return encode_B(0x63, 0x0, rs1, rs2, imm)
def BNE(rs1, rs2, imm):  return encode_B(0x63, 0x1, rs1, rs2, imm)
def BLT(rs1, rs2, imm):  return encode_B(0x63, 0x4, rs1, rs2, imm)
def BGE(rs1, rs2, imm):  return encode_B(0x63, 0x5, rs1, rs2, imm)
def BLTU(rs1, rs2, imm): return encode_B(0x63, 0x6, rs1, rs2, imm)
def BGEU(rs1, rs2, imm): return encode_B(0x63, 0x7, rs1, rs2, imm)

# Jumps
def JAL(rd, imm):        return encode_J(0x6F, rd, imm)
def JALR(rd, rs1, imm):  return encode_I(0x67, rd, 0x0, rs1, imm)

def SB(rs2, rs1, imm): return encode_S(0x23, 0x0, rs1, rs2, imm)
def SH(rs2, rs1, imm): return encode_S(0x23, 0x1, rs1, rs2, imm)
def SW(rs2, rs1, imm): return encode_S(0x23, 0x2, rs1, rs2, imm)
# Loads (opcode 0000011 = 0x03)
def LB(rd, rs1, imm):  return encode_I(0x03, rd, 0x0, rs1, imm)
def LH(rd, rs1, imm):  return encode_I(0x03, rd, 0x1, rs1, imm)
def LW(rd, rs1, imm):  return encode_I(0x03, rd, 0x2, rs1, imm)
def LBU(rd, rs1, imm): return encode_I(0x03, rd, 0x4, rs1, imm)
def LHU(rd, rs1, imm): return encode_I(0x03, rd, 0x5, rs1, imm)



# -------------------------
# Helpers
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

def x(r: int) -> str:
    return f"x{r}"

def load_hex_words(path: str) -> List[int]:
    words = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line: 
                continue
            # supports "deadbeef" per line
            words.append(int(line, 16) & 0xFFFFFFFF)
    return words

def imm_i(inst): return sext(inst >> 20, 12)

def imm_s(inst):
    imm = ((inst >> 25) << 5) | ((inst >> 7) & 0x1F)
    return sext(imm, 12)

def imm_b(inst):
    imm = 0
    imm |= ((inst >> 31) & 0x1) << 12
    imm |= ((inst >> 7)  & 0x1) << 11
    imm |= ((inst >> 25) & 0x3F) << 5
    imm |= ((inst >> 8)  & 0xF) << 1
    return sext(imm, 13)

def imm_u(inst): return inst & 0xFFFFF000

def imm_j(inst):
    imm = 0
    imm |= ((inst >> 31) & 0x1) << 20
    imm |= ((inst >> 12) & 0xFF) << 12
    imm |= ((inst >> 20) & 0x1) << 11
    imm |= ((inst >> 21) & 0x3FF) << 1
    return sext(imm, 21)

def decode_word(inst: int, pc: int) -> tuple[Meta, str]:

    if inst == 0:
        return Meta("NOP", 0, 0, 0, 0, None), "nop"

    opcode = inst & 0x7F
    rd     = (inst >> 7) & 0x1F
    funct3 = (inst >> 12) & 0x7
    rs1    = (inst >> 15) & 0x1F
    rs2    = (inst >> 20) & 0x1F
    funct7 = (inst >> 25) & 0x7F

    # Defaults
    m = Meta("NOP", 0, 0, 0, 0, None)
    s = "nop"

    if opcode == 0x37:  # LUI
        m = Meta("LUI", rd, 0, 0, imm_u(inst) >> 12)
        s = f"lui x{rd}, 0x{(imm_u(inst)>>12):x}"

    elif opcode == 0x17:  # AUIPC
        m = Meta("AUIPC", rd, 0, 0, imm_u(inst) >> 12)
        s = f"auipc x{rd}, 0x{(imm_u(inst)>>12):x}"

    elif opcode == 0x6F:  # JAL
        off = imm_j(inst)
        m = Meta("JAL", rd, 0, 0, 0, pc + off)
        s = f"jal x{rd}, {off:+d}"

    elif opcode == 0x67:  # JALR
        off = imm_i(inst)
        m = Meta("JALR", rd, rs1, 0, off, None)
        s = f"jalr x{rd}, {off}(x{rs1})"

    elif opcode == 0x63:  # BRANCH
        off = imm_b(inst)
        tgt = pc + off
        opmap = {0x0:"BEQ",0x1:"BNE",0x4:"BLT",0x5:"BGE",0x6:"BLTU",0x7:"BGEU"}
        op = opmap.get(funct3, None)
        if op is None: raise RuntimeError(f"Unknown BR funct3={funct3} inst={inst:08x}")
        m = Meta(op, 0, rs1, rs2, 0, tgt)
        s = f"{op.lower()} x{rs1}, x{rs2}, {off:+d}"

    elif opcode == 0x03:  # LOAD
        off = imm_i(inst)
        opmap = {0x0:"LB",0x1:"LH",0x2:"LW",0x4:"LBU",0x5:"LHU"}
        op = opmap.get(funct3, None)
        if op is None: raise RuntimeError(f"Unknown LD funct3={funct3} inst={inst:08x}")
        m = Meta(op, rd, rs1, 0, off, None)
        s = f"{op.lower()} x{rd}, {off}(x{rs1})"

    elif opcode == 0x23:  # STORE
        off = imm_s(inst)
        opmap = {0x0:"SB",0x1:"SH",0x2:"SW"}
        op = opmap.get(funct3, None)
        if op is None: raise RuntimeError(f"Unknown ST funct3={funct3} inst={inst:08x}")
        m = Meta(op, 0, rs1, rs2, off, None)
        s = f"{op.lower()} x{rs2}, {off}(x{rs1})"

    elif opcode == 0x13:  # OP-IMM
        off = imm_i(inst)
        if funct3 == 0x0: m,s = Meta("ADDI", rd, rs1, 0, off), f"addi x{rd}, x{rs1}, {off}"
        elif funct3 == 0x2: m,s = Meta("SLTI", rd, rs1, 0, off), f"slti x{rd}, x{rs1}, {off}"
        elif funct3 == 0x3: m,s = Meta("SLTIU", rd, rs1, 0, off), f"sltiu x{rd}, x{rs1}, {off}"
        elif funct3 == 0x4: m,s = Meta("XORI", rd, rs1, 0, off), f"xori x{rd}, x{rs1}, {off}"
        elif funct3 == 0x6: m,s = Meta("ORI", rd, rs1, 0, off), f"ori x{rd}, x{rs1}, {off}"
        elif funct3 == 0x7: m,s = Meta("ANDI", rd, rs1, 0, off), f"andi x{rd}, x{rs1}, {off}"
        elif funct3 == 0x1:  # SLLI
            sh = (inst >> 20) & 0x1F
            m,s = Meta("SLLI", rd, rs1, 0, sh), f"slli x{rd}, x{rs1}, {sh}"
        elif funct3 == 0x5:
            sh = (inst >> 20) & 0x1F
            if funct7 == 0x00: m,s = Meta("SRLI", rd, rs1, 0, sh), f"srli x{rd}, x{rs1}, {sh}"
            elif funct7 == 0x20: m,s = Meta("SRAI", rd, rs1, 0, sh), f"srai x{rd}, x{rs1}, {sh}"
            else: raise RuntimeError(f"Bad shift imm inst={inst:08x}")
        else:
            raise RuntimeError(f"Unknown OP-IMM funct3={funct3} inst={inst:08x}")

    elif opcode == 0x33:  # OP
        key = (funct7, funct3)
        if key == (0x00,0x0): m,s = Meta("ADD", rd, rs1, rs2, 0), f"add x{rd}, x{rs1}, x{rs2}"
        elif key == (0x20,0x0): m,s = Meta("SUB", rd, rs1, rs2, 0), f"sub x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x1): m,s = Meta("SLL", rd, rs1, rs2, 0), f"sll x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x2): m,s = Meta("SLT", rd, rs1, rs2, 0), f"slt x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x3): m,s = Meta("SLTU", rd, rs1, rs2, 0), f"sltu x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x4): m,s = Meta("XOR", rd, rs1, rs2, 0), f"xor x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x5): m,s = Meta("SRL", rd, rs1, rs2, 0), f"srl x{rd}, x{rs1}, x{rs2}"
        elif key == (0x20,0x5): m,s = Meta("SRA", rd, rs1, rs2, 0), f"sra x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x6): m,s = Meta("OR", rd, rs1, rs2, 0), f"or x{rd}, x{rs1}, x{rs2}"
        elif key == (0x00,0x7): m,s = Meta("AND", rd, rs1, rs2, 0), f"and x{rd}, x{rs1}, x{rs2}"
        else:
            raise RuntimeError(f"Unknown OP key={key} inst={inst:08x}")

    else:
        raise RuntimeError(f"Unknown opcode=0x{opcode:x} inst={inst:08x}")

    return m, s

def simulate_commit_trace_from_hex(hex_path: str, max_steps: int = 200000):
    words = load_hex_words(hex_path)
    # Create decoded meta/asm arrays aligned with word index
    meta = []
    asm  = []
    for i, w in enumerate(words):
        pc = i * 4
        try:
            m, s = decode_word(w, pc)
        except RuntimeError:
            # Allow embedded/trailing data words (e.g., signatures, pointers)
            m = Meta("DATA", 0, 0, 0, 0, None)
            s = f".word 0x{w:08x}"
        meta.append(m)
        asm.append(s)

    return simulate_commit_trace(words, meta, asm, max_steps=max_steps)


@dataclass
class Meta:
    op: str
    rd: int = 0
    rs1: int = 0
    rs2: int = 0
    imm: int = 0
    target_pc: Optional[int] = None  # For branches/jumps

# -------------------------
# Commit Trace Entry
# -------------------------
@dataclass
class CommitEntry:
    """Golden reference commit entry for OOO verification"""
    cycle: int          # Simulated cycle (for reference, actual OOO timing differs)
    pc: int            # PC of committed instruction
    inst: int          # 32-bit instruction encoding
    rd: int            # Destination register
    rd_data: int       # Data written to rd (0 if rd=0)
    asm: str           # Assembly mnemonic for debug
    
    def __str__(self):
        return f"[{self.cycle:6d}] PC={self.pc:08x} inst={self.inst:08x} rd=x{self.rd:02d} data={self.rd_data:08x}  # {self.asm}"
    
    def to_dict(self):
        """For JSON export"""
        return {
            'cycle': self.cycle,
            'pc': self.pc,
            'inst': self.inst,
            'rd': self.rd,
            'rd_data': self.rd_data,
            'asm': self.asm
        }

# -------------------------
# Enhanced Assembler with self-check utilities
# -------------------------
class Asm:
    def __init__(self):
        self.words: List[int] = []
        self.asm:   List[str] = []
        self.meta:  List[Meta] = []
        self.labels: Dict[str, int] = {}
        self.fixups: List[Tuple[int, str, tuple]] = []  # (idx, kind, args)

    def pc(self) -> int:
        return 4 * len(self.words)

    def emit(self, w: int, asm: str, meta: Meta):
        self.words.append(w & 0xFFFFFFFF)
        self.asm.append(asm)
        self.meta.append(meta)

    # U-type
    def lui(self, rd, imm20):
        self.emit(LUI(rd, imm20), f"lui  {x(rd)}, 0x{imm20 & 0xFFFFF:x}", 
                  Meta("LUI", rd, 0, 0, imm20))
    
    def auipc(self, rd, imm20):
        self.emit(AUIPC(rd, imm20), f"auipc {x(rd)}, 0x{imm20 & 0xFFFFF:x}", 
                  Meta("AUIPC", rd, 0, 0, imm20))

    # I-type
    def addi(self, rd, rs1, imm): 
        self.emit(ADDI(rd, rs1, imm), f"addi {x(rd)}, {x(rs1)}, {imm}", 
                  Meta("ADDI", rd, rs1, 0, imm))
    
    def andi(self, rd, rs1, imm):
        s = f"andi {x(rd)}, {x(rs1)}, 0x{imm & 0xFFF:x}" if imm >= 0 else f"andi {x(rd)}, {x(rs1)}, {imm}"
        self.emit(ANDI(rd, rs1, imm), s, Meta("ANDI", rd, rs1, 0, imm))
    
    def ori(self, rd, rs1, imm):
        s = f"ori  {x(rd)}, {x(rs1)}, 0x{imm & 0xFFF:x}" if imm >= 0 else f"ori  {x(rd)}, {x(rs1)}, {imm}"
        self.emit(ORI(rd, rs1, imm), s, Meta("ORI", rd, rs1, 0, imm))
    
    def xori(self, rd, rs1, imm):
        s = f"xori {x(rd)}, {x(rs1)}, 0x{imm & 0xFFF:x}" if imm >= 0 else f"xori {x(rd)}, {x(rs1)}, {imm}"
        self.emit(XORI(rd, rs1, imm), s, Meta("XORI", rd, rs1, 0, imm))
    
    def slti(self, rd, rs1, imm): 
        self.emit(SLTI(rd, rs1, imm), f"slti {x(rd)}, {x(rs1)}, {imm}", 
                  Meta("SLTI", rd, rs1, 0, imm))
    
    def sltiu(self, rd, rs1, imm): 
        self.emit(SLTIU(rd, rs1, imm), f"sltiu {x(rd)}, {x(rs1)}, {imm}", 
                  Meta("SLTIU", rd, rs1, 0, imm))
    
    def slli(self, rd, rs1, sh):  
        self.emit(SLLI(rd, rs1, sh), f"slli {x(rd)}, {x(rs1)}, {sh}", 
                  Meta("SLLI", rd, rs1, 0, sh))
    
    def srli(self, rd, rs1, sh):  
        self.emit(SRLI(rd, rs1, sh), f"srli {x(rd)}, {x(rs1)}, {sh}", 
                  Meta("SRLI", rd, rs1, 0, sh))
    
    def srai(self, rd, rs1, sh):  
        self.emit(SRAI(rd, rs1, sh), f"srai {x(rd)}, {x(rs1)}, {sh}", 
                  Meta("SRAI", rd, rs1, 0, sh))

    # R-type
    def add(self, rd, rs1, rs2):  
        self.emit(ADD(rd, rs1, rs2), f"add  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("ADD", rd, rs1, rs2, 0))
    
    def sub(self, rd, rs1, rs2):  
        self.emit(SUB(rd, rs1, rs2), f"sub  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("SUB", rd, rs1, rs2, 0))
    
    def _and(self, rd, rs1, rs2): 
        self.emit(AND(rd, rs1, rs2), f"and  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("AND", rd, rs1, rs2, 0))
    
    def _or(self, rd, rs1, rs2):  
        self.emit(OR(rd, rs1, rs2), f"or   {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("OR",  rd, rs1, rs2, 0))
    
    def _xor(self, rd, rs1, rs2): 
        self.emit(XOR(rd, rs1, rs2), f"xor  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("XOR", rd, rs1, rs2, 0))
    
    def sll(self, rd, rs1, rs2):  
        self.emit(SLL(rd, rs1, rs2), f"sll  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("SLL", rd, rs1, rs2, 0))
    
    def srl(self, rd, rs1, rs2):  
        self.emit(SRL(rd, rs1, rs2), f"srl  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("SRL", rd, rs1, rs2, 0))
    
    def sra(self, rd, rs1, rs2):  
        self.emit(SRA(rd, rs1, rs2), f"sra  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("SRA", rd, rs1, rs2, 0))
    
    def slt(self, rd, rs1, rs2):  
        self.emit(SLT(rd, rs1, rs2), f"slt  {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("SLT", rd, rs1, rs2, 0))
    
    def sltu(self, rd, rs1, rs2): 
        self.emit(SLTU(rd, rs1, rs2), f"sltu {x(rd)}, {x(rs1)}, {x(rs2)}", 
                  Meta("SLTU", rd, rs1, rs2, 0))
        

    # Loads
    def lb(self, rd, rs1, imm):
        self.emit(LB(rd, rs1, imm), f"lb   {x(rd)}, {imm}({x(rs1)})",
                Meta("LB", rd, rs1, 0, imm))

    def lbu(self, rd, rs1, imm):
        self.emit(LBU(rd, rs1, imm), f"lbu  {x(rd)}, {imm}({x(rs1)})",
                Meta("LBU", rd, rs1, 0, imm))

    def lh(self, rd, rs1, imm):
        self.emit(LH(rd, rs1, imm), f"lh   {x(rd)}, {imm}({x(rs1)})",
                Meta("LH", rd, rs1, 0, imm))

    def lhu(self, rd, rs1, imm):
        self.emit(LHU(rd, rs1, imm), f"lhu  {x(rd)}, {imm}({x(rs1)})",
                Meta("LHU", rd, rs1, 0, imm))

    def lw(self, rd, rs1, imm):
        self.emit(LW(rd, rs1, imm), f"lw   {x(rd)}, {imm}({x(rs1)})",
                Meta("LW", rd, rs1, 0, imm))

    # Stores
    def sb(self, rs2, rs1, imm):
        self.emit(SB(rs2, rs1, imm), f"sb   {x(rs2)}, {imm}({x(rs1)})",
                Meta("SB", 0, rs1, rs2, imm))

    def sh(self, rs2, rs1, imm):
        self.emit(SH(rs2, rs1, imm), f"sh   {x(rs2)}, {imm}({x(rs1)})",
                Meta("SH", 0, rs1, rs2, imm))

    def sw(self, rs2, rs1, imm):
        self.emit(SW(rs2, rs1, imm), f"sw   {x(rs2)}, {imm}({x(rs1)})",
                Meta("SW", 0, rs1, rs2, imm))

    def nop(self): 
        self.emit(NOP(), "nop", Meta("NOP"))

    # -------------------------
    # Label support for branches/jumps
    # -------------------------
    
    def label(self, name: str):
        """Define a label at current PC"""
        if name in self.labels:
            raise ValueError(f"Duplicate label '{name}'")
        self.labels[name] = self.pc()

    def _fixup_B(self, op: str, rs1: int, rs2: int, label: str, enc_fn, asm_mn: str):
        """Helper for branch instructions with label fixup"""
        idx = len(self.words)
        self.fixups.append((idx, "B", (op, label, enc_fn)))
        self.emit(enc_fn(rs1, rs2, 0), f"{asm_mn} {x(rs1)}, {x(rs2)}, {label}",
                  Meta(op, 0, rs1, rs2, 0))

    def _fixup_J(self, rd: int, label: str):
        """Helper for JAL instruction with label fixup"""
        idx = len(self.words)
        self.fixups.append((idx, "J", (label,)))
        self.emit(JAL(rd, 0), f"jal  {x(rd)}, {label}",
                  Meta("JAL", rd, 0, 0, 0))

    # Branch instructions
    def beq(self, rs1: int, rs2: int, label: str):
        self._fixup_B("BEQ", rs1, rs2, label, BEQ, "beq ")
    
    def bne(self, rs1: int, rs2: int, label: str):
        self._fixup_B("BNE", rs1, rs2, label, BNE, "bne ")
    
    def blt(self, rs1: int, rs2: int, label: str):
        self._fixup_B("BLT", rs1, rs2, label, BLT, "blt ")
    
    def bge(self, rs1: int, rs2: int, label: str):
        self._fixup_B("BGE", rs1, rs2, label, BGE, "bge ")
    
    def bltu(self, rs1: int, rs2: int, label: str):
        self._fixup_B("BLTU", rs1, rs2, label, BLTU, "bltu")
    
    def bgeu(self, rs1: int, rs2: int, label: str):
        self._fixup_B("BGEU", rs1, rs2, label, BGEU, "bgeu")

    # Jump instructions
    def jal(self, rd: int, label: str):
        self._fixup_J(rd, label)
    
    def jalr(self, rd: int, rs1: int, imm: int):
        self.emit(JALR(rd, rs1, imm), f"jalr {x(rd)}, {imm}({x(rs1)})",
                  Meta("JALR", rd, rs1, 0, imm))

    def finalize(self):
        """Resolve all label fixups"""
        for idx, kind, args in self.fixups:
            if kind == "B":
                op, label, enc_fn = args
                if label not in self.labels:
                    raise ValueError(f"Undefined label '{label}'")
                m = self.meta[idx]
                tgt = self.labels[label]
                pc = idx * 4
                off = tgt - pc
                if off & 0x1:
                    raise ValueError(f"Branch target not aligned: {label}")
                self.words[idx] = patch_B(self.words[idx], off)
                m.target_pc = tgt
            elif kind == "J":
                (label,) = args
                if label not in self.labels:
                    raise ValueError(f"Undefined label '{label}'")
                tgt = self.labels[label]
                pc = idx * 4
                off = tgt - pc
                if off & 0x1:
                    raise ValueError(f"JAL target not aligned: {label}")
                self.words[idx] = patch_J(self.words[idx], off)
                self.meta[idx].target_pc = tgt

    # -------------------------
    # Self-check utilities
    # -------------------------
    
    def li(self, rd: int, imm32: int, comment: str = ""):
        """Load 32-bit immediate using LUI + ORI/ADDI"""
        imm32 = u32(imm32)
        upper = (imm32 >> 12) & 0xFFFFF
        lower = imm32 & 0xFFF
        
        # Handle sign extension of lower 12 bits
        if lower & 0x800:  # If bit 11 is set, ADDI will sign-extend
            upper = (upper + 1) & 0xFFFFF
        
        if comment:
            self.emit(NOP(), f"# li {x(rd)}, 0x{imm32:08x} - {comment}", Meta("NOP"))
        
        if upper != 0:
            self.lui(rd, upper)
            if lower != 0:
                self.addi(rd, rd, sext(lower, 12))
        else:
            self.addi(rd, 0, sext(lower, 12))

    def check_reg(self, reg: int, expected: int, fail_bit: int):
        """
        Check if register equals expected value.
        If mismatch, set bit <fail_bit> in x31.
        Uses x28, x29, x30 as scratch.
        """
        expected = u32(expected)
        
        # Load expected value into x28
        self.li(28, expected, f"expected {x(reg)}=0x{expected:08x}")
        
        # XOR to find difference
        self._xor(29, reg, 28)  # x29 = reg ^ expected
        
        # Convert non-zero to 1
        self.sltu(29, 0, 29)  # x29 = (0 < x29) ? 1 : 0
        
        # Shift to fail_bit position
        if fail_bit > 0:
            self.slli(29, 29, fail_bit)
        
        # Accumulate into x31
        self._or(31, 31, 29)
        
        self.emit(NOP(), f"# check x{reg}==0x{expected:08x} (bit {fail_bit})", Meta("NOP"))

    def init_test(self):
        """Initialize test - clear x31 (pass/fail accumulator)"""
        self.addi(31, 0, 0)
        self.emit(NOP(), "# === TEST START ===", Meta("NOP"))

    def finalize_test(self, expected_x31: int = 0):
        """
        Finalize test - x31 should equal expected_x31 (usually 0 for pass).
        Stores final pass/fail in x30.
        """
        self.emit(NOP(), f"# === TEST END (expect x31=0x{expected_x31:08x}) ===", Meta("NOP"))
        
        # x30 = (x31 == expected_x31) ? 0xPASS : 0xFAIL
        self.li(28, expected_x31, "expected x31")
        self._xor(29, 31, 28)  # diff
        self.sltu(30, 0, 29)   # x30 = 1 if failed, 0 if passed
        
        # We'll just check x31 directly in the testbench
        # x30 = final status marker
        self.li(30, 0xDEADBEEF if expected_x31 == 0 else 0x0BADC0DE, "status")

def mem_write_byte(mem: dict[int,int], addr: int, val: int):
    mem[addr & 0xFFFFFFFF] = val & 0xFF

def mem_read_byte(mem: dict[int,int], addr: int) -> int:
    return mem.get(addr & 0xFFFFFFFF, 0)

def mem_write(mem: dict[int,int], addr: int, size: int, val: int):
    # little-endian
    for i in range(size):
        mem_write_byte(mem, addr + i, val >> (8*i))

def mem_read(mem: dict[int,int], addr: int, size: int) -> int:
    v = 0
    for i in range(size):
        v |= (mem_read_byte(mem, addr + i) << (8*i))
    return v


# -------------------------
# Golden Reference Simulator (Generate Commit Trace)
# -------------------------
def simulate_commit_trace(words: List[int], meta: List[Meta], asm: List[str], 
                          max_steps: int = 200000) -> Tuple[List[CommitEntry], List[int]]:
    """
    Simulate program execution and generate golden commit trace.
    This is what an OOO processor MUST match at commit (not execution order).
    
    Returns:
        commit_trace: List of commit entries in program order
        final_regfile: Final architectural register state
    """
    regs = [0] * 32
    pc_to_idx = {i * 4: i for i in range(len(words))}
    mem: dict[int,int] = {}  # byte-addressable

    
    pc = 0
    cycle = 0
    commit_trace: List[CommitEntry] = []
    
    def r(i: int) -> int:
        return 0 if i == 0 else regs[i]
    
    while cycle < max_steps and pc in pc_to_idx:
        idx = pc_to_idx[pc]
        w = words[idx]
        m = meta[idx]
        op = m.op
        
        rd, rs1, rs2, imm = m.rd, m.rs1, m.rs2, m.imm
        next_pc = pc + 4
        rd_data = 0
        
        # Execute instruction
        if op == "NOP":
            pass
            
        elif op == "LUI":
            rd_data = u32((imm & 0xFFFFF) << 12)
            
        elif op == "AUIPC":
            rd_data = u32(pc + ((imm & 0xFFFFF) << 12))
            
        elif op == "ADDI":
            rd_data = u32(r(rs1) + sext(imm, 12))
            
        elif op == "SLTI":
            rd_data = 1 if s32(r(rs1)) < sext(imm, 12) else 0
            
        elif op == "SLTIU":
            rd_data = 1 if u32(r(rs1)) < u32(sext(imm, 12)) else 0
            
        elif op == "XORI":
            rd_data = u32(r(rs1) ^ sext(imm, 12))
            
        elif op == "ORI":
            rd_data = u32(r(rs1) | sext(imm, 12))
            
        elif op == "ANDI":
            rd_data = u32(r(rs1) & sext(imm, 12))
            
        elif op == "SLLI":
            rd_data = u32(r(rs1) << (imm & 0x1F))
            
        elif op == "SRLI":
            rd_data = u32(u32(r(rs1)) >> (imm & 0x1F))
            
        elif op == "SRAI":
            rd_data = u32(s32(r(rs1)) >> (imm & 0x1F))
            
        elif op == "ADD":
            rd_data = u32(r(rs1) + r(rs2))
            
        elif op == "SUB":
            rd_data = u32(r(rs1) - r(rs2))
            
        elif op == "SLL":
            rd_data = u32(r(rs1) << (r(rs2) & 0x1F))
            
        elif op == "SLT":
            rd_data = 1 if s32(r(rs1)) < s32(r(rs2)) else 0
            
        elif op == "SLTU":
            rd_data = 1 if u32(r(rs1)) < u32(r(rs2)) else 0
            
        elif op == "XOR":
            rd_data = u32(r(rs1) ^ r(rs2))
            
        elif op == "SRL":
            rd_data = u32(u32(r(rs1)) >> (r(rs2) & 0x1F))
            
        elif op == "SRA":
            rd_data = u32(s32(r(rs1)) >> (r(rs2) & 0x1F))
            
        elif op == "OR":
            rd_data = u32(r(rs1) | r(rs2))
            
        elif op == "AND":
            rd_data = u32(r(rs1) & r(rs2))
            
        elif op in ("BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"):
            if m.target_pc is None:
                raise RuntimeError(f"Unresolved branch at PC={pc:08x}")
            
            taken = False
            if op == "BEQ":
                taken = (u32(r(rs1)) == u32(r(rs2)))
            elif op == "BNE":
                taken = (u32(r(rs1)) != u32(r(rs2)))
            elif op == "BLT":
                taken = (s32(r(rs1)) < s32(r(rs2)))
            elif op == "BGE":
                taken = (s32(r(rs1)) >= s32(r(rs2)))
            elif op == "BLTU":
                taken = (u32(r(rs1)) < u32(r(rs2)))
            else:  # BGEU
                taken = (u32(r(rs1)) >= u32(r(rs2)))
            
            next_pc = m.target_pc if taken else pc + 4
            rd_data = 0  # Branches don't write registers
            
        elif op == "JAL":
            if m.target_pc is None:
                raise RuntimeError(f"Unresolved JAL at PC={pc:08x}")
            rd_data = u32(pc + 4)
            next_pc = m.target_pc
            
        elif op == "JALR":
            rd_data = u32(pc + 4)
            next_pc = u32(r(rs1) + sext(imm, 12)) & 0xFFFFFFFE

        elif op == "LB":
            addr = u32(r(rs1) + sext(imm, 12))
            b = mem_read(mem, addr, 1)
            rd_data = u32(sext(b, 8))

        elif op == "LBU":
            addr = u32(r(rs1) + sext(imm, 12))
            b = mem_read(mem, addr, 1)
            rd_data = u32(b)

        elif op == "LH":
            addr = u32(r(rs1) + sext(imm, 12))
            h = mem_read(mem, addr, 2)
            rd_data = u32(sext(h, 16))

        elif op == "LHU":
            addr = u32(r(rs1) + sext(imm, 12))
            h = mem_read(mem, addr, 2)
            rd_data = u32(h)

        elif op == "LW":
            addr = u32(r(rs1) + sext(imm, 12))
            w32 = mem_read(mem, addr, 4)
            rd_data = u32(w32)

        elif op == "SB":
            addr = u32(r(rs1) + sext(imm, 12))
            mem_write(mem, addr, 1, r(rs2))
            rd_data = 0

        elif op == "SH":
            addr = u32(r(rs1) + sext(imm, 12))
            mem_write(mem, addr, 2, r(rs2))
            rd_data = 0

        elif op == "SW":
            addr = u32(r(rs1) + sext(imm, 12))
            mem_write(mem, addr, 4, r(rs2))
            rd_data = 0
        elif op == "DATA":
            raise RuntimeError(f"Executed DATA at PC={pc:08x} word={w:08x}")


        else:
            raise RuntimeError(f"Unknown op {op} at PC={pc:08x}")
        
        # Commit architectural write
        if rd != 0:
            regs[rd] = u32(rd_data)
        regs[0] = 0  # x0 always zero
        
        # Record commit entry
        commit_trace.append(CommitEntry(
            cycle=cycle,
            pc=pc,
            inst=w,
            rd=rd,
            rd_data=regs[rd] if rd != 0 else 0,
            asm=asm[idx]
        ))
        
        pc = next_pc
        cycle += 1

    if cycle >= max_steps:
        print(f"WARNING: Simulation stopped at max_steps={max_steps}")

    return commit_trace, regs

def write_commit_trace(path: str, commit_trace: List[CommitEntry]):
    """
    Write golden commit trace to a text file.
    This is what your OoO core must match at commit.
    """
    with open(path, "w") as f:
        f.write("# Golden Commit Trace\n")
        f.write("# cycle  pc        inst       rd  data       asm\n")
        f.write("# ------------------------------------------------------------\n")
        for e in commit_trace:
            f.write(
                f"{e.cycle:6d}  "
                f"{e.pc:08x}  "
                f"{e.inst:08x}  "
                f"x{e.rd:02d}  "
                f"{e.rd_data:08x}  "
                f"{e.asm}\n"
            )



def prog_selfcheck_basic(a: Asm):
    """Basic self-checking test with explicit register checks"""
    a.init_test()
    
    # Test 1: x1 = 5, x2 = 7
    a.addi(1, 0, 5)
    a.addi(2, 0, 7)
    a.check_reg(1, 5, 0)
    a.check_reg(2, 7, 1)
    
    # Test 2: x3 = x1 + x2 = 12
    a.add(3, 1, 2)
    a.check_reg(3, 12, 2)
    
    # Test 3: x4 = x2 - x1 = 2
    a.sub(4, 2, 1)
    a.check_reg(4, 2, 3)
    
    # Test 4: x5 = 0xDEADBEEF (full 32-bit constant)
    a.li(5, 0xDEADBEEF, "magic constant")
    a.check_reg(5, 0xDEADBEEF, 4)
    
    a.finalize_test(expected_x31=0)

def prog_selfcheck_alu(a: Asm):
    """Comprehensive ALU test with self-checking"""
    a.init_test()
    
    # Logic operations
    a.addi(1, 0, 0x55)
    a.addi(2, 0, 0x0F)
    a._and(3, 1, 2)
    a.check_reg(3, 0x05, 0)
    
    a._or(4, 1, 2)
    a.check_reg(4, 0x5F, 1)
    
    a._xor(5, 1, 2)
    a.check_reg(5, 0x5A, 2)
    
    # Shifts
    a.addi(6, 0, 1)
    a.slli(7, 6, 5)
    a.check_reg(7, 32, 3)
    
    # Negative number arithmetic
    a.addi(8, 0, -1)
    a.addi(9, 0, 1)
    a.add(10, 8, 9)
    a.check_reg(10, 0, 4)
    
    # Signed vs unsigned compare
    a.slt(11, 8, 9)   # -1 < 1 signed = 1
    a.check_reg(11, 1, 5)
    
    a.sltu(12, 8, 9)  # 0xFFFFFFFF < 1 unsigned = 0
    a.check_reg(12, 0, 6)
    
    a.finalize_test(expected_x31=0)

def prog_selfcheck_shifts(a: Asm):
    """Shift operation tests with edge cases"""
    a.init_test()
    
    # Logical left shift
    a.li(1, 0x00000001)
    a.slli(2, 1, 31)
    a.check_reg(2, 0x80000000, 0)
    
    # Logical right shift
    a.srli(3, 2, 1)
    a.check_reg(3, 0x40000000, 1)
    
    # Arithmetic right shift (preserves sign)
    a.srai(4, 2, 1)
    a.check_reg(4, 0xC0000000, 2)
    
    # Variable shift with masking
    a.addi(5, 0, 32)  # Should be masked to 0
    a.sll(6, 1, 5)
    a.check_reg(6, 1, 3)  # 1 << 0 = 1
    
    a.finalize_test(expected_x31=0)

def prog_selfcheck_comprehensive(a: Asm):
    """Comprehensive test covering multiple aspects"""
    a.init_test()
    
    # 1. Basic arithmetic
    a.li(1, 100)
    a.li(2, 200)
    a.add(3, 1, 2)
    a.check_reg(3, 300, 0)
    
    # 2. LUI test
    a.lui(4, 0x12345)
    a.check_reg(4, 0x12345000, 1)
    
    # 3. Full 32-bit load and verify
    a.li(5, 0xABCD1234)
    a.check_reg(5, 0xABCD1234, 2)
    
    # 4. Overflow behavior
    a.li(6, 0xFFFFFFFF)
    a.addi(7, 6, 1)
    a.check_reg(7, 0, 3)
    
    # 5. Sign extension
    a.addi(8, 0, -1)
    a.check_reg(8, 0xFFFFFFFF, 4)
    
    # 6. x0 immutability
    a.addi(0, 0, 999)
    a.add(9, 0, 0)
    a.check_reg(9, 0, 5)
    
    a.finalize_test(expected_x31=0)

# -------------------------
# Control Hazard Tests (Branches and Jumps)
# -------------------------

def prog_branch_basic(a: Asm):
    """Basic branch tests with self-checking"""
    a.init_test()
    
    # Test 1: BEQ taken (5 == 5)
    a.addi(1, 0, 5)
    a.addi(2, 0, 5)
    a.addi(10, 0, 0)    # x10 will track if we took the right path
    a.beq(1, 2, "L1")
    a.addi(10, 10, 1)   # Should be skipped (poison)
    a.label("L1")
    a.check_reg(10, 0, 0)  # x10 should still be 0
    
    # Test 2: BNE not taken (7 == 7)
    a.addi(3, 0, 7)
    a.addi(4, 0, 7)
    a.addi(11, 0, 0)
    a.bne(3, 4, "L2")
    a.addi(11, 11, 2)   # Should execute
    a.label("L2")
    a.check_reg(11, 2, 1)
    
    # Test 3: BLT taken (signed: -1 < 1)
    a.addi(5, 0, -1)
    a.addi(6, 0, 1)
    a.addi(12, 0, 0)
    a.blt(5, 6, "L3")
    a.addi(12, 12, 4)   # Should be skipped (poison)
    a.label("L3")
    a.check_reg(12, 0, 2)
    
    # Test 4: BLTU not taken (unsigned: 0xFFFFFFFF >= 1)
    a.addi(13, 0, 0)
    a.bltu(5, 6, "L4")
    a.addi(13, 13, 8)   # Should execute
    a.label("L4")
    a.check_reg(13, 8, 3)
    
    # Test 5: BGE taken (1 >= 1)
    a.addi(7, 0, 1)
    a.addi(8, 0, 1)
    a.addi(14, 0, 0)
    a.bge(7, 8, "L5")
    a.addi(14, 14, 16)  # Should be skipped
    a.label("L5")
    a.check_reg(14, 0, 4)
    
    # Test 6: BGEU not taken (1 < 2 unsigned)
    a.addi(9, 0, 2)
    a.addi(15, 0, 0)
    a.bgeu(7, 9, "L6")
    a.addi(15, 15, 32)  # Should execute
    a.label("L6")
    a.check_reg(15, 32, 5)
    
    a.finalize_test(expected_x31=0)

def prog_branch_loop(a: Asm):
    """Loop test using backward branch"""
    a.init_test()
    
    # Sum 1..5 in x10
    a.addi(10, 0, 0)   # sum = 0
    a.addi(11, 0, 1)   # i = 1
    a.addi(12, 0, 6)   # limit = 6
    
    a.label("LOOP")
    a.add(10, 10, 11)  # sum += i
    a.addi(11, 11, 1)  # i++
    a.bne(11, 12, "LOOP")
    
    # Expected: 1+2+3+4+5 = 15
    a.check_reg(10, 15, 0)
    a.check_reg(11, 6, 1)
    
    a.finalize_test(expected_x31=0)

def prog_jal_basic(a: Asm):
    """JAL (jump and link) test"""
    a.init_test()
    
    # JAL should:
    # 1. Jump to target
    # 2. Store return address (PC+4) in rd
    a.addi(10, 0, 0)
    
    # Get current PC using AUIPC
    a.auipc(1, 0)      # x1 = current PC
    
    a.jal(5, "TARGET")
    a.addi(10, 10, 1)  # Should be skipped (poison)
    
    a.label("TARGET")
    # x5 should contain return address (PC of JAL + 4)
    # We'll verify by computing expected value
    a.check_reg(10, 0, 0)  # Poison should not have executed
    
    # Check that we can return using JALR
    a.addi(11, 0, 99)  # Mark that we reached target
    a.jalr(0, 5, 0)    # Return (jump to address in x5, discard return addr)
    a.addi(11, 11, 1)  # Should execute after return
    
    a.check_reg(11, 100, 1)
    
    a.finalize_test(expected_x31=0)

def prog_jalr_indirect(a: Asm):
    """JALR (jump and link register) with address masking"""
    a.init_test()
    
    a.addi(10, 0, 0)   # tracker
    
    # Test 1: JALR with even address
    a.jal(1, "SETUP1")
    a.label("RETURN1")
    a.addi(10, 10, 1)  # Should execute after JALR returns
    a.jal(0, "TEST2")
    
    a.label("SETUP1")
    a.jalr(0, 1, 0)    # Return to RETURN1
    
    # Test 2: JALR with odd address (should mask LSB to 0)
    a.label("TEST2")
    a.jal(1, "SETUP2")
    a.label("RETURN2")
    a.addi(10, 10, 2)  # Should execute
    a.jal(0, "END")
    
    a.label("SETUP2")
    a.addi(2, 1, 1)    # x2 = return address + 1 (odd)
    a.jalr(0, 2, 0)    # Should jump to even address (mask LSB)
    
    a.label("END")
    a.check_reg(10, 3, 0)
    
    a.finalize_test(expected_x31=0)

def prog_branch_matrix(a: Asm):
    """Comprehensive branch condition matrix"""
    a.init_test()
    
    # Test all 6 branch types with different operand combinations
    a.addi(1, 0, -5)   # negative
    a.addi(2, 0, 5)    # positive
    a.addi(3, 0, 5)    # equal to x2
    a.addi(4, 0, 0)    # zero
    
    a.addi(10, 0, 0)   # accumulator for test results
    
    # BEQ: -5 == 5? No
    a.beq(1, 2, "SKIP1")
    a.addi(10, 10, 1)
    a.label("SKIP1")
    
    # BEQ: 5 == 5? Yes
    a.beq(2, 3, "TAKE1")
    a.addi(10, 10, 2)  # poison
    a.label("TAKE1")
    
    # BNE: 5 != 0? Yes
    a.bne(2, 4, "TAKE2")
    a.addi(10, 10, 4)  # poison
    a.label("TAKE2")
    
    # BLT signed: -5 < 5? Yes
    a.blt(1, 2, "TAKE3")
    a.addi(10, 10, 8)  # poison
    a.label("TAKE3")
    
    # BLT signed: 5 < -5? No
    a.blt(2, 1, "SKIP2")
    a.addi(10, 10, 16)
    a.label("SKIP2")
    
    # BGE signed: 5 >= 5? Yes
    a.bge(2, 3, "TAKE4")
    a.addi(10, 10, 32)  # poison
    a.label("TAKE4")
    
    # BLTU unsigned: 0xFFFFFFFB < 5? No (large unsigned)
    a.bltu(1, 2, "SKIP3")
    a.addi(10, 10, 64)
    a.label("SKIP3")
    
    # BGEU unsigned: 0xFFFFFFFB >= 5? Yes
    a.bgeu(1, 2, "TAKE5")
    a.addi(10, 10, 128)  # poison
    a.label("TAKE5")
    
    # Expected: 1 + 16 + 64 = 81
    a.check_reg(10, 81, 0)
    
    a.finalize_test(expected_x31=0)

def prog_nested_branches(a: Asm):
    """Nested branch structures"""
    a.init_test()
    
    a.addi(1, 0, 10)
    a.addi(2, 0, 20)
    a.addi(10, 0, 0)
    
    # if (x1 < x2) {
    a.bge(1, 2, "ELSE1")
    #   if (x1 < 15) {
    a.addi(3, 0, 15)
    a.bge(1, 3, "ELSE2")
    #     x10 = 1
    a.addi(10, 0, 1)
    a.jal(0, "END1")
    #   } else {
    a.label("ELSE2")
    #     x10 = 2
    a.addi(10, 0, 2)
    #   }
    a.jal(0, "END1")
    # } else {
    a.label("ELSE1")
    #   x10 = 3
    a.addi(10, 0, 3)
    # }
    a.label("END1")
    
    a.check_reg(10, 1, 0)
    
    a.finalize_test(expected_x31=0)

def prog_forward_backward(a: Asm):
    """Mix of forward and backward branches"""
    a.init_test()
    
    a.addi(10, 0, 0)
    a.addi(1, 0, 0)    # counter
    a.addi(2, 0, 3)    # limit
    
    # Forward branch over initialization
    a.jal(0, "LOOP_START")
    a.addi(10, 0, 999)  # poison
    
    a.label("LOOP_START")
    # Loop body
    a.label("LOOP")
    a.addi(10, 10, 10)
    a.addi(1, 1, 1)
    a.bne(1, 2, "LOOP")  # backward branch
    
    # Forward branch to skip
    a.beq(1, 2, "SKIP")
    a.addi(10, 10, 1)    # poison
    
    a.label("SKIP")
    # Expected: 10 * 3 = 30
    a.check_reg(10, 30, 0)
    
    a.finalize_test(expected_x31=0)

def prog_mem_lw_sw_basic(a: Asm):
    a.init_test()

    # Base pointer (choose any RAM base your TB maps; 0x100 is common in small sims)
    a.li(20, 0x00000100, "mem base")

    a.li(1, 0x11223344, "pattern")
    a.sw(1, 20, 0)               # [base+0] = 0x11223344
    a.lw(2, 20, 0)               # x2 = [base+0]
    a.check_reg(2, 0x11223344, 0)

    # Overwrite and re-read (store->load)
    a.li(1, 0xA5A5A5A5, "pattern2")
    a.sw(1, 20, 0)
    a.lw(2, 20, 0)
    a.check_reg(2, 0xA5A5A5A5, 1)

    a.finalize_test(expected_x31=0)

def prog_mem_byte_signext(a: Asm):
    a.init_test()
    a.li(20, 0x00000100, "mem base")

    # Write 0x80 as a byte
    a.addi(1, 0, 0x80)           # 0x00000080
    a.sb(1, 20, 4)               # [base+4] = 0x80

    a.lb(2, 20, 4)               # sign-extend: 0xFFFFFF80
    a.check_reg(2, 0xFFFFFF80, 0)

    a.lbu(3, 20, 4)              # zero-extend: 0x00000080
    a.check_reg(3, 0x00000080, 1)

    a.finalize_test(expected_x31=0)

def prog_mem_half_signext(a: Asm):
    a.init_test()
    a.li(20, 0x00000100, "mem base")

    # Write 0x8001 as halfword
    a.li(1, 0x00008001, "half pattern")
    a.sh(1, 20, 8)               # [base+8..9] = 0x8001

    a.lh(2, 20, 8)               # sign-extend: 0xFFFF8001
    a.check_reg(2, 0xFFFF8001, 0)

    a.lhu(3, 20, 8)              # zero-extend: 0x00008001
    a.check_reg(3, 0x00008001, 1)

    a.finalize_test(expected_x31=0)

def prog_mem_endian_overlay(a: Asm):
    a.init_test()
    a.li(20, 0x00000100, "mem base")

    # Store word 0x11223344
    a.li(1, 0x11223344)
    a.sw(1, 20, 0)

    # Bytes at base+0..3 should be 44 33 22 11
    a.lbu(2, 20, 0); a.check_reg(2, 0x44, 0)
    a.lbu(3, 20, 1); a.check_reg(3, 0x33, 1)
    a.lbu(4, 20, 2); a.check_reg(4, 0x22, 2)
    a.lbu(5, 20, 3); a.check_reg(5, 0x11, 3)

    # Halfwords: base+0 => 0x3344, base+2 => 0x1122
    a.lhu(6, 20, 0); a.check_reg(6, 0x3344, 4)
    a.lhu(7, 20, 2); a.check_reg(7, 0x1122, 5)

    a.finalize_test(expected_x31=0)





# ==========================================
# ADVANCED RV32I TESTS - Add these to your TESTS dict
# ==========================================

def prog_raw_data_hazards(a: Asm):
    """Test RAW (Read-After-Write) data hazards - critical for OOO"""
    a.init_test()
    
    # Back-to-back dependency chain
    a.addi(1, 0, 10)
    a.addi(2, 1, 5)    # RAW on x1
    a.addi(3, 2, 3)    # RAW on x2
    a.addi(4, 3, 2)    # RAW on x3
    a.check_reg(4, 20, 0)
    
    # Multiple consumers of same producer
    a.addi(5, 0, 100)
    a.add(6, 5, 5)     # RAW on x5
    a.sub(7, 5, 6)     # RAW on x5 and x6
    a._xor(8, 5, 7)    # RAW on x5 and x7
    a.check_reg(6, 200, 1)
    a.check_reg(7, -100 & 0xFFFFFFFF, 2)
    
    # Long dependency chain with different ops
    a.addi(10, 0, 1)
    a.slli(11, 10, 4)   # 16
    a.add(12, 11, 10)   # 17
    a.sub(13, 12, 11)   # 1
    a._or(14, 13, 12)   # 17
    a.check_reg(14, 17, 3)
    
    a.finalize_test(expected_x31=0)

def prog_war_waw_hazards(a: Asm):
    """Test WAR (Write-After-Read) and WAW (Write-After-Write) hazards"""
    a.init_test()
    
    # WAR hazard pattern
    a.addi(1, 0, 50)
    a.addi(2, 0, 30)
    a.add(3, 1, 2)     # Read x1, x2
    a.addi(1, 0, 999)  # Write x1 (WAR with previous read)
    a.check_reg(3, 80, 0)
    a.check_reg(1, 999, 1)
    
    # WAW hazard pattern
    a.addi(4, 0, 100)  # First write to x4
    a.addi(4, 0, 200)  # Second write to x4 (WAW)
    a.addi(4, 0, 300)  # Third write to x4 (WAW)
    a.check_reg(4, 300, 2)
    
    # Complex RAW/WAR/WAW mix
    a.addi(5, 0, 10)
    a.add(6, 5, 5)     # RAW on x5
    a.addi(5, 0, 20)   # WAW on x5, WAR with first add
    a.add(7, 5, 6)     # RAW on new x5 and x6
    a.check_reg(5, 20, 3)
    a.check_reg(6, 20, 4)
    a.check_reg(7, 40, 5)
    
    a.finalize_test(expected_x31=0)

def prog_load_use_hazard(a: Asm):
    """Test load-use hazards (load followed immediately by use)"""
    a.init_test()
    
    a.li(20, 0x00000100, "mem base")
    
    # Store some values
    a.li(1, 0x12345678)
    a.sw(1, 20, 0)
    a.li(2, 0xABCDEF00)
    a.sw(2, 20, 4)
    
    # Load-use hazard: load followed immediately by dependent instruction
    a.lw(3, 20, 0)     # Load
    a.add(4, 3, 3)     # Use immediately (load-use hazard)
    a.check_reg(4, 0x2468ACF0, 0)
    
    # Load-load-use pattern
    a.lw(5, 20, 0)
    a.lw(6, 20, 4)
    a.add(7, 5, 6)     # Use both loads
    a.check_reg(7, 0xBE024578, 1)
    
    # Load-branch hazard
    a.li(8, 42)
    a.sw(8, 20, 8)
    a.lw(9, 20, 8)
    a.addi(10, 0, 42)
    a.beq(9, 10, "LOAD_BR_OK")
    a.addi(11, 0, 999)  # poison
    a.jal(0, "LOAD_BR_END")
    a.label("LOAD_BR_OK")
    a.addi(11, 0, 123)
    a.label("LOAD_BR_END")
    a.check_reg(11, 123, 2)
    
    a.finalize_test(expected_x31=0)

def prog_store_load_forwarding(a: Asm):
    """Test store-to-load forwarding and aliasing"""
    a.init_test()
    
    a.li(20, 0x00000100, "mem base")
    
    # Basic store-load forwarding (same address)
    a.li(1, 0xCAFEBABE)
    a.sw(1, 20, 0)
    a.lw(2, 20, 0)     # Should get forwarded value
    a.check_reg(2, 0xCAFEBABE, 0)
    
    # Partial forwarding: store byte, load word
    a.li(3, 0xFF)
    a.sb(3, 20, 0)     # Only modify byte 0
    a.lw(4, 20, 0)     # Load full word
    a.check_reg(4, 0xCAFEBAFF, 1)
    
    # Store-load with offset
    a.li(5, 0x11223344)
    a.sw(5, 20, 12)
    a.lw(6, 20, 12)
    a.check_reg(6, 0x11223344, 2)
    
    # Multiple stores to different addresses
    a.li(7, 0xAAAAAAAA)
    a.li(8, 0xBBBBBBBB)
    a.sw(7, 20, 16)
    a.sw(8, 20, 20)
    a.lw(9, 20, 16)
    a.lw(10, 20, 20)
    a.check_reg(9, 0xAAAAAAAA, 3)
    a.check_reg(10, 0xBBBBBBBB, 4)
    
    # Store halfword, load word (overlapping)
    a.li(11, 0x0)
    a.sw(11, 20, 24)
    a.li(12, 0xCCDD)
    a.sh(12, 20, 24)
    a.lw(13, 20, 24)
    a.check_reg(13, 0x0000CCDD, 5)
    
    a.finalize_test(expected_x31=0)

def prog_memory_aliasing(a: Asm):
    """Test memory aliasing and address calculation edge cases"""
    a.init_test()
    
    a.li(20, 0x00000100, "mem base")
    
    # Positive and negative offsets
    a.li(1, 0x12345678)
    a.sw(1, 20, 100)
    a.lw(2, 20, 100)
    a.check_reg(2, 0x12345678, 0)
    
    # Same address via different base+offset
    a.addi(21, 20, 50)   # x21 = base + 50
    a.li(3, 0xABCDEF01)
    a.sw(3, 21, 50)      # Store to base+100 via (base+50)+50
    a.lw(4, 20, 100)     # Load from base+100 via base+100
    a.check_reg(4, 0xABCDEF01, 1)
    
    # Negative offset
    a.addi(22, 20, 200)  # x22 = base + 200
    a.li(5, 0xFEEDFACE)
    a.sw(5, 22, -100)    # Store to base+100 via (base+200)-100
    a.lw(6, 20, 100)
    a.check_reg(6, 0xFEEDFACE, 2)
    
    # Sign extension of offset
    a.li(7, 0x99887766)
    a.sw(7, 20, -4)      # Negative offset with sign extension
    a.lw(8, 20, -4)
    a.check_reg(8, 0x99887766, 3)
    
    a.finalize_test(expected_x31=0)

def prog_branch_prediction_stress(a: Asm):
    """Stress test for branch prediction"""
    a.init_test()
    
    # Alternating taken/not-taken pattern
    a.addi(1, 0, 0)
    a.addi(2, 0, 0)  # counter
    a.addi(3, 0, 8)  # limit
    
    a.label("ALT_LOOP")
    a.andi(4, 2, 1)  # x4 = counter & 1
    a.beq(4, 0, "ALT_SKIP")  # Branch if even
    a.addi(1, 1, 10)
    a.label("ALT_SKIP")
    a.addi(2, 2, 1)
    a.bne(2, 3, "ALT_LOOP")
    
    # Should execute 4 times (when counter is odd)
    a.check_reg(1, 40, 0)
    
    # Always taken loop
    a.addi(5, 0, 0)
    a.addi(6, 0, 0)
    a.addi(7, 0, 10)
    a.label("TAKEN_LOOP")
    a.addi(5, 5, 1)
    a.addi(6, 6, 1)
    a.bne(6, 7, "TAKEN_LOOP")  # Always taken until last
    a.check_reg(5, 10, 1)
    
    # Never taken branches
    a.addi(8, 0, 100)
    a.beq(8, 0, "NEVER1")
    a.blt(8, 0, "NEVER2")
    a.addi(9, 0, 200)
    a.jal(0, "NEVER_END")
    a.label("NEVER1")
    a.label("NEVER2")
    a.addi(9, 0, 999)  # poison
    a.label("NEVER_END")
    a.check_reg(9, 200, 2)
    
    a.finalize_test(expected_x31=0)

def prog_deeply_nested_calls(a: Asm):
    """Test deeply nested function calls (JAL/JALR)"""
    a.init_test()
    
    # Simulated call stack using registers
    a.addi(10, 0, 0)  # result accumulator
    
    # Call chain: main -> f1 -> f2 -> f3 -> f4
    a.jal(1, "F1")
    a.addi(10, 10, 1)  # Back in main
    a.jal(0, "END_CALLS")
    
    a.label("F1")
    a.addi(10, 10, 10)
    a.addi(2, 1, 0)    # Save return addr
    a.jal(1, "F2")
    a.addi(10, 10, 100)
    a.jalr(0, 2, 0)    # Return to main
    
    a.label("F2")
    a.addi(10, 10, 20)
    a.addi(3, 1, 0)    # Save return addr
    a.jal(1, "F3")
    a.addi(10, 10, 200)
    a.jalr(0, 3, 0)    # Return to F1
    
    a.label("F3")
    a.addi(10, 10, 30)
    a.addi(4, 1, 0)
    a.jal(1, "F4")
    a.addi(10, 10, 300)
    a.jalr(0, 4, 0)    # Return to F2
    
    a.label("F4")
    a.addi(10, 10, 40)
    a.jalr(0, 1, 0)    # Return to F3
    
    a.label("END_CALLS")
    # Expected: 10 + 20 + 30 + 40 + 300 + 200 + 100 + 1 = 701
    a.check_reg(10, 701, 0)
    
    a.finalize_test(expected_x31=0)

def prog_register_pressure(a: Asm):
    """Test high register pressure (use all registers)"""
    a.init_test()
    
    # Initialize all registers (except x0, x28-x31 which are used by check_reg)
    for i in range(1, 28):
        a.addi(i, 0, i * 10)
    
    # Check a few
    a.check_reg(1, 10, 0)
    a.check_reg(10, 100, 1)
    a.check_reg(27, 270, 2)
    
    # Perform operations using many registers
    a.add(1, 2, 3)    # x1 = 20 + 30 = 50
    a.add(4, 5, 6)    # x4 = 50 + 60 = 110
    a.add(7, 8, 9)    # x7 = 80 + 90 = 170
    a.add(10, 1, 4)   # x10 = 50 + 110 = 160
    a.add(11, 7, 10)  # x11 = 170 + 160 = 330
    
    a.check_reg(11, 330, 3)
    
    # Chain using many registers
    a.add(12, 13, 14)  # 130 + 140 = 270
    a.add(15, 16, 17)  # 160 + 170 = 330
    a.add(18, 12, 15)  # 270 + 330 = 600
    a.check_reg(18, 600, 4)
    
    a.finalize_test(expected_x31=0)

def prog_arithmetic_edge_cases(a: Asm):
    """Test arithmetic edge cases and overflow"""
    a.init_test()
    
    # Maximum positive + 1 = minimum negative (2's complement)
    a.li(1, 0x7FFFFFFF)
    a.addi(2, 1, 1)
    a.check_reg(2, 0x80000000, 0)
    
    # Minimum negative - 1 = maximum positive
    a.li(3, 0x80000000)
    a.addi(4, 3, -1)
    a.check_reg(4, 0x7FFFFFFF, 1)
    
    # Zero - zero = zero
    a.sub(5, 0, 0)
    a.check_reg(5, 0, 2)
    
    # Max unsigned + max unsigned
    a.li(6, 0xFFFFFFFF)
    a.add(7, 6, 6)
    a.check_reg(7, 0xFFFFFFFE, 3)
    
    # Multiply by 2 using shift vs add
    a.li(8, 123456)
    a.slli(9, 8, 1)
    a.add(10, 8, 8)
    a.check_reg(9, 246912, 4)
    a.check_reg(10, 246912, 5)
    
    # Division by 2 using shift (arithmetic)
    a.li(11, -100)
    a.srai(12, 11, 1)
    a.check_reg(12, -50 & 0xFFFFFFFF, 6)
    
    # Signed vs unsigned comparison edge
    a.li(13, 0xFFFFFFFF)  # -1 signed, max unsigned
    a.li(14, 0)
    a.slt(15, 13, 14)     # -1 < 0 signed? Yes
    a.sltu(16, 13, 14)    # max < 0 unsigned? No
    a.check_reg(15, 1, 7)
    a.check_reg(16, 0, 8)
    
    a.finalize_test(expected_x31=0)

def prog_shift_edge_cases(a: Asm):
    """Comprehensive shift edge case testing"""
    a.init_test()
    
    # Shift by 0
    a.li(1, 0x12345678)
    a.slli(2, 1, 0)
    a.srli(3, 1, 0)
    a.srai(4, 1, 0)
    a.check_reg(2, 0x12345678, 0)
    a.check_reg(3, 0x12345678, 1)
    a.check_reg(4, 0x12345678, 2)
    
    # Shift by 31 (maximum)
    a.li(5, 1)
    a.slli(6, 5, 31)
    a.check_reg(6, 0x80000000, 3)
    
    a.srli(7, 6, 31)
    a.check_reg(7, 1, 4)
    
    a.srai(8, 6, 31)  # Arithmetic shift of negative
    a.check_reg(8, 0xFFFFFFFF, 5)
    
    # Variable shift with upper bits set (should be masked to 5 bits)
    a.li(9, 0x12345678)
    a.li(10, 32)      # Should be masked to 0
    a.sll(11, 9, 10)
    a.check_reg(11, 0x12345678, 6)
    
    a.li(12, 33)      # Should be masked to 1
    a.sll(13, 9, 12)
    a.slli(14, 9, 1)
    a.check_reg(13, 0x2468ACF0, 7)
    a.check_reg(14, 0x2468ACF0, 8)
    
    # Shift pattern recognition
    a.li(15, 0xAAAAAAAA)
    a.srli(16, 15, 1)
    a.check_reg(16, 0x55555555, 9)
    
    # Arithmetic vs logical right shift
    a.li(17, 0x80000001)
    a.srli(18, 17, 1)  # Logical: 0x40000000
    a.srai(19, 17, 1)  # Arithmetic: 0xC0000000
    a.check_reg(18, 0x40000000, 10)
    a.check_reg(19, 0xC0000000, 11)
    
    a.finalize_test(expected_x31=0)

def prog_bitwise_patterns(a: Asm):
    """Test bitwise operations with various patterns"""
    a.init_test()
    
    # De Morgan's Laws: NOT(A AND B) = NOT(A) OR NOT(B)
    a.li(1, 0xAAAAAAAA)
    a.li(2, 0x55555555)
    a._and(3, 1, 2)
    a.xori(4, 3, 0xFFF)  # Invert lower 12 bits
    a.check_reg(3, 0, 0)
    
    # XOR with self = 0
    a._xor(5, 1, 1)
    a.check_reg(5, 0, 1)
    
    # XOR twice = identity
    a.li(6, 0x12345678)
    a.li(7, 0xABCDEF00)
    a._xor(8, 6, 7)
    a._xor(9, 8, 7)
    a.check_reg(9, 0x12345678, 2)
    
    # Bit masking patterns
    a.li(10, 0xFFFFFFFF)
    a.andi(11, 10, 0xFF)  # Extract low byte
    a.check_reg(11, 0xFF, 3)
    
    a.li(12, 0x12345678)
    a.andi(13, 12, 0xF00)  # Extract specific bits
    a.check_reg(13, 0x600, 4)
    
    # Set/clear/toggle bits
    a.li(14, 0x00000000)
    a.ori(15, 14, 0x0F0)   # Set bits
    a.check_reg(15, 0x0F0, 5)
    
    a.andi(16, 15, 0xFF0)  # Clear low nibble
    a.check_reg(16, 0x0F0, 6)
    
    a.xori(17, 16, 0x0FF)  # Toggle bits
    a.check_reg(17, 0x00F, 7)
    
    a.finalize_test(expected_x31=0)

def prog_immediate_edge_cases(a: Asm):
    """Test immediate value edge cases"""
    a.init_test()
    
    # Maximum positive 12-bit immediate (2047)
    a.addi(1, 0, 2047)
    a.check_reg(1, 2047, 0)
    
    # Minimum negative 12-bit immediate (-2048)
    a.addi(2, 0, -2048)
    a.check_reg(2, 0xFFFFF800, 1)
    
    # -1 immediate
    a.addi(3, 0, -1)
    a.check_reg(3, 0xFFFFFFFF, 2)
    
    # Zero immediate
    a.addi(4, 0, 0)
    a.check_reg(4, 0, 3)
    
    # LUI with max 20-bit immediate
    a.lui(5, 0xFFFFF)
    a.check_reg(5, 0xFFFFF000, 4)
    
    # LUI with sign bit set
    a.lui(6, 0x80000)
    a.check_reg(6, 0x80000000, 5)
    
    # SLTI with edge values
    a.li(7, -1)
    a.slti(8, 7, 0)
    a.check_reg(8, 1, 6)  # -1 < 0
    
    a.slti(9, 0, -1)
    a.check_reg(9, 0, 7)  # 0 < -1? No
    
    # SLTIU with max unsigned
    a.li(10, 0xFFFFFFFF)
    a.sltiu(11, 10, -1)  # Compare with sign-extended -1 (0xFFFFFFFF)
    a.check_reg(11, 0, 8)  # Equal, not less
    
    a.finalize_test(expected_x31=0)

def prog_memory_boundary(a: Asm):
    """Test memory access at boundaries"""
    a.init_test()
    
    a.li(20, 0x00000100, "mem base")
    
    # Word-aligned accesses
    a.li(1, 0x11111111)
    a.sw(1, 20, 0)
    a.li(2, 0x22222222)
    a.sw(2, 20, 4)
    a.li(3, 0x33333333)
    a.sw(3, 20, 8)
    
    # Verify alignment
    a.lw(4, 20, 0)
    a.lw(5, 20, 4)
    a.lw(6, 20, 8)
    a.check_reg(4, 0x11111111, 0)
    a.check_reg(5, 0x22222222, 1)
    a.check_reg(6, 0x33333333, 2)
    
    # Halfword at boundaries
    a.li(7, 0xAAAA)
    a.sh(7, 20, 12)
    a.sh(7, 20, 14)
    a.lhu(8, 20, 12)
    a.lhu(9, 20, 14)
    a.check_reg(8, 0xAAAA, 3)
    a.check_reg(9, 0xAAAA, 4)
    
    # Bytes at word boundaries
    a.li(10, 0xFF)
    a.sb(10, 20, 16)
    a.sb(10, 20, 17)
    a.sb(10, 20, 18)
    a.sb(10, 20, 19)
    a.lw(11, 20, 16)
    a.check_reg(11, 0xFFFFFFFF, 5)
    
    # Large offset
    a.li(12, 0xBEEFCAFE)
    a.sw(12, 20, 2044)  # Near max 12-bit offset
    a.lw(13, 20, 2044)
    a.check_reg(13, 0xBEEFCAFE, 6)
    
    a.finalize_test(expected_x31=0)

def prog_long_dependency_chain(a: Asm):
    """Very long dependency chain to stress OOO scheduler"""
    a.init_test()
    
    # Create a chain of 20 dependent instructions
    a.addi(1, 0, 1)
    for i in range(2, 22):
        a.addi(i, i-1, 1)
    
    # x21 should be 21
    a.check_reg(21, 21, 0)
    
    # Fibonacci-like sequence
    a.addi(1, 0, 1)
    a.addi(2, 0, 1)
    a.add(3, 1, 2)   # 2
    a.add(4, 2, 3)   # 3
    a.add(5, 3, 4)   # 5
    a.add(6, 4, 5)   # 8
    a.add(7, 5, 6)   # 13
    a.add(8, 6, 7)   # 21
    a.add(9, 7, 8)   # 34
    a.add(10, 8, 9)  # 55
    a.check_reg(10, 55, 1)
    
    a.finalize_test(expected_x31=0)

def prog_mixed_operations_stress(a: Asm):
    """Mix all operation types to stress issue logic"""
    a.init_test()
    
    a.li(20, 0x00000200, "mem base")
    
    # Rapid switching between ALU, load, store, branch
    a.addi(1, 0, 10)
    a.sw(1, 20, 0)
    a.addi(2, 1, 5)
    a.lw(3, 20, 0)
    a.add(4, 2, 3)
    a.check_reg(4, 25, 0)
    
    a.slli(5, 4, 2)
    a.sw(5, 20, 4)
    a._xor(6, 4, 5)
    a.lw(7, 20, 4)
    a.check_reg(7, 100, 1)
    
    # Mix with branches
    a.beq(6, 6, "MIX1")
    a.addi(8, 0, 999)  # poison
    a.label("MIX1")
    a.lw(8, 20, 0)
    a.add(9, 8, 7)
    a.check_reg(9, 110, 2)
    
    # More complex mix
    a.lui(10, 0x12345)
    a.ori(11, 10, 0x678)
    a.sw(11, 20, 8)
    a.srli(12, 11, 4)
    a.lw(13, 20, 8)
    a._and(14, 12, 13)
    a.check_reg(14, 0x01234578, 3)
    
    a.finalize_test(expected_x31=0)

def prog_auipc_pc_relative(a: Asm):
    """Test AUIPC and PC-relative addressing"""
    a.init_test()
    
    # AUIPC gives current PC + (imm << 12)
    a.auipc(1, 0)      # x1 = current PC
    a.auipc(2, 1)      # x2 = PC + 0x1000
    a.sub(3, 2, 1)     # x3 = 0x1000
    a.check_reg(3, 0x1000, 0)
    
    # Use AUIPC for PC-relative data access
    a.auipc(4, 0)
    a.addi(5, 4, 32)   # Point 32 bytes ahead
    
    # AUIPC with JAL for long jumps
    a.auipc(6, 0)
    a.addi(7, 6, 4)    # Next instruction
    a.check_reg(7, a.pc() + 4, 1)
    
    a.finalize_test(expected_x31=0)

def prog_control_flow_chaos(a: Asm):
    """Chaotic control flow to stress branch predictor"""
    a.init_test()
    
    a.addi(10, 0, 0)  # result
    
    # Jump table simulation
    a.addi(1, 0, 2)
    a.beq(1, 0, "CASE0")
    a.addi(2, 1, -1)
    a.beq(2, 0, "CASE1")
    a.addi(3, 2, -1)
    a.beq(3, 0, "CASE2")
    a.jal(0, "CASE_DEFAULT")
    
    a.label("CASE0")
    a.addi(10, 10, 1)
    a.jal(0, "CASE_END")
    
    a.label("CASE1")
    a.addi(10, 10, 10)
    a.jal(0, "CASE_END")
    
    a.label("CASE2")
    a.addi(10, 10, 100)
    a.jal(0, "CASE_END")
    
    a.label("CASE_DEFAULT")
    a.addi(10, 10, 1000)
    
    a.label("CASE_END")
    a.check_reg(10, 100, 0)
    
    # Nested ternary-like pattern
    a.li(4, 5)
    a.li(5, 10)
    a.blt(4, 5, "TERN1_TRUE")
    a.addi(11, 0, 0)
    a.jal(0, "TERN1_END")
    a.label("TERN1_TRUE")
    a.bge(4, 0, "TERN2_TRUE")
    a.addi(11, 0, 1)
    a.jal(0, "TERN1_END")
    a.label("TERN2_TRUE")
    a.addi(11, 0, 2)
    a.label("TERN1_END")
    a.check_reg(11, 2, 1)
    
    a.finalize_test(expected_x31=0)

def prog_stress_reorder_buffer(a: Asm):
    """Stress the reorder buffer with many in-flight instructions"""
    a.init_test()
    
    # Create many independent operations
    a.addi(1, 0, 1)
    a.addi(2, 0, 2)
    a.addi(3, 0, 3)
    a.addi(4, 0, 4)
    a.addi(5, 0, 5)
    a.addi(6, 0, 6)
    a.addi(7, 0, 7)
    a.addi(8, 0, 8)
    a.addi(9, 0, 9)
    a.addi(10, 0, 10)
    
    # Now use them all
    a.add(11, 1, 2)
    a.add(12, 3, 4)
    a.add(13, 5, 6)
    a.add(14, 7, 8)
    a.add(15, 11, 12)
    a.add(16, 13, 14)
    a.add(17, 15, 16)
    a.add(18, 17, 9)
    a.add(19, 18, 10)
    
    # Expected: (1+2+3+4) + (5+6+7+8) + 9 + 10 = 55
    a.check_reg(19, 55, 0)
    
    a.finalize_test(expected_x31=0)

def prog_exception_boundary_test(a: Asm):
    """Test instruction sequences that might cause pipeline exceptions"""
    a.init_test()
    
    # x0 write attempts (should be ignored)
    a.addi(0, 0, 999)
    a.lui(0, 0x12345)
    a.add(0, 1, 2)
    a.check_reg(0, 0, 0)  # x0 should still be 0
    
    # Read from x0
    a.add(1, 0, 0)
    a.addi(2, 0, 100)
    a.add(3, 1, 2)
    a.check_reg(3, 100, 1)
    
    # Use x0 as both source and dest
    a.add(0, 0, 0)
    a._xor(0, 0, 0)
    a.check_reg(0, 0, 2)
    
    a.finalize_test(expected_x31=0)

def prog_comprehensive_memory(a: Asm):
    """Comprehensive memory test covering all load/store combinations"""
    a.init_test()
    
    a.li(20, 0x00000300, "mem base")
    
    # Test all store sizes
    a.li(1, 0x12345678)
    a.sw(1, 20, 0)
    a.sh(1, 20, 4)
    a.sb(1, 20, 6)
    
    # Test all load sizes with sign extension
    a.lw(2, 20, 0)
    a.check_reg(2, 0x12345678, 0)
    
    a.lh(3, 20, 4)
    a.check_reg(3, 0x00005678, 1)  # Sign extension of 0x5678
    
    a.lhu(4, 20, 4)
    a.check_reg(4, 0x00005678, 2)  # Zero extension
    
    a.lb(5, 20, 6)
    a.check_reg(5, 0x00000078, 3)  # Sign extension of 0x78
    
    a.lbu(6, 20, 6)
    a.check_reg(6, 0x00000078, 4)  # Zero extension
    
    # Test negative sign extension
    a.li(7, 0x80)
    a.sb(7, 20, 8)
    a.lb(8, 20, 8)
    a.check_reg(8, 0xFFFFFF80, 5)  # Sign extended
    
    a.li(9, 0x8000)
    a.sh(9, 20, 10)
    a.lh(10, 20, 10)
    a.check_reg(10, 0xFFFF8000, 6)  # Sign extended
    
    a.finalize_test(expected_x31=0)

def prog_bubble_sort(a: Asm):
    """Bubble sort algorithm - tests loops, branches, and memory"""
    a.init_test()
    
    a.li(20, 0x00000400, "array base")
    
    # Initialize array: [5, 2, 8, 1, 9]
    a.li(1, 5)
    a.sw(1, 20, 0)
    a.li(1, 2)
    a.sw(1, 20, 4)
    a.li(1, 8)
    a.sw(1, 20, 8)
    a.li(1, 1)
    a.sw(1, 20, 12)
    a.li(1, 9)
    a.sw(1, 20, 16)
    
    # Bubble sort
    a.addi(10, 0, 5)   # n = 5
    a.addi(11, 0, 0)   # i = 0
    
    a.label("OUTER_LOOP")
    a.addi(12, 0, 0)   # j = 0
    a.sub(13, 10, 11)
    a.addi(13, 13, -1) # limit = n - i - 1
    
    a.label("INNER_LOOP")
    # Load arr[j] and arr[j+1]
    a.slli(14, 12, 2)  # j * 4
    a.add(15, 20, 14)  # base + j*4
    a.lw(16, 15, 0)    # arr[j]
    a.lw(17, 15, 4)    # arr[j+1]
    
    # if arr[j] > arr[j+1], swap
    a.bge(17, 16, "NO_SWAP")
    a.sw(17, 15, 0)
    a.sw(16, 15, 4)
    
    a.label("NO_SWAP")
    a.addi(12, 12, 1)  # j++
    a.blt(12, 13, "INNER_LOOP")
    
    a.addi(11, 11, 1)  # i++
    a.blt(11, 10, "OUTER_LOOP")
    
    # Verify sorted: [1, 2, 5, 8, 9]
    a.lw(1, 20, 0)
    a.check_reg(1, 1, 0)
    a.lw(2, 20, 4)
    a.check_reg(2, 2, 1)
    a.lw(3, 20, 8)
    a.check_reg(3, 5, 2)
    a.lw(4, 20, 12)
    a.check_reg(4, 8, 3)
    a.lw(5, 20, 16)
    a.check_reg(5, 9, 4)
    
    a.finalize_test(expected_x31=0)

def prog_factorial(a: Asm):
    """Factorial calculation - recursive style simulation"""
    a.init_test()
    
    # Calculate 6! = 720 iteratively
    a.addi(1, 0, 1)    # result = 1
    a.addi(2, 0, 1)    # i = 1
    a.addi(3, 0, 7)    # limit = 7
    
    a.label("FACT_LOOP")
    a.addi(2, 2, 1)    # i++
    # result *= i
    a.add(4, 0, 0)     # temp = 0
    a.add(5, 0, 2)     # counter = i
    
    a.label("MULT_LOOP")
    a.add(4, 4, 1)     # temp += result
    a.addi(5, 5, -1)   # counter--
    a.bne(5, 0, "MULT_LOOP")
    
    a.add(1, 4, 0)     # result = temp
    a.bne(2, 3, "FACT_LOOP")
    
    a.check_reg(1, 720, 0)
    
    a.finalize_test(expected_x31=0)

def prog_gcd_euclidean(a: Asm):
    """Greatest Common Divisor using Euclidean algorithm"""
    a.init_test()
    
    # GCD(48, 18) = 6
    a.addi(1, 0, 48)   # a
    a.addi(2, 0, 18)   # b
    
    a.label("GCD_LOOP")
    a.beq(2, 0, "GCD_DONE")
    
    # temp = a % b (using repeated subtraction)
    a.add(3, 1, 0)     # temp = a
    a.label("MOD_LOOP")
    a.blt(3, 2, "MOD_DONE")
    a.sub(3, 3, 2)
    a.jal(0, "MOD_LOOP")
    a.label("MOD_DONE")
    
    # a = b, b = temp
    a.add(1, 2, 0)
    a.add(2, 3, 0)
    a.jal(0, "GCD_LOOP")
    
    a.label("GCD_DONE")
    a.check_reg(1, 6, 0)
    
    a.finalize_test(expected_x31=0)

def prog_recursive_factorial(a: Asm):
    """True recursive factorial using stack simulation"""
    a.init_test()
    a.li(20, 0x00001000, "stack pointer")
    
    # Calculate factorial(5) = 120
    a.addi(10, 0, 5)  # n = 5
    a.jal(1, "FACTORIAL")
    a.check_reg(11, 120, 0)
    a.jal(0, "END")
    
    a.label("FACTORIAL")
    # Base case: if n <= 1, return 1
    a.addi(2, 0, 1)
    a.bge(10, 2, "RECURSE")
    a.addi(11, 0, 1)
    a.jalr(0, 1, 0)
    
    a.label("RECURSE")
    # Save return address and n
    a.sw(1, 20, 0)   # Push return addr
    a.sw(10, 20, 4)  # Push n
    a.addi(20, 20, 8)
    
    # factorial(n-1)
    a.addi(10, 10, -1)
    a.jal(1, "FACTORIAL")
    
    # Restore and compute n * factorial(n-1)
    a.addi(20, 20, -8)
    a.lw(10, 20, 4)  # Pop n
    a.lw(1, 20, 0)   # Pop return addr
    
    # Multiply n * result (using repeated addition)
    a.add(12, 0, 0)
    a.add(13, 0, 10)
    a.label("MUL_LOOP")
    a.beq(13, 0, "MUL_DONE")
    a.add(12, 12, 11)
    a.addi(13, 13, -1)
    a.jal(0, "MUL_LOOP")
    a.label("MUL_DONE")
    a.add(11, 12, 0)
    a.jalr(0, 1, 0)
    
    a.label("END")
    a.finalize_test(expected_x31=0)

def prog_instruction_mix(a: Asm):
    """Test diverse instruction mix for IPC measurement"""
    a.init_test()
    a.li(20, 0x00000500, "mem base")
    
    # Deliberately create a mix:
    # - 40% ALU ops
    # - 30% memory ops
    # - 20% branches
    # - 10% jumps
    
    for i in range(10):
        # ALU cluster
        a.addi(1, 1, i)
        a.add(2, 1, 2)
        a._xor(3, 2, 1)
        a.slli(4, 3, 2)
        
        # Memory cluster
        a.sw(4, 20, i*4)
        a.lw(5, 20, i*4)
        a.add(6, 5, 4)
        
        # Branch (use unique label for each iteration)
        a.bne(6, 0, f"SKIP_{i}")
        a.addi(7, 0, 999)
        a.label(f"SKIP_{i}")
        
        # Jump
        if i % 3 == 0:
            a.jal(8, f"CONT_{i}")
            a.label(f"CONT_{i}")
    
    a.finalize_test(expected_x31=0)

def prog_memory_ordering(a: Asm):
    """Test memory operation ordering"""
    a.init_test()
    a.li(20, 0x00000600, "mem base")
    
    # Write X, write Y, read Y, read X
    a.li(1, 0xAAAA)
    a.sw(1, 20, 0)   # Write X
    a.li(2, 0xBBBB)
    a.sw(2, 20, 4)   # Write Y
    a.lw(3, 20, 4)   # Read Y (should see 0xBBBB)
    a.lw(4, 20, 0)   # Read X (should see 0xAAAA)
    a.check_reg(3, 0xBBBB, 0)
    a.check_reg(4, 0xAAAA, 1)
    
    # Write-read-write same location
    a.li(5, 0x1111)
    a.sw(5, 20, 8)
    a.lw(6, 20, 8)
    a.li(7, 0x2222)
    a.sw(7, 20, 8)
    a.lw(8, 20, 8)
    a.check_reg(6, 0x1111, 2)
    a.check_reg(8, 0x2222, 3)
    
    a.finalize_test(expected_x31=0)

def prog_power_virus(a: Asm):
    """Maximum switching activity test"""
    a.init_test()
    
    # Toggle all bits rapidly
    for _ in range(20):
        a.li(1, 0xAAAAAAAA)
        a.li(2, 0x55555555)
        a._xor(3, 1, 2)
        a._xor(4, 2, 1)
        a.add(5, 3, 4)
        a.sub(6, 5, 3)
    
    a.finalize_test(expected_x31=0)

def prog_jalr_corner_cases(a: Asm):
    """JALR edge cases and return address stack stress"""
    a.init_test()
    
    # JALR with rd=rs1 (overwrites return address)
    a.jal(1, "TARGET1")
    a.label("RETURN1")
    a.addi(10, 0, 1)
    a.jal(0, "END")
    
    a.label("TARGET1")
    a.jalr(1, 1, 0)  # rd=rs1, should still work
    
    # JALR with offset
    a.label("TARGET2")
    a.auipc(2, 0)
    a.addi(2, 2, 12)  # Point 12 bytes ahead
    a.jalr(3, 2, 0)
    a.addi(10, 0, 999)  # poison
    
    a.label("END")
    a.check_reg(10, 1, 0)
    a.finalize_test(expected_x31=0)

def prog_pipeline_flushes(a: Asm):
    """Test scenarios that cause pipeline flushes"""
    a.init_test()
    
    # Mispredicted branch followed by dependent load
    a.li(20, 0x00000800, "mem base")
    a.addi(1, 0, 10)
    a.beq(1, 0, "SKIP")  # Not taken, may mispredict
    a.sw(1, 20, 0)
    a.label("SKIP")
    a.lw(2, 20, 0)
    a.check_reg(2, 10, 0)
    
    # Jump after branch
    a.addi(3, 0, 5)
    a.bne(3, 0, "TARGET")
    a.addi(4, 0, 999)
    a.label("TARGET")
    a.jal(0, "CONT")
    a.addi(4, 0, 999)
    a.label("CONT")
    
    a.finalize_test(expected_x31=0)

def prog_binary_search(a: Asm):
    """Binary search algorithm"""
    a.init_test()
    a.li(20, 0x00000900, "array base")
    
    # Sorted array: [1, 3, 5, 7, 9, 11, 13, 15]
    for i, val in enumerate([1, 3, 5, 7, 9, 11, 13, 15]):
        a.li(1, val)
        a.sw(1, 20, i * 4)
    
    # Search for 9 (index 4)
    a.addi(2, 0, 9)   # target
    a.addi(3, 0, 0)   # left
    a.addi(4, 0, 7)   # right
    
    a.label("BSEARCH")
    a.bge(3, 4, "NOT_FOUND")
    
    # mid = (left + right) / 2
    a.add(5, 3, 4)
    a.srli(5, 5, 1)
    
    # Load arr[mid]
    a.slli(6, 5, 2)
    a.add(6, 20, 6)
    a.lw(7, 6, 0)
    
    # Compare
    a.beq(7, 2, "FOUND")
    a.blt(7, 2, "GO_RIGHT")
    # Go left
    a.addi(4, 5, -1)
    a.jal(0, "BSEARCH")
    
    a.label("GO_RIGHT")
    a.addi(3, 5, 1)
    a.jal(0, "BSEARCH")
    
    a.label("FOUND")
    a.add(10, 5, 0)  # Store found index
    a.jal(0, "END")
    
    a.label("NOT_FOUND")
    a.addi(10, 0, -1)
    
    a.label("END")
    a.check_reg(10, 4, 0)
    a.finalize_test(expected_x31=0)

# ==========================================
# ADD TO TESTS DICTIONARY
# ==========================================
TESTS: Dict[str, Tuple[str, Callable[[Asm], None]]] = {
    "selfcheck_basic": ("Self-checking basic ADD/SUB with register verification", prog_selfcheck_basic),
    "selfcheck_alu":   ("Self-checking comprehensive ALU test", prog_selfcheck_alu),
    "selfcheck_shift": ("Self-checking shift operations with edge cases", prog_selfcheck_shifts),
    "selfcheck_full":  ("Self-checking comprehensive test", prog_selfcheck_comprehensive),
    "branch_basic":    ("Self-checking basic branch tests (BEQ/BNE/BLT/BGE/BLTU/BGEU)", prog_branch_basic),
    "branch_loop":     ("Self-checking loop with backward branch", prog_branch_loop),
    "jal_basic":       ("Self-checking JAL (jump and link)", prog_jal_basic),
    "jalr_indirect":   ("Self-checking JALR with address masking", prog_jalr_indirect),
    "branch_matrix":   ("Self-checking comprehensive branch condition matrix", prog_branch_matrix),
    "nested_branch":   ("Self-checking nested branch structures", prog_nested_branches),
    "fwd_back_branch": ("Self-checking forward and backward branches", prog_forward_backward),
    "mem_lw_sw_basic": ("SW/LW basic + store->load", prog_mem_lw_sw_basic),
    "mem_byte_signext": ("SB + LB/LBU sign/zero extension", prog_mem_byte_signext),
    "mem_half_signext": ("SH + LH/LHU sign/zero extension", prog_mem_half_signext),
    "mem_endian_overlay": ("little-endian + overlapping loads", prog_mem_endian_overlay),

    # Data hazard tests
    "raw_hazards": ("RAW (Read-After-Write) data hazard stress test", prog_raw_data_hazards),
    "war_waw_hazards": ("WAR/WAW hazard patterns for OOO", prog_war_waw_hazards),
    "load_use_hazard": ("Load-use hazards and forwarding", prog_load_use_hazard),
    "store_load_fwd": ("Store-to-load forwarding and aliasing", prog_store_load_forwarding),
    "mem_aliasing": ("Memory address aliasing edge cases", prog_memory_aliasing),
    
    # Control flow tests
    "branch_pred_stress": ("Branch prediction stress patterns", prog_branch_prediction_stress),
    "deep_calls": ("Deeply nested function calls", prog_deeply_nested_calls),
    "control_chaos": ("Chaotic control flow patterns", prog_control_flow_chaos),
    
    # Resource pressure tests
    "reg_pressure": ("High register pressure test", prog_register_pressure),
    "long_dependency": ("Very long dependency chains", prog_long_dependency_chain),
    "reorder_buffer": ("Reorder buffer stress test", prog_stress_reorder_buffer),
    "mixed_ops_stress": ("Mixed operation types stress", prog_mixed_operations_stress),
    
    # Edge case tests
    "arith_edge": ("Arithmetic overflow and edge cases", prog_arithmetic_edge_cases),
    "shift_edge": ("Comprehensive shift edge cases", prog_shift_edge_cases),
    "bitwise_patterns": ("Bitwise operation patterns", prog_bitwise_patterns),
    "imm_edge": ("Immediate value edge cases", prog_immediate_edge_cases),
    "mem_boundary": ("Memory boundary access tests", prog_memory_boundary),
    "exception_boundary": ("Exception boundary conditions", prog_exception_boundary_test),
    
    # Complex algorithm tests
    "auipc_pcrel": ("AUIPC and PC-relative addressing", prog_auipc_pc_relative),
    "comprehensive_mem": ("Comprehensive memory operations", prog_comprehensive_memory),
    "bubble_sort": ("Bubble sort algorithm", prog_bubble_sort),
    "factorial": ("Factorial calculation", prog_factorial),
    "gcd": ("GCD using Euclidean algorithm", prog_gcd_euclidean),

    "recursive_factorial": ("Recursive factorial using stack", prog_recursive_factorial),
    "instruction_mix": ("Diverse instruction mix for IPC measurement", prog_instruction_mix),
    "memory_ordering": ("Memory operation ordering tests", prog_memory_ordering),
    "power_virus": ("Maximum switching activity (power virus)", prog_power_virus),
    "jalr_corner": ("JALR edge cases and RAS stress", prog_jalr_corner_cases),
    "pipeline_flushes": ("Pipeline flush scenarios", prog_pipeline_flushes),
    "binary_search": ("Binary search algorithm", prog_binary_search),
}

# -------------------------
# Output and simulation
# -------------------------

def write_hex(path: str, words: List[int]):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")

def write_asm(path: str, asm: List[str], words: List[int]):
    with open(path, "w") as f:
        pc = 0
        for a, w in zip(asm, words):
            f.write(f"{pc:08x}: {w:08x}    {a}\n")
            pc += 4

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="List available tests")
    ap.add_argument("--test", type=str, default="selfcheck_basic", help="Which test to generate")
    ap.add_argument("--out", type=str, default="prog", help="Output prefix")
    ap.add_argument("--pad", type=int, default=16, help="NOP padding words")
    args = ap.parse_args()

    if args.list:
        for k, (desc, _) in TESTS.items():
            print(f"{k:18s} - {desc}")
        return

    if args.test not in TESTS:
        raise SystemExit(f"Unknown --test '{args.test}'. Use --list.")

    a = Asm()
    TESTS[args.test][1](a)
    a.finalize()  # Resolve labels

    for _ in range(max(0, args.pad)):
        a.nop()

    write_hex(f"{args.out}.hex", a.words)
    write_asm(f"{args.out}.S", a.asm, a.words)
    Commit_trace, reg = simulate_commit_trace(a.words, a.meta, a.asm)  # Just to verify no errors
    write_commit_trace(f"{args.out}_commit_trace.txt", Commit_trace)

    print(f"Wrote {args.out}.hex and {args.out}.S ({len(a.words)} words)")
    print(f"Test '{args.test}': Check x31==0 for PASS, x30 for status marker")

if __name__ == "__main__":
    main()