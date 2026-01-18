`timescale 1ns/1ps
`include "defines.svh"

module tb_commit_dispatch_sys_full;

  // Match DUT params
  localparam int ARCH_REGS_L = 32;
  localparam int PHYS_REGS_L = 64;
  localparam int PHYS_W_L    = $clog2(PHYS_REGS_L);
  localparam int ROB_SIZE_L  = 16;
  localparam int ROB_W_L     = $clog2(ROB_SIZE_L);
  localparam int DW_L        = 32;
  localparam int RS_SIZE_L   = 8;

  // Clock/Reset
  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  longint unsigned cycle;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle <= 0;
    else        cycle <= cycle + 1;
  end

  function automatic string xreg(input logic [4:0] r);
    return $sformatf("x%0d", r);
  endfunction

  // -------------------------
  // DUT I/O
  // -------------------------
  logic               alloc_valid;
  logic               alloc_ready;
  logic               alloc_epoch;
  logic [ROB_W_L-1:0] alloc_rob_idx;

  rs_uop_t             decoded_bundle_fields;
  logic                issue_ready;
  logic                issue_valid;
  rs_uop_t             issue_uop;

  logic               wb_valid;
  logic [ROB_W_L-1:0] wb_rob_idx;
  logic               wb_epoch;
  logic               wb_mispredict;
  logic [PHYS_W_L-1:0] wb_pd;
  logic [31:0]        wb_data;

  logic               commit_valid;
  logic               commit_ready;
  logic               commit_uses_rd;
  logic [4:0]         commit_rd_arch;
  logic [PHYS_W_L-1:0] commit_pd_new;
  logic [PHYS_W_L-1:0] commit_pd_old;
  logic               commit_is_branch;
  logic               commit_is_load;
  logic               commit_is_store;

  logic               flush_valid;
  logic [ROB_W_L-1:0] flush_rob_idx;
  logic               flush_epoch;

  logic [4:0]         rs1_arch;
  logic [4:0]         rs2_arch;
  logic [4:0]         alloc_rd_arch;

  wire [PHYS_W_L-1:0] rs1_phys;
  wire [DW_L-1:0]     rs1_data;
  wire                rs1_ready;
  wire [PHYS_W_L-1:0] rs2_phys;
  wire [DW_L-1:0]     rs2_data;
  wire                rs2_ready;
  wire [PHYS_W_L-1:0] rd_phys;
  wire [PHYS_W_L-1:0] rd_new_phys;
  wire [PHYS_W_L-1:0] ready_vec; // note: DUT declares this as [PHYS_W-1:0]

  logic               recover_valid;
  logic [ROB_W_L-1:0] recover_cur_rob_idx;
  rob_entry_t         recover_entry;

  // -------------------------
  // TB-only working variables (kept at module scope)
  // -------------------------
  logic [ROB_W_L-1:0]      r0, r1, rbr, r3, r4, r5;
  logic [PHYS_W_L-1:0]     x1_new, x1_old;
  logic [PHYS_W_L-1:0]     x2_new, x2_old;
  logic [PHYS_W_L-1:0]     x3_new, x3_old;
  logic [PHYS_W_L-1:0]     x4_new, x4_old;
  logic [PHYS_W_L-1:0]     x5_new, x5_old;
  logic [PHYS_W_L-1:0]     x3_comm, x4_comm;
  logic [PHYS_W_L-1:0]     x1_comm, x2_comm;
  logic committed_seen [ROB_SIZE_L];
  rs_uop_t issued_q;
  logic    issued_q_valid;
  logic wb_seen [ROB_SIZE_L];
  int last_commit;
  logic [ROB_W_L-1:0] commit_rob_idx;




// -------------------------
// TEST H: random stress signals
// -------------------------
logic               pending_wb_valid;
logic [ROB_W_L-1:0] pending_wb_rob_idx;
logic               pending_wb_mispredict;
logic [PHYS_W_L-1:0] pending_wb_pd;
logic [31:0]        pending_wb_data;
int unsigned        h_progress_ctr;

  // temps used by stress/backpressure tests
  logic [ROB_W_L-1:0]      ridx_t;
  logic [PHYS_W_L-1:0]     pdn_t, pdo_t;


  // -------------------------
  // DUT instance
  // -------------------------
  commit_dispatch_sys #(
    .ARCH_REGS(ARCH_REGS_L),
    .PHYS_REGS(PHYS_REGS_L),
    .ROB_SIZE(ROB_SIZE_L),
    .ROB_W(ROB_W_L),
    .PHYS_W(PHYS_W_L)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),

    .alloc_valid(alloc_valid),
    .alloc_ready(alloc_ready),
    .alloc_epoch(alloc_epoch),
    .alloc_rob_idx(alloc_rob_idx),

    .decoded_bundle_fields(decoded_bundle_fields),
    .issue_ready(issue_ready),
    .issue_valid(issue_valid),
    .issue_uop(issue_uop),

    .wb_valid(wb_valid),
    .wb_rob_idx(wb_rob_idx),
    .wb_epoch(wb_epoch),
    .wb_mispredict(wb_mispredict),
    .wb_pd(wb_pd),
    .wb_data(wb_data),

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
    .alloc_rd_arch(alloc_rd_arch),

    .rs1_phys(rs1_phys),
    .rs1_data(rs1_data),
    .rs1_ready(rs1_ready),
    .rs2_phys(rs2_phys),
    .rs2_data(rs2_data),
    .rs2_ready(rs2_ready),
    .rd_phys(rd_phys),
    .rd_new_phys(rd_new_phys),
    .ready_vec(ready_vec),

    .recover_valid(recover_valid),
    .recover_cur_rob_idx(recover_cur_rob_idx),
    .recover_entry(recover_entry)
  );

  assign commit_rob_idx = dut.rob.head_ptr;

  // -------------------------
  // Golden model (rename only): RAT + freelist queue
  // -------------------------
  logic [PHYS_W_L-1:0] golden_rat [ARCH_REGS_L];
  logic [PHYS_W_L-1:0] golden_free_q[$];

  function automatic logic [PHYS_W_L-1:0] pop_free();
    logic [PHYS_W_L-1:0] x;
    if (golden_free_q.size() == 0) $fatal(1, "[TB] Golden freelist empty");
    x = golden_free_q[0];
    golden_free_q.pop_front();
    return x;
  endfunction

  task automatic push_free(input logic [PHYS_W_L-1:0] pd);
    golden_free_q.push_back(pd);
  endtask

  task automatic golden_reset();
    int i;
    golden_free_q.delete();
    for (i = 0; i < ARCH_REGS_L; i++) golden_rat[i] = i[PHYS_W_L-1:0];
    for (i = 32; i < PHYS_REGS_L; i++) golden_free_q.push_back(i[PHYS_W_L-1:0]);
  endtask

  // -------------------------
  // Common init/reset
  // -------------------------
  task automatic init_signals();
    alloc_valid = 1'b0;
    alloc_epoch = 1'b0;
    alloc_rd_arch = '0;

    decoded_bundle_fields = '0;
    issue_ready = 1'b1;

    wb_valid = 1'b0;
    wb_rob_idx = '0;
    wb_epoch = 1'b0;
    wb_mispredict = 1'b0;
    wb_pd = '0;
    wb_data = '0;

    commit_ready = 1'b1;

    flush_valid = 1'b0;
    flush_rob_idx = '0;
    flush_epoch = 1'b0;

    rs1_arch = 5'd0;
    rs2_arch = 5'd0;
  endtask

  task automatic do_reset();
    init_signals();
    golden_reset();
    for (int i = 0; i < ROB_SIZE_L; i++) wb_seen[i] = 1'b0;
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
  endtask

  // -------------------------
  // Helpers: drive alloc/decode
  // -------------------------
  task automatic set_decoded_defaults();
    decoded_bundle_fields = '0;
    decoded_bundle_fields.pc = 32'h1000;
    decoded_bundle_fields.uop_class = UOP_ALU;
    decoded_bundle_fields.branch_type = BR_NONE;
    decoded_bundle_fields.mem_size = MSZ_W;
    decoded_bundle_fields.src1_select = SRC_REG;
    decoded_bundle_fields.src2_select = SRC_REG;
    decoded_bundle_fields.uses_rs1 = 1'b0;
    decoded_bundle_fields.uses_rs2 = 1'b0;
    decoded_bundle_fields.uses_rd  = 1'b0;
    decoded_bundle_fields.imm = '0;
    decoded_bundle_fields.pred_taken = 1'b0;
    decoded_bundle_fields.pred_target = '0;
  endtask

  // Allocate one uop into dispatch subsystem.
  // This task intentionally mirrors your existing alloc tasks style.
  task automatic alloc_uop(
    input  logic        uses_rd,
    input  logic [4:0]  rd_arch,
    input  uop_class_e  ucls,
    input  logic [4:0]  rs1a,
    input  logic [4:0]  rs2a,
    input  logic        uses_rs1,
    input  logic        uses_rs2,
    input  logic [31:0] pc,
    output logic [ROB_W_L-1:0] rob_idx_out,
    output logic [PHYS_W_L-1:0] pd_new_out,
    output logic [PHYS_W_L-1:0] pd_old_out
  );
    logic [PHYS_W_L-1:0] exp_old, exp_new;

    exp_old = uses_rd ? golden_rat[rd_arch] : '0;
    exp_new = uses_rd ? pop_free()          : '0;

    // Drive arch read ports for debug outputs
    rs1_arch = rs1a;
    rs2_arch = rs2a;

    // Program the "decoded bundle" (even though it's typed as rs_uop_t)
    set_decoded_defaults();
    decoded_bundle_fields.pc = pc;
    decoded_bundle_fields.uop_class = ucls;
    decoded_bundle_fields.uses_rs1 = uses_rs1;
    decoded_bundle_fields.uses_rs2 = uses_rs2;
    decoded_bundle_fields.uses_rd  = uses_rd;

    // Allocate
    @(negedge clk);
    alloc_valid  = 1'b1;
    alloc_epoch  = 1'b0;
    alloc_rd_arch = rd_arch;

    if (!alloc_ready) $fatal(1, "[TB] alloc_ready=0 at alloc (cycle %0d)", cycle);

    // Sample rename mapping after combinational settle
    #1;
    if (uses_rd) begin
      if (rd_phys !== exp_old) $fatal(1, "[TB] Rename pd_old mismatch: exp=%0d got=%0d (rd=%s pc=%h)", exp_old, rd_phys, xreg(rd_arch), pc);
      if (rd_new_phys !== exp_new) $fatal(1, "[TB] Rename pd_new mismatch: exp=%0d got=%0d (rd=%s pc=%h)", exp_new, rd_new_phys, xreg(rd_arch), pc);
      golden_rat[rd_arch] = exp_new;
      $display("[C%0d] ALLOC rob=%0d rd=%s old=%0d new=%0d | ucls=%0d pc=%h", cycle, alloc_rob_idx, xreg(rd_arch), exp_old, exp_new, ucls, pc);
    end else begin
      $display("[C%0d] ALLOC rob=%0d rd=-- | ucls=%0d pc=%h", cycle, alloc_rob_idx, ucls, pc);
    end

    rob_idx_out = alloc_rob_idx;
    pd_new_out  = exp_new;
    pd_old_out  = exp_old;

    @(negedge clk);
    alloc_valid = 1'b0;
  endtask
  // -------------------------
  // Wrapper helpers for E/F/G (do NOT change base tasks)
  // -------------------------
  task automatic alloc_fast_ready_alu(
    input  logic        uses_rd,
    input  logic [4:0]  rd_arch,
    input  logic [31:0] pc,
    output logic [ROB_W_L-1:0]  rob_idx_out,
    output logic [PHYS_W_L-1:0] pd_new_out,
    output logic [PHYS_W_L-1:0] pd_old_out
  );
    alloc_uop(
      uses_rd,
      rd_arch,
      UOP_ALU,
      5'd0, 5'd0,
      1'b1, 1'b1,
      pc,
      rob_idx_out,
      pd_new_out,
      pd_old_out
    );
  endtask

  task automatic alloc_branch_nord(
    input  logic [31:0] pc,
    output logic [ROB_W_L-1:0] rob_idx_out
  );
    logic [PHYS_W_L-1:0] dummy_new, dummy_old;
    alloc_uop(
      1'b0,
      5'd0,
      UOP_BRANCH,
      5'd0, 5'd0,
      1'b1, 1'b1,
      pc,
      rob_idx_out,
      dummy_new,
      dummy_old
    );
  endtask


  task automatic wb_mark_done(
    input logic [ROB_W_L-1:0] ridx,
    input logic mispred,
    input logic [PHYS_W_L-1:0] pd,
    input logic [31:0] data
  );
    @(negedge clk);
    wb_valid      = 1'b1;
    wb_rob_idx    = ridx;
    wb_epoch      = 1'b0;
    wb_mispredict = mispred;
    wb_pd         = pd;
    wb_data       = data;
    @(negedge clk);
    wb_valid      = 1'b0;
    wb_mispredict = 1'b0;
  endtask

  task automatic check_map(input logic [4:0] arch, input logic [PHYS_W_L-1:0] exp);
    rs1_arch = arch;
    #1;
    if (rs1_phys !== exp)
      $fatal(1, "[TB] RAT map mismatch %s exp p%0d got p%0d", xreg(arch), exp, rs1_phys);
  endtask

  // Wait for an issue and check fields
  task automatic expect_issue(
    input logic [PHYS_W_L-1:0] exp_prs1,
    input logic exp_rdy1,
    input logic [PHYS_W_L-1:0] exp_prs2,
    input logic exp_rdy2,
    input logic [PHYS_W_L-1:0] exp_prd,
    input uop_class_e exp_ucls
  );
    int guard = 0;
    while (!issue_valid) begin
      @(posedge clk);
      guard++;
      if (guard > 50) $fatal(1, "[TB] issue_valid did not assert");
    end
    #1;
    if (issue_uop.prs1 !== exp_prs1) $fatal(1, "[TB] issue prs1 mismatch exp=%0d got=%0d", exp_prs1, issue_uop.prs1);
    if (issue_uop.rdy1 !== exp_rdy1) $fatal(1, "[TB] issue rdy1 mismatch exp=%0d got=%0d", exp_rdy1, issue_uop.rdy1);
    if (issue_uop.prs2 !== exp_prs2) $fatal(1, "[TB] issue prs2 mismatch exp=%0d got=%0d", exp_prs2, issue_uop.prs2);
    if (issue_uop.rdy2 !== exp_rdy2) $fatal(1, "[TB] issue rdy2 mismatch exp=%0d got=%0d", exp_rdy2, issue_uop.rdy2);
    if (issue_uop.prd_new !== exp_prd) $fatal(1, "[TB] issue prd_new mismatch exp=%0d got=%0d", exp_prd, issue_uop.prd_new);
    if (issue_uop.uop_class !== exp_ucls) $fatal(1, "[TB] issue uop_class mismatch exp=%0d got=%0d", exp_ucls, issue_uop.uop_class);

    $display("[C%0d] ISSUE rob=%0d prs1=%0d r1=%0d prs2=%0d r2=%0d prd=%0d ucls=%0d pc=%h",
             cycle, issue_uop.rob_idx, issue_uop.prs1, issue_uop.rdy1, issue_uop.prs2, issue_uop.rdy2,
             issue_uop.prd_new, issue_uop.uop_class, issue_uop.pc);
  endtask

  // Recovery consumer: updates golden mapping and frees pd_new.
  task automatic consume_recovery_all();
    int guard = 0;
    while (!recover_valid) begin
      @(posedge clk);
      guard++;
      if (guard > 50) $fatal(1, "[TB] recover_valid did not assert");
    end
    $display("=== RECOVERY START at C%0d ===", cycle);

    guard = 0;
    while (recover_valid) begin
      if (recover_entry.uses_rd) begin
        $display("[C%0d] RECOVER pop rob=%0d rd=%s pd_old=%0d pd_new=%0d pc=%h",
                 cycle, recover_cur_rob_idx, xreg(recover_entry.rd_arch), recover_entry.pd_old, recover_entry.pd_new, recover_entry.pc);
        golden_rat[recover_entry.rd_arch] = recover_entry.pd_old;
        push_free(recover_entry.pd_new);
      end else begin
        $display("[C%0d] RECOVER pop rob=%0d rd=-- pc=%h", cycle, recover_cur_rob_idx, recover_entry.pc);
      end
      @(posedge clk);
      #1ps;
      guard++;
      if (guard > ROB_SIZE_L + 8) $fatal(1, "[TB] recovery stuck too long");
    end

    $display("=== RECOVERY END at C%0d ===", cycle);
  endtask

  // -------------------------
  // Logging: commits (optional)
  // -------------------------
  always_ff @(posedge clk) begin
    if (rst_n && commit_valid && commit_ready) begin
      if (commit_uses_rd) begin
        $display("[C%0d] COMMIT rd=%s pd_old=%0d pd_new=%0d br=%0d ld=%0d st=%0d",
                 cycle, xreg(commit_rd_arch), commit_pd_old, commit_pd_new,
                 commit_is_branch, commit_is_load, commit_is_store);
      end else begin
        $display("[C%0d] COMMIT rd=-- br=%0d ld=%0d st=%0d",
                 cycle, commit_is_branch, commit_is_load, commit_is_store);
      end
    end
  end


//   always_ff @(posedge clk) begin
//     if (rst_n && wb_valid) begin
//       if (wb_seen[wb_rob_idx]) begin
//         $fatal(1, "[TB] WB duplicated for same rob=%0d at C%0d", wb_rob_idx, cycle);
//       end
//       wb_seen[wb_rob_idx] <= 1'b1;
//     end
//     if (rst_n && recover_valid) begin
//       // optional: if you squash entries, you may allow WB_seen to be ignored/reset
//       // But if you want strict checking: any WB after squash should be blocked by epoch check.
//     end
//   end

logic [ROB_W_L-1:0] last_committed;

initial last_committed = '1;

always @(posedge clk, negedge rst_n) begin
  #1ps;
  if (!rst_n) begin
    last_committed = '1;
  end else if (commit_valid && commit_ready) begin
    if (last_committed != '1) begin
      if (((last_committed + 1) % ROB_SIZE_L) != dut.rob.head_ptr) begin
        $fatal("ROB commit order violated: last=%0d now=%0d",
               last_committed, dut.rob.head_ptr);
      end else begin
        $display("ROB commit order OK: last=%0d now=%0d",
                last_committed, dut.rob.head_ptr);
      end
    end
    last_committed = dut.rob.head_ptr;
  end
end


// -------------------------
// TEST H helpers (do not modify existing tasks)
// -------------------------

// Best-effort allocate: skip if alloc_ready is low.
task automatic try_alloc_random_uop(input int unsigned seed_in);
  int unsigned s;
  logic uses_rd, uses_rs1, uses_rs2;
  logic [4:0] rd_a, rs1_a, rs2_a;
  uop_class_e ucls;
  logic [31:0] pc;
  logic [ROB_W_L-1:0] ridx;
  logic [PHYS_W_L-1:0] pdn, pdo;

  s = seed_in;

  if (!alloc_ready) begin
    return;
  end

  // Mostly ALU, some BRANCH
  ucls = (($urandom(s) % 10) == 0) ? UOP_BRANCH : UOP_ALU;

  uses_rs1 = (($urandom(s+1) % 100) < 85);
  uses_rs2 = (($urandom(s+2) % 100) < 65);

  rs1_a = $urandom(s+3) % 32;
  rs2_a = $urandom(s+4) % 32;

  uses_rd = (ucls != UOP_BRANCH) && (($urandom(s+5) % 100) < 95);
  rd_a    = uses_rd ? (1 + ($urandom(s+6) % 31)) : 5'd0;

  pc = 32'h8000_0000 + (cycle << 2);

  alloc_uop(
    uses_rd,
    rd_a,
    ucls,
    rs1_a,
    rs2_a,
    uses_rs1,
    uses_rs2,
    pc,
    ridx,
    pdn,
    pdo
  );
endtask

task automatic drain_recovery_if_any();
  if (recover_valid) begin
    consume_recovery_all();
  end
endtask



  // -------------------------
  // Main flow
  // -------------------------
    initial begin

    do_reset();

    // -------------------------------------------------
    // TEST A: Basic rename + immediate issue (ready src)
    //   uop: x1 <- (uses x0)
    // -------------------------------------------------
    $display("=== TEST A: rename + immediate issue ===");
    alloc_uop(1'b1, 5'd1, UOP_ALU, 5'd0, 5'd0, 1'b1, 1'b0, 32'h1000, r0, x1_new, x1_old);

    // Expect RS sees prs1 = p0, ready=1; prs2 unused but should be something stable
    expect_issue(/*prs1*/5'd0, /*rdy1*/1'b1, /*prs2*/'0, /*rdy2*/1'b1, /*prd*/x1_new, UOP_ALU);

    // Mark done + writeback PRF for x1_new
    wb_mark_done(r0, 1'b0, x1_new, 32'hAAAA_0001);

    // -------------------------------------------------
    // TEST B: PRF ready clears on rename alloc, sets on WB
    //   uop: x2 <- (uses x1) ; should not issue until wb to x1_new
    // -------------------------------------------------
    $display("=== TEST B: PRF/RS dependency wakeup ===");
    alloc_uop(1'b1, 5'd1, UOP_ALU, 5'd0, 5'd0, 1'b1, 1'b0, 32'h1000, r0, x1_new, x1_old);
    alloc_uop(1'b1, 5'd2, UOP_ALU, 5'd1, 5'd0, 1'b1, 1'b0, 32'h1010, r1, x2_new, x2_old);

    // x1 is currently mapped to x1_new (spec mapping). Operand should be NOT ready until wb hits x1_new.
    // Depending on your dispatch_sys wiring, issue_valid should not assert yet.
    repeat (5) @(posedge clk);
    if (issue_valid) $fatal(1, "[TB] issue_valid asserted unexpectedly before wakeup");

    // Now wakeup x1_new again (idempotent)
    wb_mark_done(r0, 1'b0, x1_new, 32'hAAAA_0001);
    // Now x2 can issue
    expect_issue(/*prs1*/x1_new, /*rdy1*/1'b1, /*prs2*/'0, /*rdy2*/1'b1, /*prd*/x2_new, UOP_ALU);
    wb_mark_done(r1, 1'b0, x2_new, 32'hAAAA_0002);

    // -------------------------------------------------
    // TEST C: WAW rename correctness
    //   x1 <- ... then x1 <- ... ; old/new mapping check via rd_phys/rd_new_phys
    // -------------------------------------------------
    $display("=== TEST C: WAW rename mapping ===");
    alloc_uop(1'b1, 5'd1, UOP_ALU, 5'd0, 5'd0, 1'b0, 1'b0, 32'h1020, r0, x1_new, x1_old);
    alloc_uop(1'b1, 5'd1, UOP_ALU, 5'd0, 5'd0, 1'b0, 1'b0, 32'h1030, r1, x2_new, x2_old);
    // After second rename to x1, RAT[x1] should be x2_new
    check_map(5'd1, x2_new);

    // -------------------------------------------------
    // TEST D: Branch mispredict recovery
    //   older renames: x1, x2
    //   branch
    //   younger renames: x3, x4 (must be undone)
    // -------------------------------------------------
    $display("=== TEST D: branch mispredict recovery ===");

    // Reset golden + DUT to keep recovery test clean
    do_reset();

    // older renames
    alloc_uop(1'b1, 5'd1, UOP_ALU, 5'd0, 5'd0, 1'b0, 1'b0, 32'h2000, r0, x1_new, x1_old);
    alloc_uop(1'b1, 5'd2, UOP_ALU, 5'd0, 5'd0, 1'b0, 1'b0, 32'h2010, r1, x2_new, x2_old);

    // branch (no rd)
    alloc_uop(1'b0, 5'd0, UOP_BRANCH, 5'd0, 5'd0, 1'b0, 1'b0, 32'h2020, rbr, x3_new, x3_old);

    // save committed mapping for x3/x4 (still identity right after reset)
    x3_comm = golden_rat[5'd3];
    x4_comm = golden_rat[5'd4];

    // younger renames (to be undone)
    alloc_uop(1'b1, 5'd3, UOP_ALU, 5'd0, 5'd0, 1'b0, 1'b0, 32'h2030, r3, x3_new, x3_old);
    alloc_uop(1'b1, 5'd4, UOP_ALU, 5'd0, 5'd0, 1'b0, 1'b0, 32'h2040, r4, x4_new, x4_old);

    // mark all done so ROB sees branch WB
    wb_mark_done(r0, 1'b0, x1_new, 32'hBEEF_0001);
    wb_mark_done(r1, 1'b0, x2_new, 32'hBEEF_0002);
    wb_mark_done(r3, 1'b0, x3_new, 32'hBEEF_0003);
    wb_mark_done(r4, 1'b0, x4_new, 32'hBEEF_0004);

    // trigger mispredict on branch WB (no pd writeback necessary)
    wb_mark_done(rbr, 1'b1, '0, 32'h0);

    // consume recovery stream and update golden
    consume_recovery_all();

    // Check that x3/x4 reverted
    check_map(5'd3, x3_comm);
    check_map(5'd4, x4_comm);

    // x1/x2 remain renamed
    check_map(5'd1, x1_new);
    check_map(5'd2, x2_new);

    

    // ==========================
    // TEST E: RS full backpressure (isolate RS)
    // ==========================
    $display("=== TEST E: RS full backpressure (isolate RS) ===");
    do_reset();

    issue_ready  = 1'b0;  // block issue so RS fills
    commit_ready = 1'b1;

    for (int i = 0; i < RS_SIZE_L; i++) begin
      alloc_fast_ready_alu(
        1'b1,
        5'(i % 31 + 1),
        32'h3000 + i,
        ridx_t, pdn_t, pdo_t
      );
    end

    @(posedge clk);
    #1;
    if (alloc_ready)
      $fatal(1, "[TEST E] alloc_ready should be 0 when RS is full");

    if (dut.disp_ready)
      $fatal(1, "[TEST E] dut.disp_ready should be 0 when RS is full");

    // Let RS drain and confirm alloc_ready returns
    issue_ready = 1'b1;
    repeat (2) @(posedge clk);

    if (!alloc_ready)
      $fatal(1, "[TEST E] alloc_ready did not reassert after RS started draining");

    $display("[TEST E] PASS ✅");

    // ==========================
    // TEST F: ROB-only full backpressure (isolate ROB)
    // ==========================
    $display("=== TEST F: ROB-only full backpressure (isolate ROB) ===");
    do_reset();

    commit_ready = 1'b0;  // prevent ROB from draining
    issue_ready  = 1'b1;  // keep RS draining

    for (int i = 0; i < ROB_SIZE_L; i++) begin
      alloc_fast_ready_alu(
        1'b1,
        5'(i % 31 + 1),
        32'h4000 + i,
        ridx_t, pdn_t, pdo_t
      );
      // Complete immediately (ROB done + PRF ready)
      wb_mark_done(ridx_t, 1'b0, pdn_t, 32'hF00D_0000 + i);
    end

    @(posedge clk);
    if (alloc_ready)
      $fatal(1, "[TEST F] alloc_ready should be 0 when ROB is full");

    // Ensure RS isn't the reason (should have space because it drained)
    if (!dut.disp_ready)
      $fatal(1, "[TEST F] dut.disp_ready=0 too; RS might be full, test not isolated");

    // Now allow commit and verify alloc_ready returns
    commit_ready = 1'b1;
    repeat (ROB_SIZE_L/2 + 4) @(posedge clk);

    if (!alloc_ready)
      $fatal(1, "[TEST F] alloc_ready did not reassert after enabling commit");

    $display("[TEST F] PASS ✅");

    // ==========================
    // TEST G: Recovery under load (approx real workload)
    // ==========================
    $display("=== TEST G: Recovery under load ===");
    do_reset();

    issue_ready  = 1'b1;
    commit_ready = 1'b1;

    // Older renames
    alloc_fast_ready_alu(1'b1, 5'd1, 32'h5000, r0, x1_new, x1_old);
    alloc_fast_ready_alu(1'b1, 5'd2, 32'h5010, r1, x2_new, x2_old);

    // Branch (no rd)
    alloc_branch_nord(32'h5020, rbr);

    // Save committed mappings for x3/x4 before younger renames
    x3_comm = golden_rat[5'd3];
    x4_comm = golden_rat[5'd4];

    // Younger renames
    alloc_fast_ready_alu(1'b1, 5'd3, 32'h5030, r3, x3_new, x3_old);
    alloc_fast_ready_alu(1'b1, 5'd4, 32'h5040, r4, x4_new, x4_old);
    alloc_fast_ready_alu(1'b1, 5'd5, 32'h5050, r5, x5_new, x5_old);

    // Mark done for all non-branch uops
    wb_mark_done(r0, 1'b0, x1_new, 32'hAAAA_0001);
    wb_mark_done(r1, 1'b0, x2_new, 32'hAAAA_0002);
    wb_mark_done(r3, 1'b0, x3_new, 32'hAAAA_0003);
    wb_mark_done(r4, 1'b0, x4_new, 32'hAAAA_0004);
    wb_mark_done(r5, 1'b0, x5_new, 32'hAAAA_0005);

    // Trigger mispredict on branch WB
    wb_mark_done(rbr, 1'b1, '0, 32'h0);

    // Consume recovery stream and update golden model
    consume_recovery_all();

    // Younger x3/x4 should revert
    check_map(5'd3, x3_comm);
    check_map(5'd4, x4_comm);

    // Older x1/x2 should remain renamed
    check_map(5'd1, x1_new);
    check_map(5'd2, x2_new);

    @(posedge clk);
    if (!alloc_ready)
      $fatal(1, "[TEST G] alloc_ready did not reassert after recovery");

    $display("[TEST G] PASS ✅");


    // // ==========================
    // // TEST H: Correct random stress (single outstanding WB)
    // // ==========================
    // $display("=== TEST H: Random stress (CORRECT) ===");
    // do_reset();

    // // --------------------------
    // // Local tracking
    // // --------------------------

    // h_progress_ctr        = 0;

    // // Commit order checker
    // last_commit = -1;

    // for (int t = 0; t < 1000; t++) begin
    //     // --------------------------
    //     // Random backpressure
    //     // --------------------------
        
    //     // --------------------------
    //     // Observe ISSUE (only if no WB pending!)
    //     // --------------------------
    //     @(negedge clk);
    //     issue_ready  = (($urandom(t)     % 100) < 85);
    //     commit_ready = (($urandom(t + 7) % 100) < 90);
    //     pending_wb_mispredict =
    //     (cap_issue_uop.uop_class == UOP_BRANCH) &&
    //     (($urandom(t + 99) % 8) == 0);

    //     // --------------------------
    //     // Drain recovery fully
    //     // --------------------------
    //     drain_recovery_if_any();

    //     // --------------------------
    //     // Random allocation attempts
    //     // --------------------------
    //     if (($urandom(t + 123) % 100) < 60) begin
    //         try_alloc_random_uop(t + 999);
    //         h_progress_ctr = 0;
    //     end else begin
    //         h_progress_ctr++;
    //     end

    //     // --------------------------
    //     // RAT spot-check
    //     // --------------------------
    //     if ((t % 50) == 0) begin
    //         logic [4:0] a;
    //         a = $urandom(t + 555) % 32;
    //         check_map(a, golden_rat[a]);
    //     end

    //     // --------------------------
    //     // Deadlock watchdog
    //     // --------------------------
    //     if (h_progress_ctr > 200)
    //         $fatal(1,
    //         "[TEST H] Deadlock detected at cycle %0d",
    //         cycle);
    //     @(negedge clk);
    // end

    // // Final drain
    // if (pending_wb_valid) begin
    //     wb_mark_done(
    //         pending_wb_rob_idx,
    //         pending_wb_mispredict,
    //         pending_wb_pd,
    //         pending_wb_data
    //     );
    // end

    // drain_recovery_if_any();

    // $display("[TEST H] PASS ✅");



    $display("[TB] ALL dispatch subsystem tests PASS ✅");
    $finish;
  end

endmodule
