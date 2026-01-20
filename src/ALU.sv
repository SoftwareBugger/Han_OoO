`include "defines.svh"
/* -----------------------------
 * ALU Module with safe 1-entry output buffer
 * ---------------------------- */
module ALU (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_valid,
  output logic        req_ready,
  input  rs_uop_t     req_uop,

  input  logic [31:0] rs1_val,
  input  logic [31:0] rs2_val,

  output logic        wb_valid,
  input  logic        wb_ready,
  output logic [31:0] wb_pc,
  output logic        wb_uses_rd,
  output logic [ROB_W-1:0]  wb_rob_idx,
  output logic [PHYS_W-1:0] wb_prd_new,
  output logic [EPOCH_W-1:0]       wb_epoch,
  output logic [31:0] wb_data
);

  // ------------------------------------------------------------
  // Decode bundle (combinational view of req_uop.bundle)
  // ------------------------------------------------------------
  decoded_bundle_t b;
  always_comb b = req_uop.bundle;

  // ------------------------------------------------------------
  // Operand muxing
  // ------------------------------------------------------------
  logic [31:0] op_a, op_b;
  logic [4:0]  shamt;

  always_comb begin
    op_a  = 32'b0;
    op_b  = 32'b0;
    shamt = b.imm[4:0];

    unique case (b.src1_select)
      SRC_RS1:  op_a = rs1_val;
      SRC_PC:    op_a = b.pc;
      SRC_ZERO: op_a = 32'b0;
      default:  op_a = 32'b0;
    endcase

    unique case (b.src2_select)
      SRC_RS2:  op_b = rs2_val;
      SRC_IMM:  op_b = b.imm;
      default:  op_b = 32'b0;
    endcase
  end

  // ------------------------------------------------------------
  // RV32I ALU execute (combinational)
  // ------------------------------------------------------------
  logic [31:0] result_c;

  logic [4:0] shamt_i;
  logic [4:0] shamt_r;

  assign shamt_i = shamt;        // immediate shift amount (already decoded)
  assign shamt_r = op_b[4:0];     // register shift amount

  always_comb begin
    result_c = 32'b0;
    unique case (b.op)
      OP_ADD, OP_ADDI, OP_AUIPC:  result_c = op_a + op_b;
      OP_SUB:                    result_c = op_a - op_b;

      OP_AND, OP_ANDI:           result_c = op_a & op_b;
      OP_OR,  OP_ORI:            result_c = op_a | op_b;
      OP_XOR, OP_XORI:           result_c = op_a ^ op_b;

      // Shifts: immediate vs register forms must use different shift sources
      OP_SLLI:                   result_c = op_a <<  shamt_i;
      OP_SLL:                    result_c = op_a <<  shamt_r;

      OP_SRLI:                   result_c = op_a >>  shamt_i;
      OP_SRL:                    result_c = op_a >>  shamt_r;

      OP_SRAI:                   result_c = $signed(op_a) >>> shamt_i;
      OP_SRA:                    result_c = $signed(op_a) >>> shamt_r;

      // Comparisons: for immediate forms, op_b should already be sign-extended immediate
      OP_SLT,  OP_SLTI:          result_c = ($signed(op_a) < $signed(op_b)) ? 32'd1 : 32'd0;
      OP_SLTU, OP_SLTIU:         result_c = (op_a < op_b) ? 32'd1 : 32'd0;

      OP_LUI:                    result_c = op_b;

      default:                   result_c = 32'b0;
    endcase
  end


  // ------------------------------------------------------------
  // 1-entry output buffer (safe)
  // ------------------------------------------------------------
  logic out_vld_q;

  // Latched WB payload
  logic [31:0]       out_pc_q;
  logic              out_uses_rd_q;
  logic [ROB_W-1:0]  out_rob_idx_q;
  logic [PHYS_W-1:0] out_prd_new_q;
  logic [EPOCH_W-1:0]        out_epoch_q;
  logic [31:0]       out_data_q;

  // Optional: latch class to filter wb_valid (if you want)
  uop_class_e out_uop_class_q;

  // Does this entry require a WB handshake?

  // When can the buffered result retire?
  logic out_deq_fire;
  assign out_deq_fire = out_vld_q && (wb_ready);

  // Can we accept a new request?
  // If buffer empty OR retiring this cycle (1-deep skid)
  assign req_ready = (!out_vld_q) || out_deq_fire;

  // Enqueue computed result on handshake
  logic out_enq_fire;
  assign out_enq_fire = req_valid && req_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_vld_q       <= 1'b0;
      out_pc_q        <= 32'b0;
      out_uses_rd_q   <= 1'b0;
      out_rob_idx_q   <= '0;
      out_prd_new_q   <= '0;
      out_epoch_q     <= '0;
      out_data_q      <= 32'b0;
      out_uop_class_q <= UOP_ALU;
    end else begin
      if (out_enq_fire) begin
        out_vld_q       <= 1'b1;

        out_pc_q        <= b.pc;
        out_uses_rd_q   <= b.uses_rd;
        out_rob_idx_q   <= req_uop.rob_idx;   // From top-level of rs_uop_t
        out_prd_new_q   <= req_uop.prd_new;   // From top-level of rs_uop_t
        out_epoch_q     <= req_uop.epoch;     // From top-level of rs_uop_t
        out_data_q      <= result_c;

        out_uop_class_q <= b.uop_class;
      end else if (out_deq_fire) begin
        out_vld_q       <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------
  // Final WB interface: assert valid when retiring
  // ------------------------------------------------------------
  // If you *only* want wb_valid for UOP_ALU:
  // assign wb_valid = (out_uop_class_q == UOP_ALU) && out_uses_rd_q;
  //
  // If ALU is only issued ALU-class uops anyway, this is enough:
  assign wb_valid   = out_vld_q;

  assign wb_pc      = out_pc_q;
  assign wb_uses_rd = out_uses_rd_q;
  assign wb_rob_idx = out_rob_idx_q;
  assign wb_prd_new = out_prd_new_q;
  assign wb_epoch   = out_epoch_q;
  assign wb_data    = out_data_q;

endmodule