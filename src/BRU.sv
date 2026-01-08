`include "defines.svh"

module BRU (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_valid,
  output logic        req_ready,
  input  rs_uop_t     req_uop,

  input  logic [31:0] rs1_val,
  input  logic [31:0] rs2_val,

  output logic        wb_valid,
  input  logic        wb_ready,
  output logic        wb_uses_rd,
  output logic [1:0]       wb_epoch,
  output logic [ROB_W-1:0]  wb_rob_idx,
  output logic [PHYS_W-1:0] wb_prd_new,
  output logic [31:0] wb_data,
  output logic [31:0] wb_pc,

  output logic        br_valid,
  output logic        act_taken,
  output logic [31:0] target_pc,

  output logic        mispredict,
  output logic        redirect_valid,
  output logic [31:0] redirect_pc
);

  // ============================================================
  // Combinational execute from *current* inputs
  // ============================================================
  logic cond_true_c;
  logic act_taken_c;
  logic [31:0] target_pc_c;
  logic mispredict_c;
  logic [31:0] redirect_pc_c;

  always_comb begin
    cond_true_c = 1'b0;
    unique case (req_uop.bundle.branch_type)
      BR_BEQ:  cond_true_c = (rs1_val == rs2_val);
      BR_BNE:  cond_true_c = (rs1_val != rs2_val);
      BR_BLT:  cond_true_c = ($signed(rs1_val) <  $signed(rs2_val));
      BR_BGE:  cond_true_c = ($signed(rs1_val) >= $signed(rs2_val));
      BR_BLTU: cond_true_c = (rs1_val <  rs2_val);
      BR_BGEU: cond_true_c = (rs1_val >= rs2_val);
      default: cond_true_c = 1'b0;
    endcase
  end

  always_comb begin
    act_taken_c = 1'b0;
    target_pc_c = req_uop.bundle.pc + req_uop.bundle.imm;

    unique case (req_uop.bundle.uop_class)
      UOP_BRANCH: begin
        act_taken_c = cond_true_c;
        target_pc_c = req_uop.bundle.pc + req_uop.bundle.imm;
      end

      UOP_JUMP: begin
        act_taken_c = 1'b1;
        // Heuristic: treat as JALR if uses_rs1, else JAL
        if (req_uop.bundle.uses_rs1) begin
          target_pc_c = (rs1_val + req_uop.bundle.imm) & 32'hFFFF_FFFE;
        end else begin
          target_pc_c = req_uop.bundle.pc + req_uop.bundle.imm;
        end
      end

      default: begin
        act_taken_c = 1'b0;
        target_pc_c = req_uop.bundle.pc + 32'd4;
      end
    endcase
  end

  always_comb begin
    mispredict_c = 1'b0;
    // only meaningful when we actually accept the request, but ok to compute here
    if (act_taken_c != req_uop.bundle.pred_taken) begin
      mispredict_c = 1'b1;
    end else if (act_taken_c && (target_pc_c != req_uop.bundle.pred_target)) begin
      mispredict_c = 1'b1;
    end
  end

  always_comb begin
    redirect_pc_c = act_taken_c ? target_pc_c : (req_uop.bundle.pc + 32'd4);
  end

  // ============================================================
  // Output buffer (1-entry) holds *results*
  // ============================================================
  logic out_vld_q;

  // WB meta
  logic [31:0]       out_pc_q;          // Store the PC
  logic              out_uses_rd_q;
  logic [1:0]        out_epoch_q;
  logic [ROB_W-1:0]  out_rob_idx_q;
  logic [PHYS_W-1:0] out_prd_new_q;
  logic [31:0]       out_wb_data_q;

  // Control-flow resolution
  logic        out_act_taken_q;
  logic [31:0] out_target_pc_q;
  logic        out_mispredict_q;
  logic [31:0] out_redirect_pc_q;

  logic out_needs_wb_q;
  assign out_needs_wb_q = out_uses_rd_q;

  // Retire from output buffer when:
  // - buffer valid, AND
  // - either no WB needed OR wb_ready is high
  logic out_deq_fire;
  assign out_deq_fire = out_vld_q && (!out_needs_wb_q || wb_ready);

  // Can accept a new request if:
  // - output buffer empty, OR
  // - output buffer will retire this cycle (1-deep skid)
  assign req_ready = (!out_vld_q) || out_deq_fire;

  // Enqueue new computed results on req handshake
  logic out_enq_fire;
  assign out_enq_fire = req_valid && req_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_vld_q         <= 1'b0;

      out_pc_q          <= 32'b0;
      out_uses_rd_q     <= 1'b0;
      out_epoch_q       <= 2'b0;
      out_rob_idx_q     <= '0;
      out_prd_new_q     <= '0;
      out_wb_data_q     <= '0;

      out_act_taken_q   <= 1'b0;
      out_target_pc_q   <= '0;
      out_mispredict_q  <= 1'b0;
      out_redirect_pc_q <= '0;
    end else begin
      if (out_enq_fire) begin
        out_vld_q         <= 1'b1;

        out_pc_q          <= req_uop.bundle.pc;           // Latch the PC
        out_uses_rd_q     <= req_uop.bundle.uses_rd;
        out_epoch_q       <= req_uop.epoch;
        out_rob_idx_q     <= req_uop.rob_idx;
        out_prd_new_q     <= req_uop.prd_new;
        out_wb_data_q     <= req_uop.bundle.pc + 32'd4;   // Return address (PC+4)

        out_act_taken_q   <= act_taken_c;
        out_target_pc_q   <= target_pc_c;
        out_mispredict_q  <= mispredict_c;
        out_redirect_pc_q <= redirect_pc_c;
      end else if (out_deq_fire) begin
        out_vld_q <= 1'b0;
      end
    end
  end

  // ============================================================
  // Outputs asserted when output buffer is retiring
  // ============================================================
  assign br_valid   = out_deq_fire;
  assign act_taken  = out_act_taken_q;
  assign target_pc  = out_target_pc_q;
  assign mispredict = out_mispredict_q;

  assign redirect_valid = out_deq_fire && out_mispredict_q;
  assign redirect_pc    = out_redirect_pc_q;

  always_comb begin
    wb_valid    = out_vld_q;
    wb_uses_rd  = out_uses_rd_q;
    wb_epoch    = out_epoch_q;
    wb_rob_idx  = out_rob_idx_q;
    wb_prd_new  = out_prd_new_q;
    wb_data     = out_wb_data_q;   // Return address (PC+4)
    wb_pc       = out_pc_q;        // Original instruction PC
  end

endmodule