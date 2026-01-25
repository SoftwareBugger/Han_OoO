`include "defines.svh"

module RS #(
  parameter int RS_SIZE = 2*FU_NUM
)(
  input  logic              clk,
  input  logic              rst_n,

  // Dispatch
  input  logic              disp_valid,
  output logic              disp_ready,
  input  rs_uop_t           disp_uop,

  // Wakeup from CDB
  input  logic              wb_valid,
  input  logic              wb_ready,
  input  logic [PHYS_W-1:0] wb_pd,

  // Issue to FUs
  output logic [FU_NUM-1:0] issue_valid,
  input  logic [FU_NUM-1:0] issue_ready,
  output rs_uop_t           issue_uop [FU_NUM-1:0],

  // Flush / recover
  input  logic              flush_valid,
  input  logic              recover_valid,
  input  logic [ROB_W-1:0]  recover_rob_idx,
  input  logic [EPOCH_W-1:0] recover_epoch,

  // Status
  output logic              busy
);

  rs_uop_t entries[FU_NUM][2];
  logic    valid  [FU_NUM][2];
  logic    oldest [FU_NUM];   // 0 or 1 = which slot is oldest

  // ------------------------------------------------------------
  // Dispatch logic
  // ------------------------------------------------------------
  fu_e  disp_fu;
  logic disp_has_free;
  logic disp_free_idx;

  always_comb begin
    disp_fu       = uop_to_fu(disp_uop.bundle.uop_class);
    disp_has_free = (!valid[int'(disp_fu)][0]) || (!valid[int'(disp_fu)][1]);

    // Prefer slot0 if free, else slot1
    if (!valid[int'(disp_fu)][0])
      disp_free_idx = 1'b0;
    else
      disp_free_idx = 1'b1;
  end

  assign disp_ready = disp_has_free;
  assign busy       = !disp_ready;

  // ------------------------------------------------------------
  // Issue selection (oldest first, then younger)
  // ------------------------------------------------------------
  genvar f;
  generate
    logic [FU_NUM-1:0] o, y;
    for (f = 0; f < FU_NUM; f++) begin : GEN_ISSUE

      always_comb begin
        o[f] = oldest[f];
        y[f] = ~oldest[f];

        issue_valid[f] = 1'b0;
        issue_uop[f]   = '0;

        // Oldest first
        if (valid[f][o[f]] &&
            (!entries[f][o[f]].bundle.uses_rs1 || entries[f][o[f]].rdy1) &&
            (!entries[f][o[f]].bundle.uses_rs2 || entries[f][o[f]].rdy2)) begin
          issue_valid[f] = 1'b1;
          issue_uop[f]   = entries[f][o[f]];
        end
        // Else younger
        else if (valid[f][y[f]] &&
                 (!entries[f][y[f]].bundle.uses_rs1 || entries[f][y[f]].rdy1) &&
                 (!entries[f][y[f]].bundle.uses_rs2 || entries[f][y[f]].rdy2)) begin
          issue_valid[f] = 1'b1;
          issue_uop[f]   = entries[f][y[f]];
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // Helper: repair oldest pointer if it points to an invalid slot
  // Rule: if exactly one slot is valid, oldest must point to it.
  // ------------------------------------------------------------
  task automatic repair_oldest(input int fu);
    begin
      if ( valid[fu][0] && !valid[fu][1]) oldest[fu] <= 1'b0;
      else if (!valid[fu][0] &&  valid[fu][1]) oldest[fu] <= 1'b1;
      // if both valid or both invalid: keep as-is (don't-care)
    end
  endtask

  // ------------------------------------------------------------
  // Sequential logic
  // ------------------------------------------------------------
  logic [FU_NUM-1:0] old, yng;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int fu = 0; fu < FU_NUM; fu++) begin
        valid[fu][0] <= 1'b0;
        valid[fu][1] <= 1'b0;
        oldest[fu]   <= 1'b0;
      end

    end else if (flush_valid) begin
      for (int fu = 0; fu < FU_NUM; fu++) begin
        valid[fu][0] <= 1'b0;
        valid[fu][1] <= 1'b0;
        oldest[fu]   <= 1'b0;
      end

    end else begin
      // ---------------- Wakeup ----------------
      if (wb_valid && wb_ready) begin
        for (int fu = 0; fu < FU_NUM; fu++) begin
          for (int i = 0; i < 2; i++) begin
            if (valid[fu][i]) begin
              if (entries[fu][i].bundle.uses_rs1 && !entries[fu][i].rdy1 &&
                  (entries[fu][i].prs1 == wb_pd))
                entries[fu][i].rdy1 <= 1'b1;

              if (entries[fu][i].bundle.uses_rs2 && !entries[fu][i].rdy2 &&
                  (entries[fu][i].prs2 == wb_pd))
                entries[fu][i].rdy2 <= 1'b1;
            end
          end
        end
      end

      // ---------------- Recovery ----------------
      if (recover_valid) begin
        for (int fu = 0; fu < FU_NUM; fu++) begin
          for (int i = 0; i < 2; i++) begin
            if (valid[fu][i] &&
                (entries[fu][i].rob_idx == recover_rob_idx) &&
                (entries[fu][i].epoch   == recover_epoch)) begin
              valid[fu][i] <= 1'b0;
              oldest[fu]   <= ~i; // point to the other slot
            end
          end
        end
      end

      // ---------------- Dispatch ----------------
      if (disp_valid && disp_ready) begin
        int fu;
        fu = int'(disp_fu);

        entries[fu][disp_free_idx] <= disp_uop;
        valid  [fu][disp_free_idx] <= 1'b1;

        oldest[fu] <= ~disp_free_idx; // new entry is the youngest
      end

      // ---------------- Issue consume ----------------
      for (int fu = 0; fu < FU_NUM; fu++) begin
        if (issue_valid[fu] && issue_ready[fu]) begin
          old[fu] = oldest[fu];
          yng[fu] = ~oldest[fu];

          // Oldest issued
          if (valid[fu][old[fu]] &&
              (!entries[fu][old[fu]].bundle.uses_rs1 || entries[fu][old[fu]].rdy1) &&
              (!entries[fu][old[fu]].bundle.uses_rs2 || entries[fu][old[fu]].rdy2)) begin
            valid[fu][old[fu]] <= 1'b0;
          end
          // Younger issued
          else if (valid[fu][yng[fu]] &&
                  (!entries[fu][yng[fu]].bundle.uses_rs1 || entries[fu][yng[fu]].rdy1) &&
                  (!entries[fu][yng[fu]].bundle.uses_rs2 || entries[fu][yng[fu]].rdy2)) begin
            valid[fu][yng[fu]] <= 1'b0;
          end
        end
      end
    end
  end

endmodule
