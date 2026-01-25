`include "defines.svh"

module decode (
  input  logic        clk,
  input  logic        rst_n,

  /* ==========================
   * redirect / predictor update
   * ========================= */
  input  logic              redirect_valid,

  /* =========================
   * Fetch Interface
   * ========================= */
  input  logic [31:0] fetch_inst,
  input  logic [31:0] fetch_pc,
  input  logic        fetch_valid,
  output logic        fetch_ready,
  input  logic [2:0]  fetch_epoch,

  /* =============================
   * branch prediction info from PC
   * ============================= */
  input  logic              pred_taken,
  input  logic [31:0]       pred_target,

  /* =========================
   * Decode Interface
   * ========================= */
  input  logic       decode_ready,
  output logic       decode_valid,
  output decoded_bundle_t decoded_bundle_fields
);

  // -----------------------------
  // Field extract
  // -----------------------------
  logic [6:0] opcode, funct7;
  logic [2:0] funct3;
  logic [4:0] rd, rs1, rs2;

  always_comb begin
    opcode = fetch_inst[6:0];
    rd     = fetch_inst[11:7];
    funct3 = fetch_inst[14:12];
    rs1    = fetch_inst[19:15];
    rs2    = fetch_inst[24:20];
    funct7 = fetch_inst[31:25];
  end

  // -----------------------------
  // Immediate helpers
  // -----------------------------
  function automatic logic [31:0] imm_i(input logic [31:0] ins);
    return {{20{ins[31]}}, ins[31:20]};
  endfunction

  function automatic logic [31:0] imm_s(input logic [31:0] ins);
    return {{20{ins[31]}}, ins[31:25], ins[11:7]};
  endfunction

  function automatic logic [31:0] imm_b(input logic [31:0] ins);
    return {{19{ins[31]}}, ins[31], ins[7], ins[30:25], ins[11:8], 1'b0};
  endfunction

  function automatic logic [31:0] imm_u(input logic [31:0] ins);
    return {ins[31:12], 12'b0};
  endfunction

  function automatic logic [31:0] imm_j(input logic [31:0] ins);
    return {{11{ins[31]}}, ins[31], ins[19:12], ins[20], ins[30:21], 1'b0};
  endfunction

  // ============================================================
  // Decode combinational output for current fetch inputs
  // ============================================================
  decoded_bundle_t d;

  always_comb begin
    d = '0;

    d.pc           = fetch_pc;
    d.rs1_arch     = rs1;
    d.rs2_arch     = rs2;
    d.rd_arch      = rd;

    // defaults
    d.uop_class    = UOP_MISC;
    d.op           = OP_NOP;
    d.func7        = funct7[2:0];
    d.func3        = {2'b00, funct3};

    d.branch_type  = BR_NONE;
    d.mem_size     = MSZ_W;

    d.src1_select  = SRC_RS1;
    d.src2_select  = SRC_RS2;
    d.uses_rs1     = 1'b0;
    d.uses_rs2     = 1'b0;
    d.uses_rd      = 1'b0;

    d.imm          = 32'b0;

    // prediction info: capture from inputs
    d.pred_taken   = pred_taken;
    d.pred_target  = pred_target;

    unique case (opcode)

      7'b0110011: begin
        d.uop_class   = UOP_ALU;
        d.uses_rs1    = 1'b1;
        d.uses_rs2    = 1'b1;
        d.uses_rd     = 1'b1;
        d.src1_select = SRC_RS1;
        d.src2_select = SRC_RS2;

        unique case (funct3)
          3'b000: d.op = (funct7 == 7'b0100000) ? OP_SUB : OP_ADD;
          3'b111: d.op = OP_AND;
          3'b110: d.op = OP_OR;
          3'b100: d.op = OP_XOR;
          3'b001: d.op = OP_SLL;
          3'b101: d.op = (funct7 == 7'b0100000) ? OP_SRA : OP_SRL;
          3'b010: d.op = OP_SLT;
          3'b011: d.op = OP_SLTU;
          default: d.op = OP_ILLEGAL;
        endcase
      end

      7'b0010011: begin
        d.uop_class   = UOP_ALU;
        d.uses_rs1    = 1'b1;
        d.uses_rs2    = 1'b0;
        d.uses_rd     = 1'b1;
        d.src1_select = SRC_RS1;
        d.src2_select = SRC_IMM;
        d.imm         = imm_i(fetch_inst);

        unique case (funct3)
          3'b000: d.op = OP_ADDI;
          3'b111: d.op = OP_ANDI;
          3'b110: d.op = OP_ORI;
          3'b100: d.op = OP_XORI;
          3'b010: d.op = OP_SLTI;
          3'b011: d.op = OP_SLTIU;
          3'b001: d.op = (funct7 == 7'b0000000) ? OP_SLLI : OP_ILLEGAL;
          3'b101: begin
            if      (funct7 == 7'b0000000) d.op = OP_SRLI;
            else if (funct7 == 7'b0100000) d.op = OP_SRAI;
            else                            d.op = OP_ILLEGAL;
          end
          default: d.op = OP_ILLEGAL;
        endcase
      end

      7'b0000011: begin
        d.uop_class   = UOP_LOAD;
        d.uses_rs1    = 1'b1;
        d.uses_rs2    = 1'b0;
        d.uses_rd     = 1'b1;
        d.src1_select = SRC_RS1;
        d.src2_select = SRC_IMM;
        d.imm         = imm_i(fetch_inst);

        unique case (funct3)
          3'b000: begin d.op = OP_LB;  d.mem_size = MSZ_B; end
          3'b001: begin d.op = OP_LH;  d.mem_size = MSZ_H; end
          3'b010: begin d.op = OP_LW;  d.mem_size = MSZ_W; end
          3'b100: begin d.op = OP_LBU; d.mem_size = MSZ_B; end
          3'b101: begin d.op = OP_LHU; d.mem_size = MSZ_H; end
          default: d.op = OP_ILLEGAL;
        endcase
      end

      7'b0100011: begin
        d.uop_class   = UOP_STORE;
        d.uses_rs1    = 1'b1;
        d.uses_rs2    = 1'b1;
        d.uses_rd     = 1'b0;
        d.src1_select = SRC_RS1;
        d.src2_select = SRC_IMM;
        d.imm         = imm_s(fetch_inst);

        unique case (funct3)
          3'b000: begin d.op = OP_SB; d.mem_size = MSZ_B; end
          3'b001: begin d.op = OP_SH; d.mem_size = MSZ_H; end
          3'b010: begin d.op = OP_SW; d.mem_size = MSZ_W; end
          default: d.op = OP_ILLEGAL;
        endcase
      end

      7'b1100011: begin
        d.uop_class   = UOP_BRANCH;
        d.uses_rs1    = 1'b1;
        d.uses_rs2    = 1'b1;
        d.uses_rd     = 1'b0;
        d.src1_select = SRC_RS1;
        d.src2_select = SRC_RS2;
        d.imm         = imm_b(fetch_inst);

        unique case (funct3)
          3'b000: begin d.op = OP_BEQ;  d.branch_type = BR_BEQ;  end
          3'b001: begin d.op = OP_BNE;  d.branch_type = BR_BNE;  end
          3'b100: begin d.op = OP_BLT;  d.branch_type = BR_BLT;  end
          3'b101: begin d.op = OP_BGE;  d.branch_type = BR_BGE;  end
          3'b110: begin d.op = OP_BLTU; d.branch_type = BR_BLTU; end
          3'b111: begin d.op = OP_BGEU; d.branch_type = BR_BGEU; end
          default: d.op = OP_ILLEGAL;
        endcase
      end

      7'b1101111: begin
        d.uop_class    = UOP_JUMP;
        d.op           = OP_JAL;
        d.branch_type  = BR_JAL;
        d.uses_rs1     = 1'b0;
        d.uses_rs2     = 1'b0;
        d.uses_rd      = 1'b1;
        d.src1_select  = SRC_PC;
        d.src2_select  = SRC_IMM;
        d.imm          = imm_j(fetch_inst);
      end

      7'b1100111: begin
        d.uop_class    = UOP_JUMP;
        d.op           = OP_JALR;
        d.branch_type  = BR_JALR;
        d.uses_rs1     = 1'b1;
        d.uses_rs2     = 1'b0;
        d.uses_rd      = 1'b1;
        d.src1_select  = SRC_RS1;
        d.src2_select  = SRC_IMM;
        d.imm          = imm_i(fetch_inst);
        if (funct3 != 3'b000) d.op = OP_ILLEGAL;
      end

      7'b0110111: begin
        d.uop_class    = UOP_ALU;
        d.op           = OP_LUI;
        d.uses_rs1     = 1'b0;
        d.uses_rs2     = 1'b0;
        d.uses_rd      = 1'b1;
        d.src1_select  = SRC_ZERO;
        d.src2_select  = SRC_IMM;
        d.imm          = imm_u(fetch_inst);
      end

      7'b0010111: begin
        d.uop_class    = UOP_ALU;
        d.op           = OP_AUIPC;
        d.uses_rs1     = 1'b0;
        d.uses_rs2     = 1'b0;
        d.uses_rd      = 1'b1;
        d.src1_select  = SRC_PC;
        d.src2_select  = SRC_IMM;
        d.imm          = imm_u(fetch_inst);
      end

      default: begin
        d.uop_class = UOP_MISC;
        d.op        = OP_ILLEGAL;
      end
    endcase
    if (rd == 5'd0) begin
      d.uses_rd = 1'b0; // rd=x0 means no destination
    end
  end

  // ============================================================
  // 1-entry output buffer (decode -> dispatch) with valid/ready
  // ============================================================
  logic out_vld_q;
  decoded_bundle_t out_d_q;
  logic [2:0] out_epoch_q;
  logic first_inst;

  // downstream handshake
  wire out_deq_fire = out_vld_q && (decode_ready || (out_epoch_q != decode_epoch));
  

  // upstream can send if buffer empty or we dequeue this cycle (skid)
  assign fetch_ready  = (!out_vld_q) || out_deq_fire;

  // accept from fetch on handshake
  wire out_enq_fire   = fetch_valid && fetch_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_vld_q <= 1'b0;
      out_d_q   <= 'd0;
      out_epoch_q <= 3'b0;
      //first_inst <= 1'b1;
    end else begin
      // if (redirect_valid) begin
      //   first_inst <= 1'b1;
      // end else if (out_enq_fire) begin
      //   first_inst <= 1'b0;
      // end
      if (out_enq_fire) begin
        out_vld_q <= 1'b1;//(d.pc != out_d_q.pc) ? 1'b1 : first_inst; // only update valid if new PC
        out_d_q   <= d;        // latch decoded result
        out_epoch_q <= fetch_epoch;
      end else if (out_deq_fire) begin
        out_vld_q <= 1'b0;
      end
    end
  end

  logic [2:0] decode_epoch;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      decode_epoch <= 3'b0;
    end else if (redirect_valid) begin
      decode_epoch <= decode_epoch + 3'b1;
    end
  end

  // drive decode outputs
  assign decode_valid          = out_vld_q && (out_epoch_q == decode_epoch) && !redirect_valid;
  assign decoded_bundle_fields = out_d_q;

endmodule
