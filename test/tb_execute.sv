`timescale 1ns/1ps
`include "defines.svh"

module execute_tb;

  // Clock and reset
  logic clk;
  logic rst_n;

  // Dispatch interface
  logic              disp_valid;
  logic              disp_ready;
  rs_uop_t           disp_uop;

  // PRF read interface
  logic [31:0]       rdata1 [FU_NUM-1:0];
  logic [31:0]       rdata2 [FU_NUM-1:0];
  logic              rready1 [FU_NUM-1:0];
  logic              rready2 [FU_NUM-1:0];
  logic [PHYS_W-1:0] raddr1 [FU_NUM-1:0];
  logic [PHYS_W-1:0] raddr2 [FU_NUM-1:0];

  // Store queue allocate
  decoded_bundle_t   decoded_bundle_fields;
  logic              stq_alloc_valid;
  logic              stq_alloc_ready;
  logic [ROB_W-1:0]  stq_alloc_rob_idx;
  logic [1:0]        global_epoch;

  // Flush/recovery
  logic              flush_valid;
  logic              recover_valid;
  logic [ROB_W-1:0]  recover_rob_idx;
  logic [1:0]        recover_epoch;

  // Commit interface
  logic              commit_valid;
  logic              commit_ready;
  rob_entry_t        commit_entry;
  logic [ROB_W-1:0]  commit_rob_idx;

  // Data memory interface
  dmem_if #(.LDTAG_W(4)) dmem();

  // Writeback interface
  logic              wb_valid;
  logic              wb_ready;
  fu_wb_t            wb_pkt;

  // Status
  logic              rs_busy;

  // DUT instantiation
  execute dut (
    .clk(clk),
    .rst_n(rst_n),
    .disp_valid(disp_valid),
    .disp_ready(disp_ready),
    .disp_uop(disp_uop),
    .rdata1(rdata1),
    .rdata2(rdata2),
    .rready1(rready1),
    .rready2(rready2),
    .raddr1(raddr1),
    .raddr2(raddr2),
    .decoded_bundle_fields(decoded_bundle_fields),
    .stq_alloc_valid(stq_alloc_valid),
    .stq_alloc_ready(stq_alloc_ready),
    .stq_alloc_rob_idx(stq_alloc_rob_idx),
    .global_epoch(global_epoch),
    .flush_valid(flush_valid),
    .recover_valid(recover_valid),
    .recover_rob_idx(recover_rob_idx),
    .recover_epoch(recover_epoch),
    .commit_valid(commit_valid),
    .commit_ready(commit_ready),
    .commit_entry(commit_entry),
    .commit_rob_idx(commit_rob_idx),
    .dmem(dmem),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_pkt(wb_pkt),
    .rs_busy(rs_busy)
  );

  // Clock generation
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // Simulated PRF storage
  logic [31:0] prf_sim [PHYS_REGS];
  logic        prf_valid [0:PHYS_REGS-1];

  // PRF read logic (combinational)
  always_comb begin
    for (int i = 0; i < FU_NUM; i++) begin
      rdata1[i]  = prf_sim[raddr1[i]];
      rdata2[i]  = prf_sim[raddr2[i]];
      rready1[i] = prf_valid[raddr1[i]];
      rready2[i] = prf_valid[raddr2[i]];
    end
  end

  // Simulated memory (simple array)
  // NOTE: This is a simplified word-granular memory for testing
  // Real RV32I memory is byte-addressable
  // Our mem_sim[i] represents the 32-bit word at byte address (i*4)
  // The 64-bit dmem interface allows transferring up to 8 bytes per cycle
  logic [31:0] mem_sim [1024];  // 1024 words = 4KB of memory

  // Memory interface handling
  logic [3:0] ld_pending_tag;
  logic       ld_pending;
  logic [31:0] ld_pending_addr;
  int         ld_delay_count;

  logic[9:0] mem_sim_addr;

  initial begin
    dmem.ld_ready = 1;
    dmem.ld_resp_valid = 0;
    dmem.st_ready = 1;
    ld_pending = 0;
  end

  // Simple memory model
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dmem.ld_resp_valid <= 0;
      dmem.st_ready <= 1;       // Keep store ready after reset
      ld_pending <= 0;
      ld_delay_count <= 0;
    end else begin
      // Keep store port always ready (simple model)
      dmem.st_ready <= 1'b1;
      
      // Handle load requests
      if (dmem.ld_valid && dmem.ld_ready && !ld_pending) begin
        ld_pending <= 1;
        ld_pending_tag <= dmem.ld_tag;
        ld_pending_addr <= dmem.ld_addr;
        ld_delay_count <= 2; // 2 cycle latency
      end

      // Count down delay
      if (ld_pending && ld_delay_count > 0) begin
        ld_delay_count <= ld_delay_count - 1;
      end

      // Send response
      if (ld_pending && ld_delay_count == 0 && !dmem.ld_resp_valid) begin
        logic [31:0] word_data;
        word_data = mem_sim[ld_pending_addr[11:2]];
        
        dmem.ld_resp_valid <= 1;
        dmem.ld_resp_tag <= ld_pending_tag;
        // Memory returns 64-bit data: duplicate word in both halves
        // LSU extracts correct half based on addr[2]
        dmem.ld_resp_data <= {word_data, word_data};
        dmem.ld_resp_err <= 0;
      end

      // Clear response when accepted
      if (dmem.ld_resp_valid && dmem.ld_resp_ready) begin
        dmem.ld_resp_valid <= 0;
        ld_pending <= 0;
      end

      // Handle store requests - use byte strobe to write correctly
      if (dmem.st_valid && dmem.st_ready) begin
        logic [31:0] store_data;
        
        // Extract the correct 32-bit word based on address[2]
        // LSU places data in correct half of 64-bit bus
        if (dmem.st_addr[2]) begin
          store_data = dmem.st_wdata[63:32];  // Upper half
        end else begin
          store_data = dmem.st_wdata[31:0];   // Lower half
        end
        
        // Write to memory (word-granular for simplicity)
        mem_sim[dmem.st_addr[11:2]] <= store_data;
        
        $display("[MEM] Store: addr=0x%08h → mem_sim[%0d] = 0x%08h (wstrb=0x%02h) at time %0t", 
                 dmem.st_addr, dmem.st_addr[11:2], store_data, dmem.st_wstrb, $time);
      end
    end
  end

  // Test statistics
  int test_count = 0;
  int pass_count = 0;
  int fail_count = 0;
  int dispatch_count = 0;
  int wb_count = 0;
  int broken;

  // Scoreboard for tracking in-flight operations
  typedef struct {
    logic        valid;
    logic [ROB_W-1:0] rob_idx;
    logic [PHYS_W-1:0] prd;
    logic [31:0] expected_result;
    uop_class_e  uop_class;
  } scoreboard_entry_t;

  scoreboard_entry_t scoreboard [16];  // Track up to 16 in-flight ops

  // Helper tasks
  task automatic reset_dut();
    rst_n = 0;
    disp_valid = 0;
    wb_ready = 1;
    flush_valid = 0;
    recover_valid = 0;
    stq_alloc_valid = 0;
    commit_valid = 0;
    global_epoch = 0;
    
    // Initialize PRF
    for (int i = 0; i < PHYS_REGS; i++) begin
      prf_sim[i] = 32'h0;
      prf_valid[i] = 1'b1;  // All valid initially
    end
    
    // Initialize scoreboard
    for (int i = 0; i < 16; i++) begin
      scoreboard[i].valid = 0;
    end
    
    repeat(3) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);
  endtask

  task automatic dispatch_alu_op(
    input uop_op_e op,
    input logic [PHYS_W-1:0] prs1,
    input logic [PHYS_W-1:0] prs2,
    input logic [PHYS_W-1:0] prd,
    input logic [31:0] imm,
    input logic [ROB_W-1:0] rob_idx,
    input logic rdy1,
    input logic rdy2
  );
    // Fill bundle fields
    disp_uop.bundle.pc = 32'h1000 + (dispatch_count * 4);
    disp_uop.bundle.uop_class = UOP_ALU;
    disp_uop.bundle.op = op;
    disp_uop.bundle.func7 = 7'b0;
    disp_uop.bundle.func3 = 3'b0;
    disp_uop.bundle.branch_type = BR_NONE;
    disp_uop.bundle.mem_size = MSZ_W;
    disp_uop.bundle.src1_select = SRC_RS1;
    disp_uop.bundle.src2_select = (op == OP_ADD) ? SRC_RS2 : SRC_IMM;
    disp_uop.bundle.uses_rs1 = 1'b1;
    disp_uop.bundle.uses_rs2 = (op == OP_ADD);
    disp_uop.bundle.uses_rd = 1'b1;
    disp_uop.bundle.rs1_arch = 5'b0;
    disp_uop.bundle.rs2_arch = 5'b0;
    disp_uop.bundle.rd_arch = 5'b0;
    disp_uop.bundle.imm = imm;
    disp_uop.bundle.pred_taken = 1'b0;
    disp_uop.bundle.pred_target = 32'h0;
    
    // Fill top-level renamed fields
    disp_uop.rob_idx = rob_idx;
    disp_uop.epoch = global_epoch;
    disp_uop.prs1 = prs1;
    disp_uop.rdy1 = rdy1;
    disp_uop.prs2 = prs2;
    disp_uop.rdy2 = rdy2;
    disp_uop.prd_new = prd;
    
    disp_valid = 1;
    @(posedge clk);
    while (!disp_ready) @(posedge clk);
    disp_valid = 0;
    
    dispatch_count++;

    prf_valid[prd] = 1'b0;  // Destination not ready after rename
    
    // Add to scoreboard
    scoreboard[rob_idx].valid = 1;
    scoreboard[rob_idx].rob_idx = rob_idx;
    scoreboard[rob_idx].prd = prd;
    scoreboard[rob_idx].uop_class = UOP_ALU;
    
    // Calculate expected result
    case (op)
      OP_ADD:  scoreboard[rob_idx].expected_result = prf_sim[prs1] + prf_sim[prs2];
      OP_ADDI: scoreboard[rob_idx].expected_result = prf_sim[prs1] + imm;
      default: scoreboard[rob_idx].expected_result = 32'hDEADBEEF;
    endcase
  endtask

  task automatic dispatch_branch(
    input branch_type_e br_type,
    input logic [PHYS_W-1:0] prs1,
    input logic [PHYS_W-1:0] prs2,
    input logic [31:0] imm,
    input logic [ROB_W-1:0] rob_idx,
    input logic pred_taken,
    input logic [31:0] pred_target
  );
    // Fill bundle fields
    disp_uop.bundle.pc = 32'h1000 + (dispatch_count * 4);
    disp_uop.bundle.uop_class = UOP_BRANCH;
    disp_uop.bundle.op = OP_BEQ;
    disp_uop.bundle.func7 = 7'b0;
    disp_uop.bundle.func3 = 3'b0;
    disp_uop.bundle.branch_type = br_type;
    disp_uop.bundle.mem_size = MSZ_W;
    disp_uop.bundle.src1_select = SRC_RS1;
    disp_uop.bundle.src2_select = SRC_RS2;
    disp_uop.bundle.uses_rs1 = 1'b1;
    disp_uop.bundle.uses_rs2 = 1'b1;
    disp_uop.bundle.uses_rd = 1'b0;
    disp_uop.bundle.rs1_arch = 5'b0;
    disp_uop.bundle.rs2_arch = 5'b0;
    disp_uop.bundle.rd_arch = 5'b0;
    disp_uop.bundle.imm = imm;
    disp_uop.bundle.pred_taken = pred_taken;
    disp_uop.bundle.pred_target = pred_target;
    
    // Fill top-level renamed fields
    disp_uop.rob_idx = rob_idx;
    disp_uop.epoch = global_epoch;
    disp_uop.prs1 = prs1;
    disp_uop.rdy1 = 1'b1;
    disp_uop.prs2 = prs2;
    disp_uop.rdy2 = 1'b1;
    disp_uop.prd_new = 6'b0;
    
    disp_valid = 1;
    @(posedge clk);
    while (!disp_ready) @(posedge clk);
    disp_valid = 0;
    
    dispatch_count++;
    
    scoreboard[rob_idx].valid = 1;
    scoreboard[rob_idx].rob_idx = rob_idx;
    scoreboard[rob_idx].uop_class = UOP_BRANCH;
  endtask

  task automatic dispatch_load(
    input logic [PHYS_W-1:0] prs1,
    input logic [PHYS_W-1:0] prd,
    input logic [31:0] imm,
    input logic [ROB_W-1:0] rob_idx,
    input logic rdy1
  );
    // Fill bundle fields for a word load (LW)
    disp_uop.bundle.pc = 32'h2000 + (dispatch_count * 4);
    disp_uop.bundle.uop_class = UOP_LOAD;
    disp_uop.bundle.op = OP_LW;
    disp_uop.bundle.func7 = 7'b0;
    disp_uop.bundle.func3 = 3'b0;
    disp_uop.bundle.branch_type = BR_NONE;
    disp_uop.bundle.mem_size = MSZ_W;
    disp_uop.bundle.src1_select = SRC_RS1;
    disp_uop.bundle.src2_select = SRC_IMM;
    disp_uop.bundle.uses_rs1 = 1'b1;
    disp_uop.bundle.uses_rs2 = 1'b0;
    disp_uop.bundle.uses_rd  = 1'b1;
    disp_uop.bundle.rs1_arch = 5'b0;
    disp_uop.bundle.rs2_arch = 5'b0;
    disp_uop.bundle.rd_arch  = 5'b0;
    disp_uop.bundle.imm = imm;
    disp_uop.bundle.pred_taken  = 1'b0;
    disp_uop.bundle.pred_target = 32'h0;

    // Fill top-level renamed fields
    disp_uop.rob_idx  = rob_idx;
    disp_uop.epoch    = global_epoch;
    disp_uop.prs1     = prs1;
    disp_uop.rdy1     = rdy1;
    disp_uop.prs2     = '0;
    disp_uop.rdy2     = 1'b1;
    disp_uop.prd_new  = prd;

    // Rename would typically mark destination as not-ready
    prf_valid[prd] = 1'b0;

    disp_valid = 1;
    @(posedge clk);
    while (!disp_ready) @(posedge clk);
    disp_valid = 0;

    dispatch_count++;

    // Scoreboard: expected load result from our mem_sim array
    scoreboard[rob_idx].valid = 1;
    scoreboard[rob_idx].rob_idx = rob_idx;
    scoreboard[rob_idx].prd = prd;
    scoreboard[rob_idx].uop_class = UOP_LOAD;
    mem_sim_addr = (prf_sim[prs1] + imm) >> 2;
    scoreboard[rob_idx].expected_result = mem_sim[mem_sim_addr];
  endtask

  task automatic dispatch_store(
    input logic [PHYS_W-1:0] prs1,
    input logic [PHYS_W-1:0] prs2,
    input logic [31:0] imm,
    input logic [ROB_W-1:0] rob_idx,
    input logic rdy1,
    input logic rdy2
  );
    bit disp_done, stq_done;
    // Provide the decoded bundle mem_size for SQ allocation sideband
    decoded_bundle_fields = '0;
    decoded_bundle_fields.mem_size = MSZ_W;

    // Fill bundle fields for a word store (SW)
    disp_uop.bundle.pc = 32'h3000 + (dispatch_count * 4);
    disp_uop.bundle.uop_class = UOP_STORE;
    disp_uop.bundle.op = OP_SW;
    disp_uop.bundle.func7 = 7'b0;
    disp_uop.bundle.func3 = 3'b0;
    disp_uop.bundle.branch_type = BR_NONE;
    disp_uop.bundle.mem_size = MSZ_W;
    disp_uop.bundle.src1_select = SRC_RS1;
    disp_uop.bundle.src2_select = SRC_IMM;
    disp_uop.bundle.uses_rs1 = 1'b1;
    disp_uop.bundle.uses_rs2 = 1'b1;
    disp_uop.bundle.uses_rd  = 1'b0;
    disp_uop.bundle.rs1_arch = 5'b0;
    disp_uop.bundle.rs2_arch = 5'b0;
    disp_uop.bundle.rd_arch  = 5'b0;
    disp_uop.bundle.imm = imm;
    disp_uop.bundle.pred_taken  = 1'b0;
    disp_uop.bundle.pred_target = 32'h0;

    // Fill top-level renamed fields
    disp_uop.rob_idx  = rob_idx;
    disp_uop.epoch    = global_epoch;
    disp_uop.prs1     = prs1;
    disp_uop.rdy1     = rdy1;
    disp_uop.prs2     = prs2;
    disp_uop.rdy2     = rdy2;
    disp_uop.prd_new  = '0;

    // Request a Store Queue entry allocation (sideband)
    stq_alloc_rob_idx = rob_idx;
    stq_alloc_valid   = 1'b1;

    disp_valid = 1'b1;

    // Handshake both channels independently
    disp_done = 0;
    stq_done  = 0;

    do begin
      @(posedge clk);
      if (disp_valid && disp_ready) begin
        disp_valid = 1'b0;
        disp_done = 1;
      end
      if (stq_alloc_valid && stq_alloc_ready) begin
        stq_alloc_valid = 1'b0;
        stq_done = 1;
      end
    end while (!(disp_done && stq_done));

    dispatch_count++;
  endtask

  task automatic commit_store(
    input logic [ROB_W-1:0] rob_idx,
    input logic [1:0] epoch
  );
    commit_entry = '0;
    commit_entry.is_store = 1'b1;
    commit_entry.epoch    = epoch;
    commit_rob_idx        = rob_idx;

    commit_ready = 1'b1;
    commit_valid = 1'b1;
    @(posedge clk);
    commit_valid = 1'b0;
  endtask

  task automatic wait_for_store_drain(input int max_cycles = 50);
    int cycles = 0;
    while (!(dmem.st_valid && dmem.st_ready)) begin
      @(posedge clk);
      cycles++;
      if (cycles > max_cycles) begin
        $display("[WARNING] Store drain timeout after %0d cycles", max_cycles);
        return;
      end
    end
    @(posedge clk); // One more cycle for write to complete
  endtask

  // Monitor writeback and update PRF
  always_ff @(posedge clk) begin
    if (wb_valid && wb_ready) begin
      wb_count++;
      
      if (wb_pkt.uses_rd && wb_pkt.data_valid) begin
        prf_sim[wb_pkt.prd_new] <= wb_pkt.data;
        prf_valid[wb_pkt.prd_new] <= 1'b1;
        
        // Check scoreboard
        if (scoreboard[wb_pkt.rob_idx].valid) begin
          if ((scoreboard[wb_pkt.rob_idx].uop_class == UOP_ALU) || 
              (scoreboard[wb_pkt.rob_idx].uop_class == UOP_LOAD)) begin
            if (wb_pkt.data == scoreboard[wb_pkt.rob_idx].expected_result) begin
              $display("[PASS] ROB[%0d] WB: prd=p%0d, data=0x%08h (expected 0x%08h)", 
                       wb_pkt.rob_idx, wb_pkt.prd_new, wb_pkt.data,
                       scoreboard[wb_pkt.rob_idx].expected_result);
              pass_count++;
              test_count++;
            end else begin
              $display("[FAIL] ROB[%0d] WB: prd=p%0d, data=0x%08h (expected 0x%08h)", 
                       wb_pkt.rob_idx, wb_pkt.prd_new, wb_pkt.data,
                       scoreboard[wb_pkt.rob_idx].expected_result);
              fail_count++;
              test_count++;
            end
          end
          scoreboard[wb_pkt.rob_idx].valid = 0;
        end
      end
      
      if (wb_pkt.is_branch) begin
        $display("[INFO] Branch resolved: rob=%0d, taken=%b, mispredict=%b",
                 wb_pkt.rob_idx, wb_pkt.act_taken, wb_pkt.mispredict);
        scoreboard[wb_pkt.rob_idx].valid = 0;
      end
    end
  end

  // Main test sequence
  initial begin
    $display("========================================");
    $display("Execute Block Testbench Starting");
    $display("========================================");
    
    reset_dut();
    
    // Initialize some PRF values
    prf_sim[1] = 32'd10;
    prf_sim[2] = 32'd20;
    prf_sim[3] = 32'd30;
    prf_sim[4] = 32'd5;
    prf_valid[1] = 1'b1;
    prf_valid[2] = 1'b1;
    prf_valid[3] = 1'b1;
    prf_valid[4] = 1'b1;
    
    // ========================================
    // Test 1: Simple ALU operations (independent)
    // ========================================
    $display("\n--- Test 1: Independent ALU Operations ---");
    dispatch_alu_op(OP_ADD, 6'd1, 6'd2, 6'd10, 32'h0, 4'd0, 1'b1, 1'b1);
    dispatch_alu_op(OP_ADDI, 6'd3, 6'd0, 6'd11, 32'd5, 4'd1, 1'b1, 1'b1);
    
    repeat(10) @(posedge clk);
    
    // ========================================
    // Test 2: Dependent ALU operations (RAW hazard)
    // ========================================
    $display("\n--- Test 2: Dependent ALU Operations ---");
    dispatch_alu_op(OP_ADDI, 6'd1, 6'd0, 6'd12, 32'd100, 4'd2, 1'b1, 1'b1);
    prf_valid[12] = 1'b0;
    dispatch_alu_op(OP_ADDI, 6'd12, 6'd0, 6'd13, 32'd50, 4'd3, 1'b0, 1'b1);
    
    repeat(15) @(posedge clk);
    
    // ========================================
    // Test 3: Branch operation
    // ========================================
    $display("\n--- Test 3: Branch Operation ---");
    prf_sim[5] = 32'd10;
    prf_sim[6] = 32'd10;
    prf_valid[5] = 1'b1;
    prf_valid[6] = 1'b1;
    dispatch_branch(BR_BEQ, 6'd5, 6'd6, 32'h100, 4'd4, 1'b1, 32'h1100);
    
    repeat(10) @(posedge clk);
    
    // ========================================
    // Test 4: Mixed ALU and Branch
    // ========================================
    $display("\n--- Test 4: Mixed ALU and Branch ---");
    dispatch_alu_op(OP_ADDI, 6'd1, 6'd0, 6'd14, 32'd7, 4'd5, 1'b1, 1'b1);
    dispatch_branch(BR_BNE, 6'd1, 6'd2, 32'h80, 4'd6, 1'b0, 32'h1004);
    dispatch_alu_op(OP_ADD, 6'd1, 6'd4, 6'd15, 32'h0, 4'd7, 1'b1, 1'b1);
    
    repeat(15) @(posedge clk);
    
    // ========================================
    // Test 5: Fill RS and test backpressure
    // ========================================
    broken = 0;
    $display("\n--- Test 5: RS Backpressure Test ---");
    for (int i = 0; i < RS_SIZE + 2; i++) begin
      fork
        begin : dispatch_loop
            automatic int prd_val = 16 + i;
            automatic int imm_val = i;
            automatic int rob_val = 8 + i;
            dispatch_alu_op(OP_ADDI, 6'd1, 6'd0, prd_val[PHYS_W-1:0], imm_val[31:0], rob_val[ROB_W-1:0], 1'b1, 1'b1);
        end
        begin : monitor_loop
            @(posedge clk);
            if (~disp_ready) begin
                $display("[INFO] RS Full - backpressure working");
                disable dispatch_loop;
                broken = 1;
            end 
        end
      join
      if (broken) break;
    end
    
    repeat(20) @(posedge clk);
    
    // ========================================
    // Test 6: Flush test
    // ========================================
    $display("\n--- Test 6: Flush Test ---");
    dispatch_alu_op(OP_ADDI, 6'd1, 6'd0, 6'd20, 32'd999, 4'd10, 1'b1, 1'b1);
    @(posedge clk);
    flush_valid = 1;
    @(posedge clk);
    flush_valid = 0;
    
    repeat(5) @(posedge clk);
    
    if (wb_valid && wb_pkt.rob_idx == 10) begin
      $display("[FAIL] Flushed operation completed");
      fail_count++;
    end else begin
      $display("[PASS] Flush prevented completion");
      pass_count++;
    end
    
    // ========================================
    // Test 7: LSU Basic Load (LW)
    // ========================================
    $display("\n--- Test 7: LSU Basic Load (LW) ---");
    mem_sim[8]  = 32'hA1B2C3D4;
    prf_sim[7]  = 32'h0000_0020;
    prf_valid[7]= 1'b1;

    dispatch_load(6'd7, 6'd20, 32'h0, 4'd12, 1'b1);
    repeat(20) @(posedge clk);

    // ========================================
    // Test 8: LSU Store->Load Forwarding (uncommitted)
    // ========================================
    $display("\n--- Test 8: LSU Store->Load Forwarding (uncommitted) ---");
    mem_sim[9]   = 32'h1111_1111;
    prf_sim[7]   = 32'h0000_0024;
    prf_valid[7] = 1'b1;
    prf_sim[8]   = 32'hDEAD_BEEF;
    prf_valid[8] = 1'b1;

    dispatch_store(6'd7, 6'd8, 32'h0, 4'd13, 1'b1, 1'b1);
    repeat(5) @(posedge clk);
    
    dispatch_load(6'd7, 6'd21, 32'h0, 4'd14, 1'b1);
    scoreboard[4'd14].expected_result = 32'hDEAD_BEEF;
    repeat(30) @(posedge clk);
    
    commit_store(4'd13, global_epoch);
    wait_for_store_drain(50);
    repeat(5) @(posedge clk);

    // ========================================
    // Test 9: LSU Store Commit → Drain → Load from Memory
    // ========================================
    $display("\n--- Test 9: Store Commit, Drain, then Load from Memory ---");
    mem_sim[10]  = 32'h2222_2222;
    prf_sim[7]   = 32'h0000_0028;
    prf_valid[7] = 1'b1;
    prf_sim[9]   = 32'hCAFE_BABE;
    prf_valid[9] = 1'b1;

    dispatch_store(6'd7, 6'd9, 32'h0, 4'd15, 1'b1, 1'b1);
    repeat(10) @(posedge clk);
    
    $display("  Committing store...");
    commit_store(4'd15, global_epoch);
    
    $display("  Waiting for store to drain...");
    wait_for_store_drain(50);
    $display("  Store drained, memory = 0x%08h", mem_sim[10]);
    repeat(5) @(posedge clk);

    $display("  Dispatching load from memory...");
    dispatch_load(6'd7, 6'd22, 32'h0, 4'd0, 1'b1);
    scoreboard[4'd0].expected_result = 32'hCAFE_BABE;
    repeat(30) @(posedge clk);

    // ========================================
    // Test 10: Store with Dependent Operands (NOT READY)
    // ========================================
    $display("\n--- Test 10: Store with Dependent Operands ---");
    // Scenario: Store data comes from ALU result that's not ready yet
    mem_sim[11] = 32'h0000_0000;
    prf_sim[7]  = 32'h0000_002C;  // base address
    prf_valid[7] = 1'b1;
    prf_sim[1]  = 32'd100;
    prf_valid[1] = 1'b1;
    
    // ALU: p50 = p1 + 500
    $display("  [1] Dispatch ALU: p50 = p1 + 500 (produces store data)");
    dispatch_alu_op(OP_ADDI, 6'd1, 6'd0, 6'd50, 32'd500, 4'd1, 1'b1, 1'b1);
    prf_valid[50] = 1'b0;  // Mark as not ready
    
    // Store with not-ready operand: store p50 to [p7+0]
    $display("  [2] Dispatch STORE with NOT READY data: MEM[p7+0] = p50");
    dispatch_store(6'd7, 6'd50, 32'h0, 4'd2, 1'b1, 1'b0);  // prs2 not ready!
    
    $display("  Waiting for ALU to produce p50, then store executes...");
    repeat(30) @(posedge clk);
    
    commit_store(4'd2, global_epoch);
    wait_for_store_drain(50);
    repeat(5) @(posedge clk);
    
    // Verify memory was written correctly
    if (mem_sim[11] == 32'd600) begin
      $display("[PASS] Store with dependent operand: mem[11] = %0d (expected 600)", mem_sim[11]);
      pass_count++;
    end else begin
      $display("[FAIL] Store with dependent operand: mem[11] = %0d (expected 600)", mem_sim[11]);
      fail_count++;
    end

    // ========================================
    // Test 11: Forwarding Priority
    // ========================================
    $display("\n--- Test 11: Forwarding Priority Test ---");
    mem_sim[16] = 32'hDEAD_BEEF;
    prf_sim[7]  = 32'h0000_0040;
    prf_sim[10] = 32'h1111_2222;
    prf_sim[11] = 32'h3333_4444;
    prf_valid[7] = 1'b1;
    prf_valid[10] = 1'b1;
    prf_valid[11] = 1'b1;

    $display("  [A] First store (will commit)...");
    global_epoch = 2'd0;
    dispatch_store(6'd7, 6'd10, 32'h0, 4'd11, 1'b1, 1'b1);
    repeat(10) @(posedge clk);
    commit_store(4'd11, 2'd0);
    wait_for_store_drain(50);
    $display("  Memory = 0x%08h", mem_sim[16]);
    repeat(5) @(posedge clk);

    $display("  [B] Second store (uncommitted, newer)...");
    global_epoch = 2'd1;
    dispatch_store(6'd7, 6'd11, 32'h0, 4'd3, 1'b1, 1'b1);
    repeat(10) @(posedge clk);

    $display("  [C] Load (should forward from uncommitted)...");
    dispatch_load(6'd7, 6'd23, 32'h0, 4'd4, 1'b1);
    scoreboard[4'd4].expected_result = 32'h3333_4444;
    repeat(40) @(posedge clk);

    commit_store(4'd3, global_epoch);
    wait_for_store_drain(50);
    repeat(5) @(posedge clk);

    // ========================================
    // Test 12: Complex Mixed FU Test
    // ========================================
    $display("\n--- Test 12: Complex Mixed FU Test (ALU+BRU+LSU) ---");
    
    mem_sim[20] = 32'h1000_0000;
    mem_sim[21] = 32'h2000_0000;
    mem_sim[22] = 32'h3000_0000;
    
    prf_sim[12] = 32'h0000_0050;
    prf_sim[13] = 32'd100;
    prf_sim[14] = 32'd200;
    prf_sim[15] = 32'hAAAA_AAAA;
    prf_valid[12] = 1'b1;
    prf_valid[13] = 1'b1;
    prf_valid[14] = 1'b1;
    prf_valid[15] = 1'b1;
    
    $display("  [1] ALU: p24 = p13 + 50");
    dispatch_alu_op(OP_ADDI, 6'd13, 6'd0, 6'd24, 32'd50, 4'd5, 1'b1, 1'b1);
    
    $display("  [2] LOAD: p25 = MEM[p12+0]");
    dispatch_load(6'd12, 6'd25, 32'h0, 4'd6, 1'b1);
    
    repeat(2) @(posedge clk);
    
    $display("  [3] ALU: p26 = p24 + p14 (depends on ALU)");
    dispatch_alu_op(OP_ADD, 6'd24, 6'd14, 6'd26, 32'h0, 4'd7, 1'b0, 1'b1);
    
    $display("  [4] STORE: MEM[p12+4] = p15");
    dispatch_store(6'd12, 6'd15, 32'h4, 4'd8, 1'b1, 1'b1);
    
    repeat(2) @(posedge clk);
    
    $display("  [5] BRANCH: BEQ p13, p24");
    dispatch_branch(BR_BEQ, 6'd13, 6'd24, 32'h100, 4'd9, 1'b0, 32'h2100);
    
    repeat(3) @(posedge clk);
    
    $display("  [6] LOAD: p27 = MEM[p12+4] (forward)");
    dispatch_load(6'd12, 6'd27, 32'h4, 4'd10, 1'b1);
    scoreboard[4'd10].expected_result = 32'hAAAA_AAAA;
    
    repeat(2) @(posedge clk);
    
    $display("  [7] ALU: p28 = p25 + p27 (depends on loads)");
    dispatch_alu_op(OP_ADD, 6'd25, 6'd27, 6'd28, 32'h0, 4'd11, 1'b1, 1'b1);
    
    repeat(2) @(posedge clk);
    
    $display("  [8] STORE: MEM[p12+8] = p28 (depends on ALU)");
    dispatch_store(6'd12, 6'd28, 32'h8, 4'd12, 1'b1, 1'b1);
    
    repeat(50) @(posedge clk);
    
    commit_store(4'd8, global_epoch);
    wait_for_store_drain(50);
    repeat(5) @(posedge clk);
    
    commit_store(4'd12, global_epoch);
    wait_for_store_drain(50);
    repeat(5) @(posedge clk);
    
    if (mem_sim[21] == 32'hAAAA_AAAA) begin
      $display("[PASS] Store to 0x54: 0x%08h", mem_sim[21]);
      pass_count++;
    end else begin
      $display("[FAIL] Store to 0x54: 0x%08h (expected 0xAAAA_AAAA)", mem_sim[21]);
      fail_count++;
    end
    
    if (mem_sim[22] == (32'h1000_0000 + 32'hAAAA_AAAA)) begin
      $display("[PASS] Store to 0x58: 0x%08h", mem_sim[22]);
      pass_count++;
    end else begin
      $display("[FAIL] Store to 0x58: 0x%08h (expected 0x%08h)", 
               mem_sim[22], 32'h1000_0000 + 32'hAAAA_AAAA);
      fail_count++;
    end
    
    // ========================================
    // Summary
    // ========================================
    repeat(10) @(posedge clk);
    
    $display("\n========================================");
    $display("Test Summary");
    $display("========================================");
    $display("Dispatched:  %0d operations", dispatch_count);
    $display("Completed:   %0d writebacks", wb_count);
    $display("Passed:      %0d checks", pass_count);
    $display("Failed:      %0d checks", fail_count);
    $display("========================================");
    
    if (fail_count == 0)
      $display("ALL TESTS PASSED!");
    else
      $display("SOME TESTS FAILED!");
    
    $finish;
  end

endmodule