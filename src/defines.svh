`ifndef DEFINES_SVH
`define DEFINES_SVH

// -----------------------------
// Global architectural params
// -----------------------------
parameter int ARCH_REGS = 32;
parameter int PHYS_REGS = 64;

parameter int ARCH_W = $clog2(ARCH_REGS);
parameter int PHYS_W = $clog2(PHYS_REGS);

// You already have ROB_SIZE elsewhere; keep it centralized if you want:
parameter int ROB_SIZE = 16;
parameter int ROB_W    = $clog2(ROB_SIZE);

// register width
parameter int DW = 32;

// RS params
parameter int RS_SIZE = 8;

parameter int BTB_ENTRIES = 16;
parameter int BTB_W       = $clog2(BTB_ENTRIES);
// Tag bits: remaining upper bits after removing [1:0] and index bits.
// You can override if you want shorter tags.
parameter int TAG_W       = (32 - 2 - BTB_W);

parameter int EPOCH_W     = 32;

// -----------------------------
// Uop classification enums
// -----------------------------
typedef enum logic [2:0] {
  UOP_ALU   = 3'd0,
  UOP_LOAD  = 3'd1,
  UOP_STORE = 3'd2,
  UOP_BRANCH= 3'd3,
  UOP_JUMP  = 3'd4,
  UOP_MISC  = 3'd5
} uop_class_e;

// -----------------------------
// Uop stored in RS (with phys tags)
// -----------------------------
typedef enum logic [6:0] {

  OP_INVALID = 7'd0,
  OP_ILLEGAL = 7'd1,
  OP_NOP     = 7'd2,

  // ----------------
  // Register ALU
  // ----------------
  OP_ADD     = 7'd3,
  OP_SUB     = 7'd4,
  OP_AND     = 7'd5,
  OP_OR      = 7'd6,
  OP_XOR     = 7'd7,
  OP_SLL     = 7'd8,
  OP_SRL     = 7'd9,
  OP_SRA     = 7'd10,
  OP_SLT     = 7'd11,
  OP_SLTU    = 7'd12,

  // ----------------
  // Immediate ALU
  // ----------------
  OP_ADDI    = 7'd13,
  OP_ANDI    = 7'd14,
  OP_ORI     = 7'd15,
  OP_XORI    = 7'd16,
  OP_SLLI    = 7'd17,
  OP_SRLI    = 7'd18,
  OP_SRAI    = 7'd19,
  OP_SLTI    = 7'd20,
  OP_SLTIU   = 7'd21,

  // ----------------
  // Upper immediates
  // ----------------
  OP_LUI     = 7'd22,
  OP_AUIPC   = 7'd23,

  // ----------------
  // Control flow
  // ----------------
  OP_BEQ     = 7'd24,
  OP_BNE     = 7'd25,
  OP_BLT     = 7'd26,
  OP_BGE     = 7'd27,
  OP_BLTU    = 7'd28,
  OP_BGEU    = 7'd29,
  OP_JAL     = 7'd30,
  OP_JALR    = 7'd31,

  // ----------------
  // Loads
  // ----------------
  OP_LB      = 7'd32,
  OP_LH      = 7'd33,
  OP_LW      = 7'd34,
  OP_LBU     = 7'd35,
  OP_LHU     = 7'd36,

  // ----------------
  // Stores
  // ----------------
  OP_SB      = 7'd37,
  OP_SH      = 7'd38,
  OP_SW      = 7'd39

} uop_op_e;


typedef enum logic [3:0] {
  BR_NONE = 4'd0,

  // Conditional branches
  BR_BEQ  = 4'd1,
  BR_BNE  = 4'd2,
  BR_BLT  = 4'd3,
  BR_BGE  = 4'd4,
  BR_BLTU = 4'd5,
  BR_BGEU = 4'd6,

  // Unconditional control flow (used by your decode)
  BR_JAL  = 4'd7,
  BR_JALR = 4'd8
} branch_type_e;


typedef enum logic [1:0] {
  MSZ_B = 2'd0,   // byte
  MSZ_H = 2'd1,   // half
  MSZ_W = 2'd2    // word
} mem_size_e;

// Source select muxes used by your decode/execute
// (tweak to match your diagram: reg, imm, pc, zero, etc.)
typedef enum logic [2:0] {
  SRC_RS1  = 3'd0,
  SRC_RS2  = 3'd1,
  SRC_IMM  = 3'd2,
  SRC_PC   = 3'd3,
  SRC_ZERO = 3'd4
} src_sel_e;

// -----------------------------
// Decode bundle (no phys tags)
// -----------------------------
// This is what decode produces before rename.
// Rename will add phys tags and old/new mapping bookkeeping.
typedef struct packed {
  // Core identity / debug
  logic [31:0]      pc;

  // Class / type
  uop_class_e       uop_class;
  uop_op_e          op;
  logic [6:0]       func7;      // optional
  logic [2:0]       func3;      // optional

  // Branch/load/store fields
  branch_type_e     branch_type;
  mem_size_e        mem_size;

  // Operand selection / usage
  src_sel_e         src1_select;
  src_sel_e         src2_select;
  logic             uses_rs1;
  logic             uses_rs2;
  logic             uses_rd;

  // Architectural regs
  logic [4:0]       rs1_arch;
  logic [4:0]       rs2_arch;
  logic [4:0]       rd_arch;

  // Immediate
  logic [31:0]      imm;

  // Control-flow helpers (optional for now)
  logic             pred_taken;
  logic [31:0]      pred_target;
} decoded_bundle_t;


// -----------------------------
// Renamed uop bundle (what RS stores)
// -----------------------------
// Matches your RS box: includes all bundle fields
// + prd_new + {prs1,rdy1} + {prs2,rdy2} + rob_idx + epoch
typedef struct packed {
  // From decode bundle
  decoded_bundle_t bundle;

  // Identity
  logic [ROB_W-1:0] rob_idx;
  logic [EPOCH_W-1:0]            epoch;

  // Renamed regs (no values)
  logic [PHYS_W-1:0] prs1;
  logic              rdy1;
  logic [PHYS_W-1:0] prs2;
  logic              rdy2;
  logic [PHYS_W-1:0] prd_new;
} rs_uop_t;

/* =========================
* ROB Entry Definition
* ========================= */
typedef struct packed {
    logic        valid;
    logic        done;
    logic [EPOCH_W-1:0]  epoch;

    logic        uses_rd;
    logic [4:0]  rd_arch;
    logic [PHYS_W-1:0] pd_new;
    logic [PHYS_W-1:0] pd_old;

    logic        is_branch;
    logic        mispredict;
    logic        is_load;
    logic        is_store;

    logic [31:0] pc;
} rob_entry_t;

/* =========================
* Execution Unit Types
* ========================= */
parameter int FU_NUM = 4;
typedef enum logic [2:0] {
  FU_ALU = 3'd0,
  FU_BRU = 3'd1,  // LSU can handle both loads and stores, just won't block stores on pending loads
  FU_SU = 3'd2,
  FU_LU = 3'd3,
  FU_FP  = 3'd4    // future
} fu_e;

function automatic fu_e uop_to_fu(uop_class_e c);
  case (c)
    UOP_ALU, UOP_MISC:           return FU_ALU;
    UOP_LOAD:                    return FU_LU;
    UOP_STORE:                   return FU_SU;
    UOP_BRANCH, UOP_JUMP:        return FU_BRU;
    default:                     return FU_ALU;
  endcase
endfunction


// -----------------------------
// FU writeback: what an FU produces (to WB arb / CDB / ROB)
// Keep it generic; unused fields are 0.
// -----------------------------
typedef struct packed {
  // Identity
  logic [ROB_W-1:0]  rob_idx;
  logic [EPOCH_W-1:0]            epoch;

  // Destination
  logic              uses_rd;
  logic [PHYS_W-1:0] prd_new;
  logic [31:0]       data;
  logic              data_valid;     // "this op produces a reg value" (loads/alu/fp)

  // Completion
  logic              done;           // FU has completed (even if no reg write)

  // Branch/redirect info (valid when uop.uop_class == BRANCH-like)
  logic              is_branch;
  logic              mispredict;
  logic              redirect;
  logic [31:0]       redirect_pc;
  logic              act_taken;
  logic [31:0]       pc;             

  // LSU info (optional)
  logic              is_load;
  logic              is_store;
  logic              mem_exc;        // e.g., fault/unaligned (optional)
  logic [31:0]       mem_addr;       // debug/scoreboard optional
} fu_wb_t;

// -----------------------------
// LSQ sizing
// -----------------------------
parameter int SQ_SIZE = 8;
parameter int LQ_SIZE = 16;

parameter int SQ_W = $clog2(SQ_SIZE);

// -----------------------------
// Store Queue (SQ) entry
// -----------------------------
// Purpose:
// - Hold stores after dispatch until they are allowed to commit to memory.
// - Support store-to-load forwarding (needs addr/data + valid bits).
// - Support recovery (epoch) + ordering (rob_idx).
typedef struct packed {
  // Ordering / recovery
  logic [ROB_W-1:0]  rob_idx;     // for "older-than" checks + commit ordering
  logic [EPOCH_W-1:0]            epoch;       // squash wrong-path stores on mispredict

  // Store attributes
  mem_size_e         mem_size;    // byte/half/word
  logic [31:0]       addr;
  logic              addr_rdy;

  logic [31:0]       data;
  logic              data_rdy;

  // Commit/drain bookkeeping
  logic              committed;   // set when ROB commits this store
  logic              sent;        // set when memory accepted the write (optional)
} sq_entry_t;

parameter int LD_REQ_NUM = 1;
parameter int ST_REQ_NUM = 1;


interface dmem_if #(parameter int LDTAG_W=4);
  // LOAD request
  logic              ld_valid, ld_ready;
  logic [31:0]       ld_addr;
  logic [2:0]        ld_size;
  logic [LDTAG_W-1:0] ld_tag;

  // LOAD response
  logic              ld_resp_valid, ld_resp_ready;
  logic [LDTAG_W-1:0] ld_resp_tag;
  logic [63:0]       ld_resp_data;
  logic              ld_resp_err;

  // STORE request
  logic              st_valid, st_ready;
  logic              st_resp_ready, st_resp_valid;
  logic [31:0]       st_addr;
  logic [2:0]        st_size;
  logic [63:0]       st_wdata;
  logic [7:0]        st_wstrb;

  // Optional: modports to make direction explicit (recommended)
  modport master (
    output ld_valid, ld_addr, ld_size, ld_tag,
    input  ld_ready,
    input  ld_resp_valid, ld_resp_tag, ld_resp_data, ld_resp_err,
    output ld_resp_ready,
    output st_valid, st_addr, st_size, st_wdata, st_wstrb, st_resp_ready,
    input  st_ready, st_resp_valid
  );

  modport slave (
    input  ld_valid, ld_addr, ld_size, ld_tag,
    output ld_ready,
    output ld_resp_valid, ld_resp_tag, ld_resp_data, ld_resp_err,
    input  ld_resp_ready,
    input  st_valid, st_addr, st_size, st_wdata, st_wstrb, st_resp_ready,
    output st_ready, st_resp_valid
  );
endinterface

interface imem_if;
  // IMEM request
  logic              imem_req_valid, imem_req_ready;
  logic [31:0]       imem_req_addr;

  // IMEM response
  logic              imem_resp_valid, imem_resp_ready;
  logic [31:0]       imem_resp_inst;

  // Optional: modports to make direction explicit (recommended)
  modport master (
    output imem_req_valid, imem_req_addr,
    input  imem_req_ready,
    input  imem_resp_valid, imem_resp_inst,
    output imem_resp_ready
  );

  modport slave (
    input  imem_req_valid, imem_req_addr,
    output imem_req_ready,
    output imem_resp_valid, imem_resp_inst,
    input  imem_resp_ready
  );
endinterface

`endif // DEFINES_SVH
