`include "defines.svh"
// Reservation Station (RS) module
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
  input  logic [1:0]        recover_epoch,


  // -------------------------
  // Status
  // -------------------------
  output logic              busy
);

  // -------------------------
  // RS storage
  // -------------------------
  rs_uop_t entries [RS_SIZE-1:0];
  logic    [RS_SIZE-1:0] valid;

  // -------------------------
  // Free slot detection
  // -------------------------
  int free_idx;
  logic has_free;

  // -------------------------
  // Issue selection
  // -------------------------
  int issue_idx [FU_NUM-1:0];
  logic [FU_NUM-1:0] has_issue;

  always_comb begin
    has_free = ~&valid; // at least one free entry
    free_idx = 0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (!valid[i]) begin
        free_idx = i;
      end
    end
  end

  assign disp_ready = has_free;
  assign busy       = !has_free;

  // -------------------------
  // Wakeup logic (tag match)
  // -------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < RS_SIZE; i++) begin
        valid[i] <= 1'b0;
      end
    end else if (flush_valid) begin
      for (int i = 0; i < RS_SIZE; i++) begin
        valid[i] <= 1'b0;
      end
    end else if (recover_valid) begin
      // On recovery, invalidate entries from mispredicted branch onwards
      for (int i = 0; i < RS_SIZE; i++) begin
        if (valid[i] && 
            (entries[i].rob_idx == recover_rob_idx) && 
            (entries[i].epoch == recover_epoch)) begin
          valid[i] <= 1'b0;
        end
      end
    end
    else begin
      // Wakeup on CDB
      if (wb_valid) begin
        for (int i = 0; i < RS_SIZE; i++) begin
          if (valid[i]) begin
            // Check prs1 - uses_rs1 is in bundle, but prs1/rdy1 are at top level
            if (entries[i].bundle.uses_rs1 && !entries[i].rdy1 &&
                entries[i].prs1 == wb_pd)
              entries[i].rdy1 <= 1'b1;

            // Check prs2 - uses_rs2 is in bundle, but prs2/rdy2 are at top level
            if (entries[i].bundle.uses_rs2 && !entries[i].rdy2 &&
                entries[i].prs2 == wb_pd)
              entries[i].rdy2 <= 1'b1;
          end
        end
      end

      // Dispatch allocation
      if (disp_valid && disp_ready) begin
        entries[free_idx] <= disp_uop;
        valid[free_idx]   <= 1'b1;
      end

      // Issue consumes entry
      for (int i = 0; i < FU_NUM; i++) begin
        if (issue_valid[i] && issue_ready[i]) begin
          valid[issue_idx[i]] <= 1'b0;
        end
      end
    end
  end

  // -------------------------
  // Issue selection logic
  // -------------------------
  generate 
    for (genvar fu = 0; fu < FU_NUM; fu++) begin : ISSUE_SELECT
      always_comb begin
        
        issue_idx[fu] = RS_SIZE - 1; // default: last entry
        
        // Select oldest ready instruction for this FU
        for (int i = RS_SIZE-1; i >= 0; i--) begin
          if (valid[i] &&
              (!entries[i].bundle.uses_rs1 || entries[i].rdy1) &&
              (!entries[i].bundle.uses_rs2 || entries[i].rdy2) &&
              (uop_to_fu(entries[i].bundle.uop_class) == fu_e'(fu))) begin
            issue_idx[fu] = i;
          end
        end
      end
      // Check if entry at issue_idx is ready
      // uses_rs1/uses_rs2 are in bundle, but rdy1/rdy2 are at top level
      assign has_issue[fu] = valid[issue_idx[fu]] &&
                      (!entries[issue_idx[fu]].bundle.uses_rs1 || entries[issue_idx[fu]].rdy1) &&
                      (!entries[issue_idx[fu]].bundle.uses_rs2 || entries[issue_idx[fu]].rdy2) &&
                      (uop_to_fu(entries[issue_idx[fu]].bundle.uop_class) == fu_e'(fu));
      assign issue_valid[fu] = has_issue[fu];
      assign issue_uop[fu]   = entries[issue_idx[fu]];
    end
  endgenerate

endmodule