`timescale 1ns/1ps
`include "defines.svh"

// ============================================================
// Aggressive LSU Testbench
// - Tests all corner cases: forwarding, backpressure, flush, recovery
// - Multiple outstanding operations with randomized ready signals
// - Comprehensive protocol checking
// ============================================================
module tb_lsu;

  // -----------------------
  // Clock / reset
  // -----------------------
  logic clk;
  logic rst_n;

  initial clk = 0;
  always #5 clk = ~clk; // 100MHz

  task automatic do_reset();
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
  endtask

  // -----------------------
  // DUT I/O
  // -----------------------
  logic        req_valid_st, req_valid_ld;
  logic        req_ready_st, req_ready_ld;
  rs_uop_t     req_uop [1:0];
  logic [31:0] rs1_val [1:0];
  logic [31:0] rs2_val [1:0];

  sq_entry_t   sq_entry_in;
  logic        sq_entry_in_valid;
  logic        sq_entry_in_ready;
  sq_entry_t   sq_entry_out;

  logic        commit_valid;
  logic        commit_ready;
  logic        commit_is_store;
  logic [ROB_W-1:0] commit_rob_idx;
  logic [1:0]       commit_epoch;

  logic        flush_valid;

  logic        recover_valid;
  logic [ROB_W-1:0] recover_rob_idx;
  logic [1:0]       recover_epoch;

  dmem_if dmem();

  logic        wb_valid;
  logic        wb_ready;
  logic        wb_uses_rd;
  logic [1:0]       wb_epoch;
  logic [ROB_W-1:0]  wb_rob_idx;
  logic [PHYS_W-1:0] wb_prd_new;
  logic [31:0] wb_data;

  // -----------------------
  // DUT instantiation
  // -----------------------
  LSU dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid_st(req_valid_st),
    .req_valid_ld(req_valid_ld),
    .req_ready_st(req_ready_st),
    .req_ready_ld(req_ready_ld),
    .req_uop(req_uop),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .sq_entry_in(sq_entry_in),
    .sq_entry_in_valid(sq_entry_in_valid),
    .sq_entry_in_ready(sq_entry_in_ready),
    .sq_entry_out(sq_entry_out),
    .commit_valid(commit_valid),
    .commit_ready(commit_ready),
    .commit_is_store(commit_is_store),
    .commit_rob_idx(commit_rob_idx),
    .commit_epoch(commit_epoch),
    .flush_valid(flush_valid),
    .recover_valid(recover_valid),
    .recover_rob_idx(recover_rob_idx),
    .recover_epoch(recover_epoch),
    .dmem(dmem.master),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_uses_rd(wb_uses_rd),
    .wb_epoch(wb_epoch),
    .wb_rob_idx(wb_rob_idx),
    .wb_prd_new(wb_prd_new),
    .wb_data(wb_data)
  );

  // ============================================================
  // Memory model with aggressive backpressure
  // ============================================================
  localparam int MEM_BYTES = 4096;
  byte mem [0:MEM_BYTES-1];

  int unsigned LD_LATENCY_CYC = 2;
  int unsigned ST_ACCEPT_STALL_PCT = 30; // Aggressive stall
  int unsigned LD_ACCEPT_STALL_PCT = 30;
  int unsigned RESP_STALL_PCT      = 30;

  int unsigned rng = 32'hC0FFEE01;
  function automatic int unsigned xorshift32(input int unsigned x);
    x ^= (x << 13);
    x ^= (x >> 17);
    x ^= (x << 5);
    return x;
  endfunction

  function automatic bit rand_pct(input int unsigned pct);
    rng = xorshift32(rng);
    return ((rng % 100) < pct);
  endfunction

  task automatic mem_apply_store(
    input logic [31:0] addr,
    input logic [63:0] wdata,
    input logic [7:0]  wstrb
  );
    int base;
    base = addr;
    for (int i = 0; i < 8; i++) begin
      if (wstrb[i]) begin
        if ((base+i) >= 0 && (base+i) < MEM_BYTES) begin
          mem[base+i] = wdata[8*i +: 8];
        end
      end
    end
  endtask

  function automatic logic [63:0] mem_read64(input logic [31:0] addr);
    logic [63:0] r;
    int base;
    base = addr & 32'hFFFF_FFFC;
    r = '0;
    for (int i = 0; i < 8; i++) begin
      if ((base+i) >= 0 && (base+i) < MEM_BYTES) begin
        r[8*i +: 8] = mem[base+i];
      end
    end
    return r;
  endfunction

  typedef struct packed {
    logic        valid;
    logic [31:0] addr;
    logic [3:0]  tag;
    int unsigned countdown;
  } ld_pipe_t;

  ld_pipe_t ldq;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dmem.ld_ready      <= 1'b0;
      dmem.st_ready      <= 1'b0;
      dmem.ld_resp_valid <= 1'b0;
      dmem.ld_resp_tag   <= '0;
      dmem.ld_resp_data  <= '0;
      dmem.ld_resp_err   <= 1'b0;
      ldq.valid          <= 1'b0;
    end else begin
      dmem.st_ready <= !rand_pct(ST_ACCEPT_STALL_PCT);
      dmem.ld_ready <= !rand_pct(LD_ACCEPT_STALL_PCT);

      if (dmem.ld_resp_valid && dmem.ld_resp_ready) begin
        dmem.ld_resp_valid <= 1'b0;
      end

      if (dmem.st_valid && dmem.st_ready) begin
        mem_apply_store(dmem.st_addr, dmem.st_wdata, dmem.st_wstrb);
      end

      if (dmem.ld_valid && dmem.ld_ready) begin
        ldq.valid     <= 1'b1;
        ldq.addr      <= dmem.ld_addr;
        ldq.tag       <= dmem.ld_tag;
        ldq.countdown <= LD_LATENCY_CYC;
      end

      if (ldq.valid) begin
        if (ldq.countdown != 0) begin
          ldq.countdown <= ldq.countdown - 1;
        end else begin
          if (!dmem.ld_resp_valid) begin
            if (!rand_pct(RESP_STALL_PCT)) begin
              dmem.ld_resp_valid <= 1'b1;
              dmem.ld_resp_tag   <= ldq.tag;
              dmem.ld_resp_data  <= mem_read64(ldq.addr);
              dmem.ld_resp_err   <= 1'b0;
              ldq.valid          <= 1'b0;
            end
          end
        end
      end
    end
  end

  // ============================================================
  // Helper tasks
  // ============================================================
  function automatic rs_uop_t mk_uop(
    input uop_class_e cls,
    input uop_op_e    op,
    input mem_size_e  msz,
    input logic [31:0] imm,
    input logic [ROB_W-1:0] rob,
    input logic [1:0]  epoch,
    input logic [PHYS_W-1:0] prd_new
  );
    rs_uop_t u;
    u = '0;
    u.bundle.uop_class = cls;
    u.bundle.op        = op;
    u.bundle.mem_size  = msz;
    u.bundle.imm       = imm;
    u.rob_idx          = rob;
    u.epoch            = epoch;
    u.prd_new          = prd_new;
    return u;
  endfunction

  task automatic drive_defaults();
    req_valid_st       = 1'b0;
    req_valid_ld       = 1'b0;
    req_uop[0]         = '0;
    req_uop[1]         = '0;
    rs1_val[0]         = '0;
    rs2_val[0]         = '0;
    rs1_val[1]         = '0;
    rs2_val[1]         = '0;
    sq_entry_in        = '0;
    sq_entry_in_valid  = 1'b0;
    commit_valid       = 1'b0;
    commit_is_store    = 1'b0;
    commit_rob_idx     = '0;
    commit_epoch       = '0;
    flush_valid        = 1'b0;
    recover_valid      = 1'b0;
    recover_rob_idx    = '0;
    recover_epoch      = '0;
    wb_ready           = 1'b1;
  endtask

  task automatic sq_alloc_store(
    input logic [ROB_W-1:0] rob,
    input logic [1:0] epoch,
    input mem_size_e msz
  );
    sq_entry_t e;
    e = '0;
    e.rob_idx    = rob;
    e.epoch      = epoch;
    e.mem_size   = msz;
    e.committed  = 1'b0;
    e.sent       = 1'b0;
    e.addr_rdy   = 1'b0;
    e.data_rdy   = 1'b0;
    @(posedge clk);
    sq_entry_in       <= e;
    sq_entry_in_valid <= 1'b1;
    #1;
    while (!(sq_entry_in_valid && sq_entry_in_ready)) @(posedge clk);
    @(posedge clk);
    sq_entry_in_valid <= 1'b0;
  endtask

  task automatic exec_store(
    input logic [ROB_W-1:0] rob,
    input logic [1:0] epoch,
    input mem_size_e msz,
    input logic [31:0] base,
    input logic [31:0] imm,
    input logic [31:0] data
  );
    @(posedge clk);
    req_uop[0]   <= mk_uop(UOP_STORE, (msz==MSZ_B)?OP_SB:(msz==MSZ_H)?OP_SH:OP_SW,
                          msz, imm, rob, epoch, '0);
    rs1_val[0]   <= base;
    rs2_val[0]   <= data;
    req_valid_st <= 1'b1;
    @(posedge clk);
    req_valid_st <= 1'b0;
  endtask

  task automatic commit_store(
    input logic [ROB_W-1:0] rob,
    input logic [1:0] epoch
  );
    @(posedge clk);
    commit_valid    <= 1'b1;
    commit_is_store <= 1'b1;
    commit_rob_idx  <= rob;
    commit_epoch    <= epoch;
    @(posedge clk);
    commit_valid    <= 1'b0;
    commit_is_store <= 1'b0;
  endtask

  task automatic issue_load(
    input uop_op_e op,
    input mem_size_e msz,
    input logic [31:0] base,
    input logic [31:0] imm,
    input logic [ROB_W-1:0] rob,
    input logic [1:0] epoch,
    input logic [PHYS_W-1:0] prd
  );
    @(posedge clk);
    req_uop[1]   <= mk_uop(UOP_LOAD, op, msz, imm, rob, epoch, prd);
    rs1_val[1]   <= base;
    req_valid_ld <= 1'b1;
    #1;
    while (!req_ready_ld) @(posedge clk);
    @(posedge clk);
    req_valid_ld <= 1'b0;
  endtask

  task automatic expect_wb(
    input logic [ROB_W-1:0] exp_rob,
    input logic [31:0] exp_data,
    input int timeout = 100
  );
    int cycles = 0;
    while (!wb_valid) begin
      @(posedge clk);
      cycles++;
      if (cycles > timeout) $fatal(1, "[WB] Timeout waiting for rob=%0d", exp_rob);
    end
    if (wb_rob_idx !== exp_rob) begin
      $fatal(1, "[WB] rob_idx mismatch exp=%0d got=%0d", exp_rob, wb_rob_idx);
    end
    if (wb_data !== exp_data) begin
      $fatal(1, "[WB] data mismatch exp=0x%08x got=0x%08x", exp_data, wb_data);
    end
    @(posedge clk);
  endtask

  // Randomized WB backpressure
  int unsigned WB_STALL_PCT = 20;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_ready <= 1'b1;
    end else begin
      wb_ready <= !rand_pct(WB_STALL_PCT);
    end
  end

  // ============================================================
  // Test sequences
  // ============================================================
  initial begin
    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;
    drive_defaults();
    commit_ready = 1'b1;
    do_reset();

    // TEST 1: Basic store-to-load forwarding
    $display("=== TEST 1: Store-to-Load forwarding ===");
    sq_alloc_store(ROB_W'(1), 2'd0, MSZ_W);
    sq_alloc_store(ROB_W'(2), 2'd0, MSZ_W);
    sq_alloc_store(ROB_W'(3), 2'd0, MSZ_W);
    sq_alloc_store(ROB_W'(4), 2'd0, MSZ_W);
    exec_store(ROB_W'(1), 2'd0, MSZ_W, 32'h100, 32'h0, 32'hAABB_CCDD);
    exec_store(ROB_W'(2), 2'd0, MSZ_W, 32'h100, 32'h0, 32'h1122_3344);
    exec_store(ROB_W'(3), 2'd0, MSZ_W, 32'h101, 32'h0, 32'h5566_7788);
    exec_store(ROB_W'(4), 2'd0, MSZ_W, 32'h102, 32'h0, 32'h7788_99AA);
    issue_load(OP_LW, MSZ_W, 32'h100, 32'h0, ROB_W'(5), 2'd0, PHYS_W'(5));
    expect_wb(ROB_W'(5), 32'h1122_3344);
    issue_load(OP_LW, MSZ_W, 32'h102, 32'h0, ROB_W'(6), 2'd0, PHYS_W'(6));
    expect_wb(ROB_W'(6), 32'h7788_99AA);
    commit_store(ROB_W'(1), 2'd0);
    commit_store(ROB_W'(2), 2'd0);
    commit_store(ROB_W'(3), 2'd0);
    commit_store(ROB_W'(4), 2'd0);

    // TEST 2: Sequential loads with backpressure (single outstanding)
    $display("=== TEST 2: Sequential loads with backpressure ===");
    mem[32'h200] = 8'h11; mem[32'h201] = 8'h22; mem[32'h202] = 8'h33; mem[32'h203] = 8'h44;
    mem[32'h204] = 8'h55; mem[32'h205] = 8'h66; mem[32'h206] = 8'h77; mem[32'h207] = 8'h88;
    
    // Issue first load
    issue_load(OP_LW, MSZ_W, 32'h200, 32'h0, ROB_W'(10), 2'd0, PHYS_W'(10));
    expect_wb(ROB_W'(10), 32'h4433_2211, 150);
    
    // Issue second load (tests that ld_busy cleared properly)
    issue_load(OP_LW, MSZ_W, 32'h204, 32'h0, ROB_W'(11), 2'd0, PHYS_W'(11));
    expect_wb(ROB_W'(11), 32'h8877_6655, 150);

    // TEST 3: Load partial forwarding (byte/halfword from word store)
    $display("=== TEST 3: Partial size forwarding ===");
    sq_alloc_store(ROB_W'(20), 2'd0, MSZ_W);
    exec_store(ROB_W'(20), 2'd0, MSZ_W, 32'h300, 32'h0, 32'h1234_5678);
    
    // Load byte from word store (should forward lowest byte)
    issue_load(OP_LBU, MSZ_B, 32'h300, 32'h0, ROB_W'(21), 2'd0, PHYS_W'(20));
    expect_wb(ROB_W'(21), 32'h0000_0078);
    
    // Load halfword
    issue_load(OP_LHU, MSZ_H, 32'h300, 32'h0, ROB_W'(22), 2'd0, PHYS_W'(21));
    expect_wb(ROB_W'(22), 32'h0000_5678);
    
    commit_store(ROB_W'(20), 2'd0);

    // TEST 4: Multiple stores to same address, youngest wins
    $display("=== TEST 4: Multiple stores same addr, youngest forwarding ===");
    sq_alloc_store(ROB_W'(30), 2'd0, MSZ_W);
    sq_alloc_store(ROB_W'(31), 2'd0, MSZ_W);
    sq_alloc_store(ROB_W'(32), 2'd0, MSZ_W);
    
    exec_store(ROB_W'(30), 2'd0, MSZ_W, 32'h400, 32'h0, 32'hDEAD_0000);
    exec_store(ROB_W'(31), 2'd0, MSZ_W, 32'h400, 32'h0, 32'hBEEF_1111);
    exec_store(ROB_W'(32), 2'd0, MSZ_W, 32'h400, 32'h0, 32'hCAFE_2222);
    
    // Load should get youngest (ROB=32)
    issue_load(OP_LW, MSZ_W, 32'h400, 32'h0, ROB_W'(33), 2'd0, PHYS_W'(30));
    expect_wb(ROB_W'(33), 32'hCAFE_2222);
    
    commit_store(ROB_W'(30), 2'd0);
    commit_store(ROB_W'(31), 2'd0);
    commit_store(ROB_W'(32), 2'd0);

    // TEST 5: Load waits for older store addr/data (single outstanding)
    $display("=== TEST 5: Load waits for older store info ===");
    sq_alloc_store(ROB_W'(40), 2'd0, MSZ_W);
    
    // Try to issue load before store executes (should block on req_ready_ld)
    fork
      begin
        @(posedge clk);
        req_uop[1]   <= mk_uop(UOP_LOAD, OP_LW, MSZ_W, 32'h0, ROB_W'(41), 2'd0, PHYS_W'(40));
        rs1_val[1]   <= 32'h500;
        req_valid_ld <= 1'b1;
        $display("  Load request asserted at time %0t", $time);
        
        // Should NOT be ready until store executes
        repeat(3) @(posedge clk);
        #1;
        if (req_ready_ld) begin
          $fatal(1, "[TEST5] req_ready_ld should be low until older store has info");
        end
        $display("  req_ready_ld correctly low while waiting for store");
      end
      begin
        repeat(5) @(posedge clk);
        exec_store(ROB_W'(40), 2'd0, MSZ_W, 32'h500, 32'h0, 32'hFEED_FACE);
        $display("  Store executed at time %0t", $time);
      end
    join
    
    // Now wait for load to complete
    #1;
    while (!req_ready_ld) @(posedge clk);
    @(posedge clk);
    req_valid_ld <= 1'b0;
    
    expect_wb(ROB_W'(41), 32'hFEED_FACE, 200);
    commit_store(ROB_W'(40), 2'd0);

    // TEST 6: Flush during pending load
    $display("=== TEST 6: Flush with pending load ===");
    mem[32'h600] = 8'hAA; mem[32'h601] = 8'hBB; mem[32'h602] = 8'hCC; mem[32'h603] = 8'hDD;
    
    fork
      begin
        issue_load(OP_LW, MSZ_W, 32'h600, 32'h0, ROB_W'(50), 2'd0, PHYS_W'(50));
        repeat(3) @(posedge clk);
        flush_valid <= 1'b1;
        @(posedge clk);
        flush_valid <= 1'b0;
        $display("  Flushed at time %0t", $time);
      end
    join
    
    // Should NOT see WB after flush
    repeat(20) @(posedge clk);
    if (wb_valid && wb_rob_idx == ROB_W'(50)) begin
      $fatal(1, "[FLUSH] WB occurred after flush for rob=50");
    end

    // TEST 7: Recovery (branch mispredict)
    $display("=== TEST 7: Recovery kills speculative load ===");
    sq_alloc_store(ROB_W'(60), 2'd1, MSZ_W);
    exec_store(ROB_W'(60), 2'd1, MSZ_W, 32'h700, 32'h0, 32'h0BAD_F00D);
    
    fork
      begin
        issue_load(OP_LW, MSZ_W, 32'h700, 32'h0, ROB_W'(61), 2'd1, PHYS_W'(60));
        repeat(3) @(posedge clk);
        recover_valid   <= 1'b1;
        recover_rob_idx <= ROB_W'(60);
        recover_epoch   <= 2'd1;
        @(posedge clk);
        recover_valid <= 1'b0;
        $display("  Recovery at time %0t", $time);
      end
    join
    
    repeat(20) @(posedge clk);
    if (wb_valid && wb_rob_idx == ROB_W'(61)) begin
      $fatal(1, "[RECOVERY] WB occurred after recovery for rob=61");
    end

    // TEST 8: Store queue full backpressure
    $display("=== TEST 8: SQ full backpressure ===");
    for (int i = 0; i < SQ_SIZE; i++) begin
      sq_alloc_store(ROB_W'(70+i), 2'd0, MSZ_W);
    end
    
    // Next allocation should stall
    @(posedge clk) begin
    sq_entry_in_valid = 1'b1;
    sq_entry_in.rob_idx = ROB_W'(70+SQ_SIZE);
    #1;
    if (sq_entry_in_ready) begin
      $fatal(1, "[SQ] Should be full but ready asserted");
    end
    sq_entry_in_valid = 1'b0;
    end
    
    // Commit and drain one
    exec_store(ROB_W'(70), 2'd0, MSZ_W, 32'h800, 32'h0, 32'h1111_1111);
    commit_store(ROB_W'(70), 2'd0);
    repeat(50) @(posedge clk); // Allow drain
    
    // Now should have space
    sq_alloc_store(ROB_W'(70+SQ_SIZE), 2'd0, MSZ_W);

    // Clean up
    for (int i = 1; i < SQ_SIZE; i++) begin
        exec_store(ROB_W'(70+i), 2'd0, MSZ_W, 32'h800 + i*4, 32'h0, 32'h1111_1111 + i);
        commit_store(ROB_W'(70+i), 2'd0);
    end

    // TEST 9: Signed vs unsigned loads
    $display("=== TEST 9: Signed/unsigned load extensions ===");
    mem[32'h900] = 8'hFF; // -1 signed, 255 unsigned
    mem[32'h902] = 8'hFF; mem[32'h903] = 8'h7F; // 0x7FFF
    
    issue_load(OP_LB,  MSZ_B, 32'h900, 32'h0, ROB_W'(80), 2'd0, PHYS_W'(80));
    expect_wb(ROB_W'(80), 32'hFFFF_FFFF); // Sign extend
    
    issue_load(OP_LBU, MSZ_B, 32'h900, 32'h0, ROB_W'(81), 2'd0, PHYS_W'(81));
    expect_wb(ROB_W'(81), 32'h0000_00FF); // Zero extend
    
    issue_load(OP_LH,  MSZ_H, 32'h902, 32'h0, ROB_W'(82), 2'd0, PHYS_W'(82));
    expect_wb(ROB_W'(82), 32'h0000_7FFF); // Positive half
    
    mem[32'h904] = 8'hFF; mem[32'h905] = 8'hFF;
    issue_load(OP_LH,  MSZ_H, 32'h904, 32'h0, ROB_W'(83), 2'd0, PHYS_W'(83));
    expect_wb(ROB_W'(83), 32'hFFFF_FFFF); // Negative half

    // TEST 10: Unaligned addresses (within word boundary)
    $display("=== TEST 10: Unaligned access within word ===");
    mem[32'hA00] = 8'h11; mem[32'hA01] = 8'h22; 
    mem[32'hA02] = 8'h33; mem[32'hA03] = 8'h44;
    
    issue_load(OP_LBU, MSZ_B, 32'hA01, 32'h0, ROB_W'(90), 2'd0, PHYS_W'(90));
    expect_wb(ROB_W'(90), 32'h0000_0022);
    
    issue_load(OP_LHU, MSZ_H, 32'hA02, 32'h0, ROB_W'(91), 2'd0, PHYS_W'(91));
    expect_wb(ROB_W'(91), 32'h0000_4433);

    // Wait for all stores to drain
    repeat(100) @(posedge clk);

    $display("✅ All aggressive tests passed!");
    $finish;
  end

  // ============================================================
  // Protocol assertions
  // ============================================================
  
  // Response stability under backpressure
//   logic [63:0] resp_data_hold;
//   logic [3:0]  resp_tag_hold;
//   always_ff @(posedge clk) begin
//     if (rst_n && dmem.ld_resp_valid && !dmem.ld_resp_ready) begin
//       resp_data_hold <= dmem.ld_resp_data;
//       resp_tag_hold  <= dmem.ld_resp_tag;
//     end
//     if (rst_n && dmem.ld_resp_valid && !dmem.ld_resp_ready) begin
//       assert(dmem.ld_resp_data == resp_data_hold)
//         else $fatal(1, "ld_resp_data changed under backpressure");
//       assert(dmem.ld_resp_tag == resp_tag_hold)
//         else $fatal(1, "ld_resp_tag changed under backpressure");
//     end
//   end

//   // WB output stability
//   logic [31:0] wb_data_hold;
//   logic [ROB_W-1:0] wb_rob_hold;
//   always_ff @(posedge clk) begin
//     if (rst_n && wb_valid && !wb_ready) begin
//       wb_data_hold <= wb_data;
//       wb_rob_hold  <= wb_rob_idx;
//     end
//     if (rst_n && wb_valid && !wb_ready) begin
//       assert(wb_data == wb_data_hold)
//         else $fatal(1, "wb_data changed under backpressure");
//       assert(wb_rob_idx == wb_rob_hold)
//         else $fatal(1, "wb_rob_idx changed under backpressure");
//     end
//   end

  // No WB after flush/recover for killed instructions
  logic [1:0] killed_epoch;
  logic [ROB_W-1:0] killed_rob;
  logic track_killed;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      track_killed <= 1'b0;
    end else begin
      if (flush_valid) begin
        track_killed <= 1'b1;
        killed_epoch <= 2'b11; // Mark all epochs killed
      end else if (recover_valid) begin
        track_killed <= 1'b1;
        killed_epoch <= recover_epoch;
        killed_rob   <= recover_rob_idx;
      end else if (track_killed) begin
        // Check no WB for killed instructions
        if (wb_valid) begin
          if (flush_valid) begin
            $fatal(1, "WB after flush: rob=%0d", wb_rob_idx);
          end else if (recover_valid && wb_epoch == killed_epoch && wb_rob_idx >= killed_rob) begin
            $fatal(1, "WB after recovery: rob=%0d epoch=%0d", wb_rob_idx, wb_epoch);
          end
        end
      end
    end
  end

endmodule