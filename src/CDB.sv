`include "defines.svh"

/* ================================================================
 * CDB (Common Data Bus) / WB Arbiter
 *
 * Selects at most one FU completion per cycle and presents it to the
 * ROB/PRF as a single fu_wb_t packet (Ready/Valid).
 *
 * Priority: BRU > LSU > ALU
 *  - BRU uses br_valid (branch resolution) as the true completion valid.
 *    wb_valid may be asserted additionally for JAL/JALR rd writeback.
 * ================================================================ */
module CDB (
    input  logic        clk,
    input  logic        rst_n,

    // -----------------------------
    // ALU writeback (completion == wb_valid)
    // -----------------------------
    input  logic              alu_wb_valid,
    output logic              alu_wb_ready,
    input  logic [ROB_W-1:0]  alu_wb_rob_idx,
    input  logic [PHYS_W-1:0] alu_wb_prd_new,
    input  logic [31:0]       alu_wb_data,
    input  logic [31:0]       alu_wb_pc,
    input  logic [EPOCH_W-1:0]        alu_wb_epoch,
    input  logic              alu_wb_uses_rd,

    // -----------------------------
    // BRU resolution + optional rd writeback (JAL/JALR)
    //   completion == br_valid
    // -----------------------------
    input  logic              bru_wb_valid,     // rd writeback valid (JAL/JALR), may be 0 for pure branches
    output logic              bru_wb_ready,
    input  logic [ROB_W-1:0]  bru_wb_rob_idx,
    input  logic [PHYS_W-1:0] bru_wb_prd_new,
    input  logic [31:0]       bru_wb_data,
    input  logic [EPOCH_W-1:0]        bru_wb_epoch,
    input  logic              bru_wb_uses_rd,
    input  logic [31:0]       bru_wb_pc,

    input  logic              bru_act_taken,
    input  logic              bru_mispredict,
    input  logic              bru_redirect_valid,
    input  logic [31:0]       bru_redirect_pc,

    // -----------------------------
    // LSU writeback (loads) (completion == wb_valid)
    // -----------------------------
    input  logic              lsu_wb_valid,
    output logic              lsu_wb_ready,
    input  logic [ROB_W-1:0]  lsu_wb_rob_idx,
    input  logic [PHYS_W-1:0] lsu_wb_prd_new,
    input  logic [31:0]       lsu_wb_data,
    input  logic [EPOCH_W-1:0]        lsu_wb_epoch,
    input  logic              lsu_wb_uses_rd,
    input  logic [31:0]       lsu_wb_pc,

    // -----------------------------
    // LSU writeback (stores) (completion == wb_valid_st)
    // -----------------------------
    input  logic              lsu_wb_valid_st,
    output logic              lsu_wb_ready_st,
    input  logic [ROB_W-1:0]  lsu_wb_rob_idx_st,
    input  logic [EPOCH_W-1:0]        lsu_wb_epoch_st,
    input  logic [31:0]       lsu_wb_pc_st,

    // Optional LSU info (tie off to 0 if unused)
    input  logic              lsu_is_load,
    input  logic              lsu_is_store,
    input  logic              lsu_mem_exc,
    input  logic [31:0]       lsu_mem_addr,

    // -----------------------------
    // To ROB + PRF (single defined interface)
    // -----------------------------
    output logic              wb_valid,
    input  logic              wb_ready,
    output fu_wb_t            wb_pkt
);

    // ============================================================
    // Arbitration (BRU > LSU > ALU)
    // ============================================================
    typedef enum logic [2:0] {
        SEL_NONE = 3'd0,
        SEL_BRU  = 3'd1,
        SEL_ST  = 3'd2,
        SEL_LD  = 3'd3,
        SEL_ALU  = 3'd4
    } sel_e;

    sel_e sel;

    always_comb begin
        sel = SEL_NONE;
        if      (bru_wb_valid) sel = SEL_BRU;
        else if (lsu_wb_valid_st) sel = SEL_ST; // Give store WB higher priority than load WB
        else if (lsu_wb_valid)  sel = SEL_LD;
        else if (alu_wb_valid)  sel = SEL_ALU;
        else                    sel = SEL_NONE;
    end

    // ============================================================
    // Output packet mux
    // ============================================================
    always_comb begin
        wb_valid = 1'b0;
        wb_pkt   = '0;

        unique case (sel)
            SEL_BRU: begin
                wb_valid          = bru_wb_valid;

                wb_pkt.rob_idx    = bru_wb_rob_idx;
                wb_pkt.epoch      = bru_wb_epoch;

                wb_pkt.done       = 1'b1;

                // Optional rd writeback (JAL/JALR); may be 0 for branches.
                wb_pkt.uses_rd    = bru_wb_uses_rd && bru_wb_valid;
                wb_pkt.prd_new    = bru_wb_prd_new;
                wb_pkt.data       = bru_wb_data;
                wb_pkt.data_valid = (bru_wb_uses_rd && bru_wb_valid);

                // Branch info
                wb_pkt.is_branch   = 1'b1;
                wb_pkt.mispredict  = bru_mispredict;
                wb_pkt.redirect    = bru_redirect_valid;
                wb_pkt.redirect_pc = bru_redirect_pc;
                wb_pkt.act_taken   = bru_act_taken;

                // LSU fields unused
                wb_pkt.is_load     = 1'b0;
                wb_pkt.is_store    = 1'b0;
                wb_pkt.mem_exc     = 1'b0;
                wb_pkt.mem_addr    = 32'b0;
                wb_pkt.pc          = bru_wb_pc;
            end

            SEL_ST: begin
                wb_valid          = lsu_wb_valid_st;

                wb_pkt.rob_idx    = lsu_wb_rob_idx_st;
                wb_pkt.epoch      = lsu_wb_epoch_st;

                wb_pkt.done       = 1'b1;

                wb_pkt.uses_rd    = 1'b0;
                wb_pkt.prd_new    = '0;
                wb_pkt.data       = 32'b0;
                wb_pkt.data_valid = 1'b0;

                // Branch fields unused
                wb_pkt.is_branch   = 1'b0;
                wb_pkt.mispredict  = 1'b0;
                wb_pkt.redirect    = 1'b0;
                wb_pkt.redirect_pc = 32'b0;
                wb_pkt.act_taken   = 1'b0;

                // Optional LSU info
                wb_pkt.is_load     = 1'b0;
                wb_pkt.is_store    = 1'b1;
                wb_pkt.mem_exc     = 1'b0;
                wb_pkt.mem_addr    = 32'b0;
                wb_pkt.pc          = lsu_wb_pc_st;
            end

            SEL_LD: begin
                wb_valid          = lsu_wb_valid;

                wb_pkt.rob_idx    = lsu_wb_rob_idx;
                wb_pkt.epoch      = lsu_wb_epoch;

                wb_pkt.done       = 1'b1;

                wb_pkt.uses_rd    = lsu_wb_uses_rd;
                wb_pkt.prd_new    = lsu_wb_prd_new;
                wb_pkt.data       = lsu_wb_data;
                // For LSU: data_valid should indicate "a reg value is produced"
                wb_pkt.data_valid = lsu_wb_uses_rd;

                // Branch fields unused
                wb_pkt.is_branch   = 1'b0;
                wb_pkt.mispredict  = 1'b0;
                wb_pkt.redirect    = 1'b0;
                wb_pkt.redirect_pc = 32'b0;
                wb_pkt.act_taken   = 1'b0;

                // Optional LSU info
                wb_pkt.is_load     = 1'b1;
                wb_pkt.is_store    = 1'b0;
                wb_pkt.mem_exc     = lsu_mem_exc;
                wb_pkt.mem_addr    = lsu_mem_addr;
                wb_pkt.pc          = lsu_wb_pc;
            end

            SEL_ALU: begin
                wb_valid          = alu_wb_valid;

                wb_pkt.rob_idx    = alu_wb_rob_idx;
                wb_pkt.epoch      = alu_wb_epoch;

                wb_pkt.done       = 1'b1;

                wb_pkt.uses_rd    = alu_wb_uses_rd;
                wb_pkt.prd_new    = alu_wb_prd_new;
                wb_pkt.data       = alu_wb_data;
                wb_pkt.data_valid = alu_wb_uses_rd;

                // Branch fields unused
                wb_pkt.is_branch   = 1'b0;
                wb_pkt.mispredict  = 1'b0;
                wb_pkt.redirect    = 1'b0;
                wb_pkt.redirect_pc = 32'b0;
                wb_pkt.act_taken   = 1'b0;

                // LSU fields unused
                wb_pkt.is_load     = 1'b0;
                wb_pkt.is_store    = 1'b0;
                wb_pkt.mem_exc     = 1'b0;
                wb_pkt.mem_addr    = 32'b0;
                wb_pkt.pc          = alu_wb_pc;
            end

            default: begin
                wb_valid = 1'b0;
                wb_pkt   = '0;
            end
        endcase
    end

    // ============================================================
    // Backpressure to FUs
    //  - Only the selected producer sees ready.
    //  - For BRU, we gate with bru_wb_valid selection (br_valid).
    // ============================================================
    assign bru_wb_ready = (sel == SEL_BRU) && wb_ready;
    assign lsu_wb_ready = (sel == SEL_LD) && wb_ready;
    assign alu_wb_ready = (sel == SEL_ALU) && wb_ready;
    assign lsu_wb_ready_st = (sel == SEL_ST) && wb_ready;

endmodule
