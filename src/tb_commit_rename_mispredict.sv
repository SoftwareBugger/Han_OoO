`timescale 1ns/1ps
`include "defines.svh"

// ------------------------------------------------------------
// TB: commit_rename + ROB mispredict-driven recovery (with logs)
// Prints:
//  - per-alloc rename info (rd old/new, flags, pc, rob idx)
//  - per-commit info
//  - per-recovery pop info (what is being squashed / undone)
// ------------------------------------------------------------

module tb_commit_rename_mispredict;

  localparam int ARCH_REGS = 32;
  localparam int PHYS_REGS = 64;
  localparam int PHYS_W    = $clog2(PHYS_REGS);
  localparam int ROB_SIZE  = 16;
  localparam int ROB_W     = $clog2(ROB_SIZE);

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Cycle counter (matches your [Cxxxxx] style)
  longint unsigned cycle;
  always_ff @(posedge clk) begin
    if (!rst_n) cycle <= 0;
    else        cycle <= cycle + 1;
  end

  function automatic string xreg(input logic [4:0] r);
    return $sformatf("x%0d", r);
  endfunction

  // DUT I/O
  logic               alloc_valid;
  logic               alloc_ready;
  logic               alloc_uses_rd;
  logic [4:0]         alloc_rd_arch;
  logic               alloc_is_branch, alloc_is_load, alloc_is_store;
  logic [31:0]        alloc_pc;
  logic               alloc_epoch;
  logic [ROB_W-1:0]   alloc_rob_idx;

  logic               wb_valid;
  logic [ROB_W-1:0]   wb_rob_idx;
  logic               wb_epoch;
  logic               wb_mispredict;

  logic               commit_valid;
  logic               commit_ready;

  logic               commit_uses_rd;
  logic [4:0]         commit_rd_arch;
  logic [PHYS_W-1:0]  commit_pd_new;
  logic [PHYS_W-1:0]  commit_pd_old;
  logic               commit_is_branch, commit_is_load, commit_is_store;

  logic               flush_valid;
  logic [ROB_W-1:0]   flush_rob_idx;
  logic               flush_epoch;

  logic [4:0]         rs1_arch, rs2_arch;
  wire  [PHYS_W-1:0]  rs1_phys;
  wire  [PHYS_W-1:0]  rs2_phys;
  wire  [PHYS_W-1:0]  rd_phys;
  wire  [PHYS_W-1:0]  rd_new_phys;

  // Recovery outputs (from commit_rename/ROB)
  logic               recover_valid;
  logic [ROB_W-1:0]   recover_cur_rob_idx;
  rob_entry_t         recover_entry;

  // TB bookkeeping
  logic [ROB_W-1:0]    r0, r1, rbr, r3, r4;
  logic [PHYS_W-1:0]   x1_new, x1_old;
  logic [PHYS_W-1:0]   x2_new, x2_old;
  logic [PHYS_W-1:0]   x3_new, x3_old;
  logic [PHYS_W-1:0]   x4_new, x4_old;
  logic [PHYS_W-1:0]   x3_comm, x4_comm;

  commit_rename #(
    .ARCH_REGS(ARCH_REGS),
    .PHYS_REGS(PHYS_REGS),
    .ROB_SIZE(ROB_SIZE),
    .ROB_W(ROB_W),
    .PHYS_W(PHYS_W)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),

    .alloc_valid(alloc_valid),
    .alloc_ready(alloc_ready),
    .alloc_uses_rd(alloc_uses_rd),
    .alloc_rd_arch(alloc_rd_arch),
    .alloc_is_branch(alloc_is_branch),
    .alloc_is_load(alloc_is_load),
    .alloc_is_store(alloc_is_store),
    .alloc_pc(alloc_pc),
    .alloc_epoch(alloc_epoch),
    .alloc_rob_idx(alloc_rob_idx),

    .wb_valid(wb_valid),
    .wb_rob_idx(wb_rob_idx),
    .wb_epoch(wb_epoch),
    .wb_mispredict(wb_mispredict),

    .commit_valid(commit_valid),
    .commit_ready(commit_ready),
    .commit_uses_rd(commit_uses_rd),
    .commit_rd_arch(commit_rd_arch),
    .commit_pd_new(commit_pd_new),
    .commit_pd_old(commit_pd_old),
    .commit_is_branch(commit_is_branch),
    .commit_is_load(commit_is_load),
    .commit_is_store(commit_is_store),

    .flush_valid(flush_valid),
    .flush_rob_idx(flush_rob_idx),
    .flush_epoch(flush_epoch),

    .rs1_arch(rs1_arch),
    .rs2_arch(rs2_arch),

    .rs1_phys(rs1_phys),
    .rs2_phys(rs2_phys),
    .rd_phys(rd_phys),
    .rd_new_phys(rd_new_phys),

    .recover_valid(recover_valid),
    .recover_cur_rob_idx(recover_cur_rob_idx),
    .recover_entry(recover_entry)
  );

  // ------------------------------------------------------------
  // Golden model: speculative RAT + freelist (queue; membership ok)
  // ------------------------------------------------------------
  logic [PHYS_W-1:0] golden_rat [ARCH_REGS];
  logic [PHYS_W-1:0] golden_free_q[$];

  function automatic logic [PHYS_W-1:0] pop_free();
    logic [PHYS_W-1:0] x;
    if (golden_free_q.size() == 0) $fatal(1, "[TB] Golden freelist empty");
    x = golden_free_q[0];
    golden_free_q.pop_front();
    return x;
  endfunction

  task automatic push_free(input logic [PHYS_W-1:0] pd);
    golden_free_q.push_back(pd);
  endtask

  task automatic golden_reset();
    int i;
    golden_free_q.delete();
    for (i = 0; i < ARCH_REGS; i++) golden_rat[i] = i[PHYS_W-1:0];
    for (i = 32; i < PHYS_REGS; i++) golden_free_q.push_back(i[PHYS_W-1:0]);
  endtask

  // ------------------------------------------------------------
  // Basic drive helpers
  // ------------------------------------------------------------
  task automatic init_signals();
    alloc_valid     = 0;
    alloc_uses_rd   = 0;
    alloc_rd_arch   = '0;
    alloc_is_branch = 0;
    alloc_is_load   = 0;
    alloc_is_store  = 0;
    alloc_pc        = '0;
    alloc_epoch     = 0;

    wb_valid        = 0;
    wb_rob_idx      = '0;
    wb_epoch        = 0;

    commit_ready    = 1'b1;

    flush_valid     = 0;
    flush_rob_idx   = '0;
    flush_epoch     = 0;

    rs1_arch        = 5'd0;
    rs2_arch        = 5'd0;
  endtask

  task automatic do_reset();
    init_signals();
    golden_reset();
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // Pretty commit logging
  always_ff @(posedge clk) begin
    if (rst_n && commit_valid && commit_ready) begin
      if (commit_uses_rd) begin
        $display("[C%0d] COMMIT | rd=%s pd_old=%0d pd_new=%0d | br=%0d ld=%0d st=%0d",
                 cycle, xreg(commit_rd_arch), commit_pd_old, commit_pd_new,
                 commit_is_branch, commit_is_load, commit_is_store);
      end else begin
        $display("[C%0d] COMMIT | rd=-- | br=%0d ld=%0d st=%0d",
                 cycle, commit_is_branch, commit_is_load, commit_is_store);
      end
    end
  end

  // Allocate one instruction; update golden RAT if uses_rd; print rename info
  task automatic alloc_uop(
    input  logic uses_rd,
    input  logic [4:0] rd_arch,
    input  logic is_branch,
    output logic [ROB_W-1:0] rob_idx_out,
    output logic [PHYS_W-1:0] pd_new_out,
    output logic [PHYS_W-1:0] pd_old_out
  );
    logic [PHYS_W-1:0] exp_old, exp_new;

    exp_old = uses_rd ? golden_rat[rd_arch] : '0;
    exp_new = uses_rd ? pop_free()          : '0;

    @(negedge clk);
    alloc_valid     = 1'b1;
    alloc_uses_rd   = uses_rd;
    alloc_rd_arch   = rd_arch;
    alloc_is_branch = is_branch;
    alloc_is_load   = 1'b0;
    alloc_is_store  = 1'b0;
    alloc_pc        = 32'h1000 + {24'h0, rd_arch, 3'b000};
    alloc_epoch     = 1'b0;

    if (!alloc_ready) $fatal(1, "[TB] alloc_ready=0 at alloc");

    // sample rename mapping
    #1;

    if (uses_rd) begin
      if (rd_phys !== exp_old) $fatal(1, "[TB] pd_old mismatch exp=%0d got=%0d", exp_old, rd_phys);
      if (rd_new_phys !== exp_new) $fatal(1, "[TB] pd_new mismatch exp=%0d got=%0d", exp_new, rd_new_phys);
      golden_rat[rd_arch] = exp_new;
      $display("[C%0d] ALLOC | rob=%0d rd=%s old=%0d new=%0d | br=%0d ld=%0d st=%0d | pc=%h",
               cycle, alloc_rob_idx, xreg(rd_arch), exp_old, exp_new,
               is_branch, 1'b0, 1'b0, alloc_pc);
    end else begin
      $display("[C%0d] ALLOC | rob=%0d rd=-- | br=%0d ld=%0d st=%0d | pc=%h",
               cycle, alloc_rob_idx, is_branch, 1'b0, 1'b0, alloc_pc);
    end

    rob_idx_out = alloc_rob_idx;
    pd_new_out  = exp_new;
    pd_old_out  = exp_old;

    @(negedge clk);
    alloc_valid = 1'b0;
  endtask

  task automatic wb_done(input logic [ROB_W-1:0] ridx);
    @(negedge clk);
    wb_valid   = 1'b1;
    wb_rob_idx = ridx;
    wb_epoch   = 1'b0;
    @(negedge clk);
    wb_valid   = 1'b0;
  endtask

  task automatic check_map(input logic [4:0] arch, input logic [PHYS_W-1:0] exp);
    rs1_arch = arch;
    #1;
    if (rs1_phys !== exp)
      $fatal(1, "[TB] RAT map mismatch x%0d exp p%0d got p%0d", arch, exp, rs1_phys);
  endtask

  // Inject mispredict into the branch ROB entry, then WB it.
  // Uses force/release to ensure it sticks through WB edge.
  task automatic trigger_branch_mispredict(input logic [ROB_W-1:0] br_rob_idx);
    $display("=== TRIGGER MISPREDICT on branch rob=%0d at C%0d ===", br_rob_idx, cycle);

    // Adjust these instance names if your hierarchy differs.
    // dut.rob.rob_mem[br_rob_idx].mispredict = 1'b1;
    // dut.rob.rob_mem[br_rob_idx].is_branch  = 1'b1;
    wb_mispredict = 1'b1;
    wb_done(br_rob_idx);
    wb_mispredict = 1'b0;

    // dut.rob.rob_mem[br_rob_idx].mispredict ;
    // dut.rob.rob_mem[br_rob_idx].is_branch;
  endtask

  // Consume recovery stream and print each recovered entry.
  task automatic consume_recovery_until_done(
    input logic [ROB_W-1:0] br_rob_idx,
    input logic [PHYS_W-1:0] x3_comm_in,
    input logic [PHYS_W-1:0] x4_comm_in
  );
    int guard = 0;

    // Wait for recovery to start
    while (!recover_valid) begin
      @(posedge clk);
      guard++;
      if (guard > 50) $fatal(1, "[TB] recovery did not start");
    end

    $display("=== RECOVERY START (stop at branch rob=%0d) at C%0d ===", br_rob_idx, cycle);

    // While recovering, update golden model as if undoing speculative renames
    guard = 0;
    while (recover_valid) begin
      if (recover_entry.uses_rd) begin
        $display("[C%0d] RECOVER | pop_rob=%0d rd=%s pd_old=%0d pd_new=%0d | br=%0d mispred=%0d | pc=%h",
                 cycle, recover_cur_rob_idx,
                 xreg(recover_entry.rd_arch),
                 recover_entry.pd_old, recover_entry.pd_new,
                 recover_entry.is_branch, recover_entry.mispredict,
                 recover_entry.pc);

        golden_rat[recover_entry.rd_arch] = recover_entry.pd_old;
        push_free(recover_entry.pd_new);
      end else begin
        $display("[C%0d] RECOVER | pop_rob=%0d rd=-- | br=%0d mispred=%0d | pc=%h",
                 cycle, recover_cur_rob_idx,
                 recover_entry.is_branch, recover_entry.mispredict,
                 recover_entry.pc);
      end
      @(posedge clk);
      #1;

      guard++;
      if (guard > ROB_SIZE + 8) $fatal(1, "[TB] recovery stuck too long");
    end

    $display("=== RECOVERY END at C%0d ===", cycle);

    // After recovery, x3/x4 must be restored to committed mapping
    check_map(5'd3, x3_comm_in);
    check_map(5'd4, x4_comm_in);
  endtask

  // ------------------------------------------------------------
  // TEST: branch mispredict squashes younger renames
  // ------------------------------------------------------------
  initial begin
    do_reset();
    wb_mispredict = 1'b0;

    // Older renaming uops
    alloc_uop(1'b1, 5'd1, 1'b0, r0, x1_new, x1_old);
    alloc_uop(1'b1, 5'd2, 1'b0, r1, x2_new, x2_old);

    // Branch (no dest)
    alloc_uop(1'b0, 5'd0, 1'b1, rbr, /*pd_new*/ x3_new, /*pd_old*/ x3_old);

    // Save committed mapping for x3/x4 (initially identity p3/p4)
    x3_comm = golden_rat[5'd3];
    x4_comm = golden_rat[5'd4];

    // Younger renaming uops (must be squashed)
    alloc_uop(1'b1, 5'd3, 1'b0, r3, x3_new, x3_old);
    alloc_uop(1'b1, 5'd4, 1'b0, r4, x4_new, x4_old);

    // Mark all done (so commit isn't blocked by done=0)
    wb_done(r0);
    wb_done(r1);
    wb_done(r3);
    wb_done(r4);

    // Trigger mispredict on branch WB (sets mispredict/is_branch inside ROB entry)
    trigger_branch_mispredict(rbr);

    // Consume recovery pops; update golden as undo log; print everything
    consume_recovery_until_done(rbr, x3_comm, x4_comm);

    // Older renames (x1/x2) should remain mapped to their speculative pd_new
    check_map(5'd1, x1_new);
    check_map(5'd2, x2_new);

    $display("[TB] BRANCH MISPREDICT RECOVERY TEST PASS ✅");
    $finish;
  end

endmodule
