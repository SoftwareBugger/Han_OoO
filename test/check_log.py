#!/usr/bin/env python3
# check_log.py
#
# Compares frontend trace (readable key=value format) against golden RV32I decode
# using the same prog.hex used by your imem.
#
# Fixes:
# - compares immediates as 32-bit unsigned (so -1 matches 0xFFFF_FFFF)
# - matches your RTL behavior for shift-immediates (SLLI/SRLI/SRAI use imm_i field)
# - only compares rs1/rs2/rd when instruction semantically uses them
# - skips lines with rs/rd/imm = x
# - avoids imm_s name collision (which caused "'str' object is not callable")

from __future__ import annotations

# ------------------------------------------------------------
# RISC-V opcode maps (must match your RTL uop_op_e numbering)
# ------------------------------------------------------------
OP = {
    "ADD":   3, "SUB": 4, "AND": 5, "OR": 6, "XOR": 7,
    "SLL":   8, "SRL": 9, "SRA": 10, "SLT": 11, "SLTU": 12,

    "ADDI": 13, "ANDI": 14, "ORI": 15, "XORI": 16,
    "SLLI": 17, "SRLI": 18, "SRAI": 19, "SLTI": 20, "SLTIU": 21,

    "LUI": 22, "AUIPC": 23,

    "BEQ": 24, "BNE": 25, "BLT": 26, "BGE": 27, "BLTU": 28, "BGEU": 29,
    "JAL": 30, "JALR": 31,

    "LB": 32, "LH": 33, "LW": 34, "LBU": 35, "LHU": 36,
    "SB": 37, "SH": 38, "SW": 39
}

# ------------------------------------------------------------
# Load hex program (readmemh-style, one word per line)
# ------------------------------------------------------------
def load_hex(path: str):
    mem = {}
    pc = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            mem[pc] = int(line, 16) & 0xFFFF_FFFF
            pc += 4
    return mem

# ------------------------------------------------------------
# Immediate extract
# ------------------------------------------------------------
def signext(x: int, bits: int) -> int:
    if (x >> (bits - 1)) & 1:
        return x | (-1 << bits)
    return x

def imm_i(ins: int) -> int:
    return signext((ins >> 20) & 0xFFF, 12)

def imm_s_fn(ins: int) -> int:
    return signext(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12)

def imm_b(ins: int) -> int:
    v = ((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1)
    return signext(v, 13)

def imm_u(ins: int) -> int:
    return ins & 0xFFFFF000

def imm_j(ins: int) -> int:
    v = ((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1)
    return signext(v, 21)

# ------------------------------------------------------------
# Golden decode (matches your RTL decode conventions)
# - For shift-immediates, returns imm_i(ins) (funct7<<5 | shamt) to match RTL d.imm=imm_i
# ------------------------------------------------------------
def decode(ins: int):
    opc = ins & 0x7F
    rd  = (ins >> 7) & 0x1F
    f3  = (ins >> 12) & 7
    rs1 = (ins >> 15) & 0x1F
    rs2 = (ins >> 20) & 0x1F
    f7  = (ins >> 25) & 0x7F

    if opc == 0x33:   # R
        if f3==0 and f7==0x00: return ("ADD",  rs1, rs2, rd, 0)
        if f3==0 and f7==0x20: return ("SUB",  rs1, rs2, rd, 0)
        if f3==7:              return ("AND",  rs1, rs2, rd, 0)
        if f3==6:              return ("OR",   rs1, rs2, rd, 0)
        if f3==4:              return ("XOR",  rs1, rs2, rd, 0)
        if f3==1:              return ("SLL",  rs1, rs2, rd, 0)
        if f3==5 and f7==0x00: return ("SRL",  rs1, rs2, rd, 0)
        if f3==5 and f7==0x20: return ("SRA",  rs1, rs2, rd, 0)
        if f3==2:              return ("SLT",  rs1, rs2, rd, 0)
        if f3==3:              return ("SLTU", rs1, rs2, rd, 0)

    if opc == 0x13:   # I-ALU
        if f3==0: return ("ADDI",  rs1, 0, rd, imm_i(ins))
        if f3==7: return ("ANDI",  rs1, 0, rd, imm_i(ins))
        if f3==6: return ("ORI",   rs1, 0, rd, imm_i(ins))
        if f3==4: return ("XORI",  rs1, 0, rd, imm_i(ins))
        if f3==2: return ("SLTI",  rs1, 0, rd, imm_i(ins))
        if f3==3: return ("SLTIU", rs1, 0, rd, imm_i(ins))

        # Match RTL: d.imm = imm_i(fetch_inst) for shifts, not just shamt
        if f3==1 and f7==0x00: return ("SLLI",  rs1, 0, rd, imm_i(ins))
        if f3==5 and f7==0x00: return ("SRLI",  rs1, 0, rd, imm_i(ins))
        if f3==5 and f7==0x20: return ("SRAI",  rs1, 0, rd, imm_i(ins))

    if opc == 0x03:   # Loads
        if f3==0: return ("LB",  rs1, 0, rd, imm_i(ins))
        if f3==1: return ("LH",  rs1, 0, rd, imm_i(ins))
        if f3==2: return ("LW",  rs1, 0, rd, imm_i(ins))
        if f3==4: return ("LBU", rs1, 0, rd, imm_i(ins))
        if f3==5: return ("LHU", rs1, 0, rd, imm_i(ins))

    if opc == 0x23:   # Stores
        if f3==0: return ("SB", rs1, rs2, 0, imm_s_fn(ins))
        if f3==1: return ("SH", rs1, rs2, 0, imm_s_fn(ins))
        if f3==2: return ("SW", rs1, rs2, 0, imm_s_fn(ins))

    if opc == 0x63:   # Branches
        if f3==0: return ("BEQ",  rs1, rs2, 0, imm_b(ins))
        if f3==1: return ("BNE",  rs1, rs2, 0, imm_b(ins))
        if f3==4: return ("BLT",  rs1, rs2, 0, imm_b(ins))
        if f3==5: return ("BGE",  rs1, rs2, 0, imm_b(ins))
        if f3==6: return ("BLTU", rs1, rs2, 0, imm_b(ins))
        if f3==7: return ("BGEU", rs1, rs2, 0, imm_b(ins))

    if opc == 0x6F: return ("JAL",   0,   0, rd, imm_j(ins))
    if opc == 0x67: return ("JALR",  rs1, 0, rd, imm_i(ins))
    if opc == 0x37: return ("LUI",   0,   0, rd, imm_u(ins))
    if opc == 0x17: return ("AUIPC", 0,   0, rd, imm_u(ins))

    return None

# ------------------------------------------------------------
# Field usage gating (avoid comparing don't-care fields from encoding)
# ------------------------------------------------------------
def uses_rs1(name: str) -> bool:
    return name in {
        # R
        "ADD","SUB","AND","OR","XOR","SLL","SRL","SRA","SLT","SLTU",
        # I-ALU
        "ADDI","ANDI","ORI","XORI","SLLI","SRLI","SRAI","SLTI","SLTIU",
        # loads/stores
        "LB","LH","LW","LBU","LHU","SB","SH","SW",
        # branches
        "BEQ","BNE","BLT","BGE","BLTU","BGEU",
        # jalr
        "JALR",
    }

def uses_rs2(name: str) -> bool:
    return name in {
        # R
        "ADD","SUB","AND","OR","XOR","SLL","SRL","SRA","SLT","SLTU",
        # stores
        "SB","SH","SW",
        # branches
        "BEQ","BNE","BLT","BGE","BLTU","BGEU",
    }

def writes_rd(name: str) -> bool:
    return name in {
        # R
        "ADD","SUB","AND","OR","XOR","SLL","SRL","SRA","SLT","SLTU",
        # I-ALU
        "ADDI","ANDI","ORI","XORI","SLLI","SRLI","SRAI","SLTI","SLTIU",
        # loads
        "LB","LH","LW","LBU","LHU",
        # jumps and upper immediates
        "JAL","JALR","LUI","AUIPC",
    }

# ------------------------------------------------------------
# Trace parsing helpers for key=value tokens
# ------------------------------------------------------------
def parse_kv(tok: str):
    if "=" not in tok:
        return None, None
    k, v = tok.split("=", 1)
    return k.strip(), v.strip()

def parse_int_maybe(v: str, base: int):
    v = v.strip()
    if v.lower() == "x":
        return None
    # allow xNN for regs in readable logs
    if base == 10 and (v.lower().startswith("x") and v[1:].isdigit()):
        v = v[1:]
    # allow 0x... for hex
    if base == 16 and v.lower().startswith("0x"):
        v = v[2:]
    return int(v, base)

def main():
    mem = load_hex("prog.hex")

    bad = 0
    seen = 0
    skipped_parse = 0
    skipped_not_in_hex = 0

    with open("fetch_trace.log") as tf:
        for line in tf:
            line = line.strip()
            if not line.startswith("PC="):
                continue

            toks = line.split()
            kv = {}
            for t in toks:
                k, v = parse_kv(t)
                if k is not None:
                    kv[k] = v

            pc_s  = kv.get("PC")
            op_s  = kv.get("op")
            rs1_s = kv.get("rs1")
            rs2_s = kv.get("rs2")
            rd_s  = kv.get("rd")
            imm_hex_str = kv.get("imm")  # do NOT name this imm_s

            if None in (pc_s, op_s, rs1_s, rs2_s, rd_s, imm_hex_str):
                skipped_parse += 1
                continue

            pc  = parse_int_maybe(pc_s, 16)
            op  = parse_int_maybe(op_s, 10)
            rs1 = parse_int_maybe(rs1_s, 10)
            rs2 = parse_int_maybe(rs2_s, 10)
            rd  = parse_int_maybe(rd_s, 10)
            imm = parse_int_maybe(imm_hex_str, 16)

            # skip x / unparsable
            if None in (pc, op, rs1, rs2, rd, imm):
                skipped_parse += 1
                continue

            ins = mem.get(pc)
            if ins is None:
                skipped_not_in_hex += 1
                continue

            ref = decode(ins)
            if ref is None:
                # padding/data: ignore
                continue

            name, r1, r2, rd0, imm0 = ref
            exp_op = OP[name]

            # compare immediates as 32-bit unsigned
            imm_rtl = imm & 0xFFFF_FFFF
            imm_ref = imm0 & 0xFFFF_FFFF

            mismatch = False
            if op != exp_op:
                mismatch = True
            if uses_rs1(name) and (rs1 != r1):
                mismatch = True
            if uses_rs2(name) and (rs2 != r2):
                mismatch = True
            if writes_rd(name) and (rd != rd0):
                mismatch = True
            if imm_rtl != imm_ref:
                mismatch = True

            if mismatch:
                bad += 1
                print(f"Mismatch @ PC {pc:08x} ins={ins:08x}")
                print(f"  RTL: op={op} rs1={rs1} rs2={rs2} rd={rd} imm=0x{imm_rtl:08x}")
                print(f"  REF: {name} op={exp_op} rs1={r1} rs2={r2} rd={rd0} imm=0x{imm_ref:08x}")

            seen += 1

    if bad == 0:
        print(f"✓ PASS ({seen} checked). skipped_parse={skipped_parse} skipped_not_in_hex={skipped_not_in_hex}")
    else:
        print(f"✗ FAIL: {bad} mismatches out of {seen} checked. skipped_parse={skipped_parse} skipped_not_in_hex={skipped_not_in_hex}")

if __name__ == "__main__":
    main()
