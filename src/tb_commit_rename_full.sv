`timescale 1ns/1ps
`include "defines.svh"

// ------------------------------------------------------------
// Combined TB: commit_rename (rename+ROB+freelist) tests
//  - TEST A: WAW then probe RAW mapping + reuse
//  - TEST B: ROB full stall
//  - TEST C: uses_rd=0 does not allocate
//  - TEST D: branch mispredict recovery (ROB-walk pop-from-tail)
//
// Notes:
//  - Keeps original task/IO style from tb_commit_rename.sv.
//  - Adds recovery signals only; does not restructure core tasks.
//  - Uses hierarchical force to inject mispredict into ROB entry.
// ------------------------------------------------------------

module tb_commit_rename_full;

  // -------------------------
  // Parameters (match DUT)
  // -------------------------
  localparam int ARCH_REGS = 32;
  localparam int PHYS_REGS = 64;
  localparam int PHYS_W    = $clog2(PHYS_REGS);
  localparam int ROB_SIZE  = 16;
  localparam int ROB_W     = $clog2(ROB_SIZE);

  // -------------------------
  // Clock / Reset
  // -------------------------
  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk; // 100MHz

  // Optional cycle counter for prints
  longint unsigned cyc;
  always_ff @(posedge clk) begin
    if (!rst_n) cyc <= 0;
    else        cyc <= cyc + 1;
  end

  // -------------------------
  // DUT I/O
  // -------------------------
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

  // debug outputs from DUT
  wire  [PHYS_W-1:0]  rs1_phys_dbg;
  wire  [PHYS_W-1:0]  rs2_phys_dbg;
  wire  [PHYS_W-1:0]  rd_phys_dbg;
  wire  [PHYS_W-1:0]  rd_new_phys_dbg;

  logic [PHYS_W-1:0] rs1_phys, rs2_phys, rd_phys, rd_new_phys;

  // Recovery outputs (new)
  logic               recover_valid;
  logic [ROB_W-1:0]   recover_cur_rob_idx;
  rob_entry_t         recover_entry;

  // -------------------------
  // Instantiate DUT
  // -------------------------
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

    .rs1_phys(rs1_phys_dbg),
    .rs2_phys(rs2_phys_dbg),
    .rd_phys(rd_phys_dbg),
    .rd_new_phys(rd_new_phys_dbg),

    .recover_valid(recover_valid),
    .recover_cur_rob_idx(recover_cur_rob_idx),
    .recover_entry(recover_entry)
  );

  always_comb begin
    rs1_phys    = rs1_phys_dbg;
    rs2_phys    = rs2_phys_dbg;
    rd_phys     = rd_phys_dbg;
    rd_new_phys = rd_new_phys_dbg;
  end

  // -------------------------
  // Golden model (TB)
  // -------------------------
  logic [PHYS_W-1:0] golden_rat [ARCH_REGS];
  logic [PHYS_W-1:0] golden_free_q[$];   // FIFO freelist model
  logic [PHYS_W-1:0] expect_reuse_q[$];  // regs that should be freed and later reused

  typedef struct packed {
    logic              uses_rd;
    logic [4:0]        rd_arch;
    logic [PHYS_W-1:0] pd_new;
    logic [PHYS_W-1:0] pd_old;
    logic [ROB_W-1:0]  rob_idx;
    logic              epoch;
    logic [31:0]       pc;
  } uop_t;

  uop_t inflight_q[$]; // program order

  uop_t i0, i1, i2, i3, i4;
  int seen_reuse = 0;
  int loops = 0;
  logic [PHYS_W-1:0] target;

  // -------------------------
  // Helpers (kept close to original TB)
  // -------------------------
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

    commit_ready    = 0;

    flush_valid     = 0;
    flush_rob_idx   = '0;
    flush_epoch     = 0;

    rs1_arch        = 5'd1;
    rs2_arch        = 5'd2;
  endtask

  task automatic golden_reset();
    int i;
    golden_free_q.delete();
    expect_reuse_q.delete();
    inflight_q.delete();

    for (i = 0; i < ARCH_REGS; i++)
      golden_rat[i] = i[PHYS_W-1:0];

    for (i = 32; i < PHYS_REGS; i++)
      golden_free_q.push_back(i[PHYS_W-1:0]);
  endtask

  task automatic do_reset();
    init_signals();
    rst_n = 0;
    golden_reset();
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  function automatic logic [PHYS_W-1:0] pop_free();
    logic [PHYS_W-1:0] x;
    if (golden_free_q.size() == 0) $fatal(1, "[TB] Golden freelist empty");
    x = golden_free_q[0];
    golden_free_q.pop_front();
    return x;
  endfunction

  task automatic push_free(input logic [PHYS_W-1:0] pd);
    golden_free_q.push_back(pd);
    expect_reuse_q.push_back(pd);
  endtask

  // One-cycle allocation on negedge to avoid TB/DUT race (original)
  task automatic alloc_inst(
    input  logic        uses_rd,
    input  logic [4:0]  rd_arch,
    input  logic [31:0] pc,
    output uop_t        u
  );
    logic [PHYS_W-1:0] exp_old, exp_new;

    exp_old = golden_rat[rd_arch];
    exp_new = uses_rd ? pop_free() : '0;

    @(negedge clk);
    alloc_valid     = 1'b1;
    alloc_uses_rd   = uses_rd;
    alloc_rd_arch   = rd_arch;
    alloc_is_branch = 1'b0;
    alloc_is_load   = 1'b0;
    alloc_is_store  = 1'b0;
    alloc_pc        = pc;
    alloc_epoch     = alloc_epoch;

    #1;
    if (alloc_ready !== 1'b1) begin
      if (uses_rd) push_free(exp_new);
      $fatal(1, "[TB] alloc_ready=0 when trying to allocate");
    end

    if (uses_rd) begin
      if (rd_phys !== exp_old) $fatal(1, "[TB] Rename pd_old mismatch: exp=%0d got=%0d (rd=x%0d pc=%h)", exp_old, rd_phys, rd_arch, pc);
      if (rd_new_phys !== exp_new) $fatal(1, "[TB] Rename pd_new mismatch: exp=%0d got=%0d (rd=x%0d pc=%h)", exp_new, rd_new_phys, rd_arch, pc);
    end

    u.uses_rd = uses_rd;
    u.rd_arch = rd_arch;
    u.pd_old  = exp_old;
    u.pd_new  = exp_new;
    u.rob_idx = alloc_rob_idx;
    u.epoch   = alloc_epoch;
    u.pc      = pc;

    if (uses_rd) golden_rat[rd_arch] = exp_new;

    inflight_q.push_back(u);

    @(negedge clk);
    alloc_valid = 1'b0;
  endtask

  // Branch allocation helper (minimal: same signature style as alloc_inst, but sets is_branch)
  task automatic alloc_inst_branch(
    input  logic [31:0] pc,
    output uop_t        u
  );
    @(negedge clk);
    alloc_valid     = 1'b1;
    alloc_uses_rd   = 1'b0;
    alloc_rd_arch   = 5'd0;
    alloc_is_branch = 1'b1;
    alloc_is_load   = 1'b0;
    alloc_is_store  = 1'b0;
    alloc_pc        = pc;
    alloc_epoch     = alloc_epoch;

    #1;
    if (alloc_ready !== 1'b1) begin
      $fatal(1, "[TB] alloc_ready=0 when trying to allocate BRANCH");
    end

    u.uses_rd = 1'b0;
    u.rd_arch = 5'd0;
    u.pd_old  = '0;
    u.pd_new  = '0;
    u.rob_idx = alloc_rob_idx;
    u.epoch   = alloc_epoch;
    u.pc      = pc;

    inflight_q.push_back(u);

    @(negedge clk);
    alloc_valid = 1'b0;
    alloc_is_branch = 1'b0;
  endtask

  task automatic wb_done(input logic [ROB_W-1:0] idx, input logic epoch);
    @(negedge clk);
    wb_valid   = 1'b1;
    wb_rob_idx = idx;
    wb_epoch   = epoch;
    @(negedge clk);
    wb_valid   = 1'b0;
  endtask

  task automatic commit_one();
    uop_t u;
    int watchdog = 0;

    if (inflight_q.size() == 0) $fatal(1, "[TB] commit_one: inflight empty");
    u = inflight_q[0];

    while (!commit_valid) begin
      @(posedge clk);
      watchdog++;
      if (watchdog > 200) $fatal(1, "[TB] Timeout waiting commit_valid");
    end

    @(negedge clk);
    commit_ready = 1'b1;
    @(negedge clk);
    commit_ready = 1'b0;

    if (commit_uses_rd !== u.uses_rd) $fatal(1, "[TB] commit_uses_rd mismatch");
    if (u.uses_rd) begin
      if (commit_rd_arch !== u.rd_arch) $fatal(1, "[TB] commit_rd_arch mismatch exp=x%0d got=x%0d pc=%h", u.rd_arch, commit_rd_arch, u.pc);
      if (commit_pd_new  !== u.pd_new)  $fatal(1, "[TB] commit_pd_new mismatch exp=%0d got=%0d pc=%h", u.pd_new, commit_pd_new, u.pc);
      if (commit_pd_old  !== u.pd_old)  $fatal(1, "[TB] commit_pd_old mismatch exp=%0d got=%0d pc=%h", u.pd_old, commit_pd_old, u.pc);

      // Golden: on commit, free pd_old
      push_free(u.pd_old);
    end

    inflight_q.pop_front();
  endtask

  // Drive an allocation attempt and EXPECT alloc_ready=0
  task automatic alloc_expect_stall(
    input logic        uses_rd,
    input logic [4:0]  rd_arch,
    input logic [31:0] pc
  );
    int free_sz_before;
    free_sz_before = golden_free_q.size();

    @(negedge clk);
    alloc_valid     = 1'b1;
    alloc_uses_rd   = uses_rd;
    alloc_rd_arch   = rd_arch;
    alloc_is_branch = 1'b0;
    alloc_is_load   = 1'b0;
    alloc_is_store  = 1'b0;
    alloc_pc        = pc;
    alloc_epoch     = alloc_epoch;

    #1;
    if (alloc_ready !== 1'b0) begin
      $fatal(1, "[TB] Expected alloc_ready=0 (stall) but got alloc_ready=1 at pc=%h rd=x%0d", pc, rd_arch);
    end
    if (golden_free_q.size() !== free_sz_before) begin
      $fatal(1, "[TB] Golden freelist changed during a supposed stall");
    end

    @(negedge clk);
    alloc_valid = 1'b0;
  endtask

  task automatic test_rob_full_stall();
    uop_t tmp;
    int i;

    $display("=== TEST B: Fill ROB and ensure alloc stalls when full ===");

    for (i = 0; i < ROB_SIZE; i++) begin
      alloc_inst(1'b1, 5'd1, 32'h2000 + 4*i, tmp);
    end

    alloc_expect_stall(1'b1, 5'd2, 32'h3000);

    wb_done(inflight_q[0].rob_idx, inflight_q[0].epoch);
    commit_one();

    alloc_inst(1'b1, 5'd2, 32'h3004, tmp);

    while (inflight_q.size() != 0) begin
      wb_done(inflight_q[0].rob_idx, inflight_q[0].epoch);
      commit_one();
    end
  endtask

  task automatic test_no_rd_does_not_allocate();
    uop_t u;
    int free_before, free_after;

    $display("=== TEST C: uses_rd=0 does not pop freelist ===");

    free_before = golden_free_q.size();
    alloc_inst(1'b0, 5'd0, 32'h4000, u);
    free_after  = golden_free_q.size();

    if (free_after !== free_before) begin
      $fatal(1, "[TB] uses_rd=0 changed freelist size: before=%0d after=%0d", free_before, free_after);
    end

    wb_done(u.rob_idx, u.epoch);
    commit_one();
  endtask

  // -------------------------
  // New: Branch mispredict recovery test
  // -------------------------

  task automatic inject_mispredict(input uop_t br);
    // // Hierarchical poke: adjust instance names if you rename them
    // force dut.rob.rob_mem[br_rob_idx].mispredict = 1'b1;
    // force dut.rob.rob_mem[br_rob_idx].is_branch  = 1'b1;
    // // Mark branch done (WB) to trigger recovery
    // wb_done(br_rob_idx, alloc_epoch);
    // release dut.rob.rob_mem[br_rob_idx].mispredict;
    // release dut.rob.rob_mem[br_rob_idx].is_branch;

    wb_mispredict = 1'b1;
    wb_done(br.rob_idx, br.epoch);
    wb_mispredict = 1'b0;
  endtask

  task automatic consume_recovery_and_update_golden(input logic [ROB_W-1:0] stop_branch_idx);
    int watchdog;
    uop_t expect_tail;

    watchdog = 0;
    while (!recover_valid) begin
      @(posedge clk);
      watchdog++;
      if (watchdog > 200) $fatal(1, "[TB] Timeout waiting for recover_valid");
    end

    $display("=== TEST D: Recovery START (stop at branch rob=%0d) ===", stop_branch_idx);

    // For each recovery pop, we expect to pop the youngest uop from inflight_q
    // until the youngest is the branch itself.
    watchdog = 0;
    while (recover_valid) begin

      if (inflight_q.size() == 0) $fatal(1, "[TB] Recovery but inflight_q empty");
      expect_tail = inflight_q[inflight_q.size()-1];

      // The recovered entry should correspond to youngest ROB entry.
      // If your design exposes recover_cur_rob_idx as tail-1, this should match expect_tail.rob_idx.
      if (recover_cur_rob_idx !== expect_tail.rob_idx) begin
        $fatal(1, "[TB] Recover idx mismatch exp=%0d got=%0d", expect_tail.rob_idx, recover_cur_rob_idx);
      end

      // If the squashed uop had a destination, undo RAT and free pd_new.
      if (recover_entry.uses_rd) begin
        if (!expect_tail.uses_rd) $fatal(1, "[TB] Recover uses_rd mismatch (expected no-rd uop)");
        if (recover_entry.rd_arch !== expect_tail.rd_arch) $fatal(1, "[TB] Recover rd_arch mismatch exp=x%0d got=x%0d", expect_tail.rd_arch, recover_entry.rd_arch);
        if (recover_entry.pd_old  !== expect_tail.pd_old)  $fatal(1, "[TB] Recover pd_old mismatch exp=%0d got=%0d", expect_tail.pd_old, recover_entry.pd_old);
        if (recover_entry.pd_new  !== expect_tail.pd_new)  $fatal(1, "[TB] Recover pd_new mismatch exp=%0d got=%0d", expect_tail.pd_new, recover_entry.pd_new);

        golden_rat[recover_entry.rd_arch] = recover_entry.pd_old;
        push_free(recover_entry.pd_new);
        @(posedge clk);
        #1;
      end

      // Pop the squashed uop from inflight_q
      inflight_q.pop_back();

      watchdog++;
      if (watchdog > (ROB_SIZE + 8)) $fatal(1, "[TB] Recovery stuck too long");

      // Stop condition sanity: we should never squash the branch itself.
      if (recover_valid && recover_cur_rob_idx == stop_branch_idx) $fatal(1, "[TB] Recovery attempted to squash branch entry itself");
    end

    $display("=== TEST D: Recovery END ===");
  endtask

  task automatic test_branch_mispredict_recovery();
    uop_t br, y0, y1, old0;
    logic [PHYS_W-1:0] x3_comm, x4_comm;

    $display("=== TEST D: Branch mispredict squashes younger renames ===");

    // Ensure empty pipeline state
    if (inflight_q.size() != 0) $fatal(1, "[TB] test_branch_mispredict_recovery requires empty inflight_q");

    // Oldest: one renaming op
    alloc_inst(1'b1, 5'd1, 32'h5000, old0);

    // Branch (no dest)
    alloc_inst_branch(32'h5004, br);

    // Committed mapping for x3/x4 in golden at this point
    x3_comm = golden_rat[5'd3];
    x4_comm = golden_rat[5'd4];

    // Younger renames (to be squashed)
    alloc_inst(1'b1, 5'd3, 32'h5008, y0);
    alloc_inst(1'b1, 5'd4, 32'h500C, y1);

    // Mark younger done (not required for recovery, but keeps your done logic consistent)
    wb_done(y0.rob_idx, y0.epoch);
    wb_done(y1.rob_idx, y1.epoch);

    // Trigger mispredict on branch (inject + wb)
    inject_mispredict(br);

    // Consume recovery pops; should pop y1 then y0
    consume_recovery_and_update_golden(br.rob_idx);

    // After recovery, mappings for x3/x4 should revert
    rs1_arch = 5'd3; #1;
    if (rs1_phys !== x3_comm) $fatal(1, "[TB] After recovery x3 mapping wrong exp=%0d got=%0d", x3_comm, rs1_phys);
    rs1_arch = 5'd4; #1;
    if (rs1_phys !== x4_comm) $fatal(1, "[TB] After recovery x4 mapping wrong exp=%0d got=%0d", x4_comm, rs1_phys);

    // Cleanly retire remaining older instructions (old0 + branch)
    wb_done(old0.rob_idx, old0.epoch);
    wb_done(br.rob_idx,  br.epoch);
    commit_one();
    commit_one();

    $display("[TB] TEST D PASS ✅");
  endtask

  // -------------------------
  // Cycle-by-cycle display (kept similar to original)
  // -------------------------
  always @(posedge clk) begin
    if (rst_n & alloc_valid) begin
      $display("[C%0t] alloc_v=%0d rdy=%0d rd=x%0d old=%0d new=%0d | rs1=x%0d->p%0d rs2=x%0d->p%0d | commit_v=%0d | recover_v=%0d",
        $time, alloc_valid, alloc_ready, alloc_rd_arch, rd_phys, rd_new_phys,
        rs1_arch, rs1_phys, rs2_arch, rs2_phys,
        commit_valid,
        recover_valid
      );
    end
    else if (rst_n & commit_valid & commit_ready) begin
      $display("[C%0t] committing instn | rs1=x%0d->p%0d rs2=x%0d->p%0d | commit_v=%0d rd=x%0d old=%0d new=%0d",
        $time,
        rs1_arch, rs1_phys, rs2_arch, rs2_phys,
        commit_valid,
        commit_rd_arch, commit_pd_old, commit_pd_new
      );
    end

    if (rst_n & recover_valid) begin
      if (recover_entry.uses_rd) begin
        $display("[C%0t] RECOVER pop rob=%0d rd=x%0d pd_old=%0d pd_new=%0d br=%0d mispred=%0d pc=%h",
          $time, recover_cur_rob_idx,
          recover_entry.rd_arch,
          recover_entry.pd_old,
          recover_entry.pd_new,
          recover_entry.is_branch,
          recover_entry.mispredict,
          recover_entry.pc
        );
      end else begin
        $display("[C%0t] RECOVER pop rob=%0d rd=-- br=%0d mispred=%0d pc=%h",
          $time, recover_cur_rob_idx,
          recover_entry.is_branch,
          recover_entry.mispredict,
          recover_entry.pc
        );
      end
    end
  end

  // -------------------------
  // Main tests flow
  // -------------------------
  initial begin
    do_reset();

    rs1_arch = 5'd1;
    rs2_arch = 5'd2;
    wb_mispredict = 1'b0;

    // ---- TEST A ----
    $display("=== TEST A: WAW then probe RAW mapping ===");
    alloc_inst(1'b1, 5'd1, 32'h1000, i0);
    alloc_inst(1'b1, 5'd1, 32'h1004, i1);

    @(negedge clk);
    if (rs1_phys !== golden_rat[1]) $fatal(1, "[TB] RAT probe mismatch after WAW: exp p%0d got p%0d", golden_rat[1], rs1_phys);

    wb_done(i1.rob_idx, i1.epoch);
    wb_done(i0.rob_idx, i0.epoch);

    commit_one();
    commit_one();

    $display("=== Alloc more to observe freed reg reuse ===");
    alloc_inst(1'b1, 5'd2, 32'h1010, i2);
    alloc_inst(1'b1, 5'd3, 32'h1014, i3);
    alloc_inst(1'b1, 5'd4, 32'h1018, i4);

    wb_done(i2.rob_idx, i2.epoch);
    wb_done(i3.rob_idx, i3.epoch);
    wb_done(i4.rob_idx, i4.epoch);
    commit_one();
    commit_one();
    commit_one();

    if (expect_reuse_q.size() > 0) target = expect_reuse_q[0];

    seen_reuse = 0;
    loops = 0;
    while (!seen_reuse && loops < 40) begin
      uop_t t;
      alloc_inst(1'b1, 5'd5, 32'h2000 + loops*4, t);
      if (t.pd_new == target) begin
        $display("[TB] Observed freed pd_old p%0d re-allocated as pd_new ✅", target);
        seen_reuse = 1;
      end
      wb_done(t.rob_idx, t.epoch);
      commit_one();
      loops++;
    end

    if (!seen_reuse) begin
      $fatal(1, "[TB] Did not observe freed pd_old p%0d being reused within bound.", target);
    end

    // ---- TEST B ----
    test_rob_full_stall();

    // ---- TEST C ----
    test_no_rd_does_not_allocate();

    // ---- TEST D ----
    test_branch_mispredict_recovery();

    $display("[TB] ALL TESTS PASS ✅");
    $finish;
  end

endmodule
