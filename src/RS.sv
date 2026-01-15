`include "defines.svh"
// Reservation Station (RS) module
//
// Per-FU partitioned RS while keeping the external interface identical.
// - Dispatch routes the incoming uop into the partition selected by uop_to_fu().
// - disp_ready reflects availability in the target partition.
// - Issue selection scans only within each FU partition.
// - Wakeup / flush / recovery are broadcast across all partitions.
module RS #(
  parameter int RS_SIZE = 8
)(
  input  logic              clk,
  input  logic              rst_n,

  // -------------------------
  // Dispatch from rename
  // -------------------------
  input  logic              disp_valid,
  output logic              disp_ready,
  input  rs_uop_t           disp_uop,

  // -------------------------
  // Wakeup from CDB
  // -------------------------
  input  logic              wb_valid,
  input  logic [PHYS_W-1:0] wb_pd,

  // -------------------------
  // Issue to execution / issue_select
  // -------------------------
  output logic [FU_NUM-1:0] issue_valid,
  input  logic [FU_NUM-1:0] issue_ready,
  output rs_uop_t           issue_uop [FU_NUM-1:0],

  // -------------------------
  // flush
  // -------------------------
  input  logic              flush_valid,

  // -------------------------
  // Recovery
  // -------------------------
  input  logic              recover_valid,
  input  logic [ROB_W-1:0]  recover_rob_idx,
  input  logic [EPOCH_W-1:0]        recover_epoch,

  // -------------------------
  // Status
  // -------------------------
  output logic              busy
);

  // -------------------------
  // Local params / helpers
  // -------------------------
  // Partition depth per FU. If RS_SIZE is not divisible by FU_NUM, this rounds up,
  // slightly increasing total physical storage, but preserving the interface.
  localparam int RS_PER_FU = (RS_SIZE + FU_NUM - 1) / FU_NUM;

  function automatic logic older_than(
    input logic [1:0]       ea,
    input logic [ROB_W-1:0] ia,
    input logic [1:0]       eb,
    input logic [ROB_W-1:0] ib
  );
    begin
      if (ea != eb) older_than = (ea < eb);
      else          older_than = (ia < ib);
    end
  endfunction

  // -------------------------
  // RS storage (per-FU partitions)
  // -------------------------
  rs_uop_t entries [FU_NUM-1:0][RS_PER_FU-1:0];
  logic    valid   [FU_NUM-1:0][RS_PER_FU-1:0];

  // -------------------------
  // Dispatch routing & free slot detection
  // -------------------------
  fu_e disp_fu;
  int  disp_free_idx;
  logic disp_has_free;

  always_comb begin
    disp_fu       = uop_to_fu(disp_uop.bundle.uop_class);
    disp_has_free = 1'b0;
    disp_free_idx = 0;

    // Find a free slot in the target partition. Choose lowest index free slot.
    for (int i = 0; i < RS_PER_FU; i++) begin
      if (!valid[int'(disp_fu)][i]) begin
        disp_has_free = 1'b1;
        disp_free_idx = i;
        break;
      end
    end
  end

  assign disp_ready = disp_has_free;
  assign busy       = !disp_ready; // with single-lane dispatch, this matches upstream stall intent

  // -------------------------
  // Issue selection (per-FU)
  // -------------------------
  int  issue_idx [FU_NUM-1:0];
  logic has_issue[ FU_NUM-1:0];

  genvar fu;
  generate
    for (fu = 0; fu < FU_NUM; fu++) begin : ISSUE_SELECT
      always_comb begin
        has_issue[fu] = 1'b0;
        issue_idx[fu] = 0;

        // Track best (oldest) candidate
        logic [EPOCH_W-1:0]       best_epoch;
        logic [ROB_W-1:0] best_rob;

        best_epoch = {EPOCH_W{1'b1}};
        best_rob   = {ROB_W{1'b1}};

        for (int i = 0; i < RS_PER_FU; i++) begin
          if (valid[fu][i] &&
              (!entries[fu][i].bundle.uses_rs1 || entries[fu][i].rdy1) &&
              (!entries[fu][i].bundle.uses_rs2 || entries[fu][i].rdy2)) begin

            if (!has_issue[fu] ||
                older_than(entries[fu][i].epoch, entries[fu][i].rob_idx, best_epoch, best_rob)) begin
              has_issue[fu] = 1'b1;
              issue_idx[fu] = i;
              best_epoch    = entries[fu][i].epoch;
              best_rob      = entries[fu][i].rob_idx;
            end
          end
        end
      end

      assign issue_valid[fu] = has_issue[fu];
      assign issue_uop[fu]   = entries[fu][issue_idx[fu]];
    end
  endgenerate

  // -------------------------
  // State updates: reset/flush/recover/wakeup/dispatch/issue
  // -------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int f = 0; f < FU_NUM; f++) begin
        for (int i = 0; i < RS_PER_FU; i++) begin
          valid[f][i] <= 1'b0;
        end
      end
    end else if (flush_valid) begin
      for (int f = 0; f < FU_NUM; f++) begin
        for (int i = 0; i < RS_PER_FU; i++) begin
          valid[f][i] <= 1'b0;
        end
      end
    end else if (recover_valid) begin
      // Invalidate matching ROB idx + epoch across all FU partitions
      for (int f = 0; f < FU_NUM; f++) begin
        for (int i = 0; i < RS_PER_FU; i++) begin
          if (valid[f][i] &&
              (entries[f][i].rob_idx == recover_rob_idx) &&
              (entries[f][i].epoch   == recover_epoch)) begin
            valid[f][i] <= 1'b0;
          end
        end
      end
    end else begin
      // Wakeup on CDB
      if (wb_valid) begin
        for (int f = 0; f < FU_NUM; f++) begin
          for (int i = 0; i < RS_PER_FU; i++) begin
            if (valid[f][i]) begin
              if (entries[f][i].bundle.uses_rs1 && !entries[f][i].rdy1 &&
                  entries[f][i].prs1 == wb_pd)
                entries[f][i].rdy1 <= 1'b1;

              if (entries[f][i].bundle.uses_rs2 && !entries[f][i].rdy2 &&
                  entries[f][i].prs2 == wb_pd)
                entries[f][i].rdy2 <= 1'b1;
            end
          end
        end
      end

      // Dispatch allocation into target FU partition
      if (disp_valid && disp_ready) begin
        entries[int'(disp_fu)][disp_free_idx] <= disp_uop;
        valid  [int'(disp_fu)][disp_free_idx] <= 1'b1;
      end

      // Issue consumes entry (one per FU)
      for (int f = 0; f < FU_NUM; f++) begin
        if (issue_valid[f] && issue_ready[f]) begin
          valid[f][issue_idx[f]] <= 1'b0;
        end
      end
    end
  end

endmodule
