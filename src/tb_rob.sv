`timescale 1ns/1ps

module tb_rob;

  // -------------------------
  // Parameters (match DUT)
  // -------------------------
  localparam int ROB_SIZE = 16;
  localparam int ROB_W    = $clog2(ROB_SIZE);
  localparam int PHYS_W   = 6;

  // -------------------------
  // Clock / Reset
  // -------------------------
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk; // 100MHz

  // -------------------------
  // DUT I/O
  // -------------------------
  // alloc
  logic               alloc_valid;
  logic               alloc_ready;
  logic               alloc_uses_rd;
  logic [4:0]         alloc_rd_arch;
  logic [PHYS_W-1:0]  alloc_pd_new;
  logic [PHYS_W-1:0]  alloc_pd_old;
  logic               alloc_is_branch, alloc_is_load, alloc_is_store;
  logic [31:0]        alloc_pc;
  logic               alloc_epoch;
  logic [ROB_W-1:0]   alloc_rob_idx;

  // wb
  logic               wb_valid;
  logic [ROB_W-1:0]   wb_rob_idx;
  logic               wb_epoch;

  // commit
  logic               commit_valid;
  logic               commit_ready;
  logic               commit_uses_rd;
  logic [4:0]         commit_rd_arch;
  logic [PHYS_W-1:0]  commit_pd_new;
  logic [PHYS_W-1:0]  commit_pd_old;
  logic               commit_is_branch, commit_is_load, commit_is_store;

  // flush
  logic               flush_valid;
  logic [ROB_W-1:0]   flush_rob_idx;
  logic               flush_epoch;

  // tb local variables
  logic [ROB_W-1:0] i0, i1, i2;
  logic [ROB_W-1:0] j0, j1, j2;
  logic [ROB_W-1:0] k0;
  logic [ROB_W-1:0] m0, m1;

  // -------------------------
  // Instantiate DUT
  // -------------------------
  ROB #(
    .ROB_SIZE(ROB_SIZE),
    .ROB_W(ROB_W),
    .PHYS_W(PHYS_W)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    // alloc signals
    .alloc_valid(alloc_valid),
    .alloc_ready(alloc_ready),
    .alloc_uses_rd(alloc_uses_rd),
    .alloc_rd_arch(alloc_rd_arch),
    .alloc_pd_new(alloc_pd_new),
    .alloc_pd_old(alloc_pd_old),
    .alloc_is_branch(alloc_is_branch),
    .alloc_is_load(alloc_is_load),
    .alloc_is_store(alloc_is_store),
    .alloc_pc(alloc_pc),
    .alloc_epoch(alloc_epoch),
    .alloc_rob_idx(alloc_rob_idx),
    // wb signals
    .wb_valid(wb_valid),
    .wb_rob_idx(wb_rob_idx),
    .wb_epoch(wb_epoch),
    // commit signals
    .commit_valid(commit_valid),
    .commit_ready(commit_ready),
    .commit_uses_rd(commit_uses_rd),
    .commit_rd_arch(commit_rd_arch),
    .commit_pd_new(commit_pd_new),
    .commit_pd_old(commit_pd_old),
    .commit_is_branch(commit_is_branch),
    .commit_is_load(commit_is_load),
    .commit_is_store(commit_is_store),
    // flush signals
    .flush_valid(flush_valid),
    .flush_rob_idx(flush_rob_idx),
    .flush_epoch(flush_epoch)
  );

  // -------------------------
  // Scoreboard entry
  // -------------------------
  typedef struct packed {
    logic              uses_rd;
    logic [4:0]        rd_arch;
    logic [PHYS_W-1:0] pd_new;
    logic [PHYS_W-1:0] pd_old;
    logic              is_branch;
    logic              is_load;
    logic              is_store;
    logic [31:0]       pc;
  } exp_commit_t;

  exp_commit_t exp_q[$];  // queue of expected commits in order

  // -------------------------
  // Helpers / tasks
  // -------------------------
  task automatic init_signals();
    alloc_valid     = 0;
    alloc_uses_rd   = 0;
    alloc_rd_arch   = '0;
    alloc_pd_new    = '0;
    alloc_pd_old    = '0;
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
  endtask

  task automatic do_reset();
    init_signals();
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // Drive one-cycle allocate; capture rob_idx at handshake time.
  task automatic alloc_uop(
    input logic              uses_rd,
    input logic [4:0]        rd_arch,
    input logic [PHYS_W-1:0] pd_new,
    input logic [PHYS_W-1:0] pd_old,
    input logic              is_branch,
    input logic              is_load,
    input logic              is_store,
    input logic [31:0]       pc,
    input logic              epoch,
    output logic [ROB_W-1:0] rob_idx_out
  );
    exp_commit_t e;

    // present inputs
    @(negedge clk);
    alloc_valid     = 1;
    alloc_uses_rd   = uses_rd;
    alloc_rd_arch   = rd_arch;
    alloc_pd_new    = pd_new;
    alloc_pd_old    = pd_old;
    alloc_is_branch = is_branch;
    alloc_is_load   = is_load;
    alloc_is_store  = is_store;
    alloc_pc        = pc;
    alloc_epoch     = epoch;

    // capture index if handshake will fire this cycle
    // (alloc_ready is combinational from count)
    if (!alloc_ready) begin
      $fatal(1, "[TB] alloc_uop called when alloc_ready=0");
    end
    rob_idx_out = alloc_rob_idx;

    // enqueue expected commit (in program order)
    e.uses_rd   = uses_rd;
    e.rd_arch   = rd_arch;
    e.pd_new    = pd_new;
    e.pd_old    = pd_old;
    e.is_branch = is_branch;
    e.is_load   = is_load;
    e.is_store  = is_store;
    e.pc        = pc;
    exp_q.push_back(e);

    // commit the allocation at posedge
    @(negedge clk);
    alloc_valid = 0;
  endtask

  // Drive one-cycle writeback for given idx/epoch
  task automatic wb_done(
    input logic [ROB_W-1:0] idx,
    input logic             epoch
  );
    @(negedge clk);
    wb_valid   = 1;
    wb_rob_idx = idx;
    wb_epoch   = epoch;
    @(negedge clk);
    wb_valid   = 0;
  endtask

  // Wait and consume exactly one commit, checking fields against expected queue head.
  task automatic expect_one_commit();
    exp_commit_t e;
    int watchdog = 0;

    if (exp_q.size() == 0) begin
      $fatal(1, "[TB] expect_one_commit called with empty expected queue");
    end
    e = exp_q[0];

    // wait until DUT asserts commit_valid
    while (!commit_valid) begin
      @(posedge clk);
      watchdog++;
      if (watchdog > 200) $fatal(1, "[TB] Timeout waiting for commit_valid");
    end

    // accept it
    @(negedge clk);
    commit_ready = 1;
    @(negedge clk);
    commit_ready = 0;

    // check outputs sampled in the cycle commit_valid was high.
    // (Your ROB drives commit_* combinationally from head_ptr entry)
    if (commit_uses_rd   !== e.uses_rd)   $fatal(1, "[TB] commit_uses_rd mismatch e.uses_rd=%0d got=%0d at pc=%0h", e.uses_rd, commit_uses_rd, e.pc);
    if (commit_rd_arch   !== e.rd_arch)   $fatal(1, "[TB] commit_rd_arch mismatch e.rd_arch=%0d got=%0d at pc=%0h", e.rd_arch, commit_rd_arch, e.pc);
    if (commit_pd_new    !== e.pd_new)    $fatal(1, "[TB] commit_pd_new mismatch e.pd_new=%0d got=%0d at pc=%0h", e.pd_new, commit_pd_new, e.pc);
    if (commit_pd_old    !== e.pd_old)    $fatal(1, "[TB] commit_pd_old mismatch e.pd_old=%0d got=%0d at pc=%0h", e.pd_old, commit_pd_old, e.pc);
    if (commit_is_branch !== e.is_branch) $fatal(1, "[TB] commit_is_branch mismatch e.is_branch=%0d got=%0d at pc=%0h", e.is_branch, commit_is_branch, e.pc);
    if (commit_is_load   !== e.is_load)   $fatal(1, "[TB] commit_is_load mismatch e.is_load=%0d got=%0d at pc=%0h", e.is_load, commit_is_load, e.pc);
    if (commit_is_store  !== e.is_store)  $fatal(1, "[TB] commit_is_store mismatch e.is_store=%0d got=%0d at pc=%0h", e.is_store, commit_is_store, e.pc);

    exp_q.pop_front();
  endtask

  // Assert flush for one cycle (your ROB does global flush currently)
  task automatic do_flush(input logic new_epoch);
    @(negedge clk);
    flush_valid = 1;
    flush_epoch = new_epoch;
    flush_rob_idx = '0; // ignored by your current flush behavior
    @(negedge clk);
    flush_valid = 0;
  endtask

  // -------------------------
  // Tests
  // -------------------------
  initial begin
    do_reset();

    // =========================
    // TEST 1: basic alloc/wb/commit
    // =========================
    $display("[TB] TEST1: alloc 3, wb in order, commit in order");
    alloc_uop(1, 5'd1, 6'd10, 6'd2, 0,0,0, 32'h1000, 1'b0, i0);
    alloc_uop(1, 5'd2, 6'd11, 6'd3, 0,0,0, 32'h1004, 1'b0, i1);
    alloc_uop(0, 5'd0, 6'd0,  6'd0, 0,0,0, 32'h1008, 1'b0, i2); // no rd
    wb_done(i0, 1'b0);
    wb_done(i1, 1'b0);
    wb_done(i2, 1'b0);
    expect_one_commit();
    expect_one_commit();
    expect_one_commit();
    $display("[TB] TEST1 PASS");

    // =========================
    // TEST 2: out-of-order completion stalls commit
    // =========================
    $display("[TB] TEST2: wb 1/2 first, commit stalls until 0 done");
    alloc_uop(1, 5'd3, 6'd12, 6'd4, 0,0,0, 32'h2000, 1'b0, j0);
    alloc_uop(1, 5'd4, 6'd13, 6'd5, 0,0,0, 32'h2004, 1'b0, j1);
    alloc_uop(1, 5'd5, 6'd14, 6'd6, 0,0,0, 32'h2008, 1'b0, j2);

    wb_done(j1, 1'b0);
    wb_done(j2, 1'b0);

    // ensure commit_valid remains low for a few cycles (since head not done)
    repeat (3) begin
      @(posedge clk);
      if (commit_valid) $fatal(1, "[TB] TEST2 fail: commit_valid asserted before head done");
    end

    wb_done(j0, 1'b0);
    expect_one_commit();
    expect_one_commit();
    expect_one_commit();
    $display("[TB] TEST2 PASS");

    // =========================
    // TEST 3: commit backpressure
    // =========================
    $display("[TB] TEST3: commit_ready=0 stalls retirement");
    alloc_uop(1, 5'd6, 6'd15, 6'd7, 0,0,0, 32'h3000, 1'b0, k0);
    wb_done(k0, 1'b0);

    // stall commit for a while
    commit_ready = 0;
    repeat (5) begin
      @(posedge clk);
      if (!commit_valid) $fatal(1, "[TB] TEST3 fail: expected commit_valid to stay high while stalled");
    end
    commit_ready = 1;
    expect_one_commit();
    $display("[TB] TEST3 PASS");

    // =========================
    // TEST 4: flush clears ROB
    // =========================
    $display("[TB] TEST4: global flush clears and prevents old commits");
    alloc_uop(1, 5'd7, 6'd20, 6'd8, 0,0,0, 32'h4000, 1'b0, m0);
    alloc_uop(1, 5'd8, 6'd21, 6'd9, 0,0,0, 32'h4004, 1'b0, m1);

    // flush and clear expected queue too (since your flush is global)
    do_flush(1'b1);
    exp_q.delete();

    // even if old wb arrives, should not lead to commit (ROB is empty)
    wb_done(m0, 1'b0);
    repeat (5) begin
      @(posedge clk);
      if (commit_valid) $fatal(1, "[TB] TEST4 fail: commit_valid asserted after flush with empty expected");
    end
    $display("[TB] TEST4 PASS");

    $display("[TB] ALL TESTS PASS");
    $finish;
  end

endmodule
