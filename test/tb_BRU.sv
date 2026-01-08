`timescale 1ns/1ps
`include "defines.svh"

module BRU_tb;

  // Clock and reset
  logic clk;
  logic rst_n;

  // Request interface
  logic        req_valid;
  logic        req_ready;
  rs_uop_t     req_uop;

  // Operand values
  logic [31:0] rs1_val;
  logic [31:0] rs2_val;

  // Writeback interface
  logic        wb_valid;
  logic        wb_ready;
  logic        wb_uses_rd;
  logic [1:0]  wb_epoch;
  logic [ROB_W-1:0]  wb_rob_idx;
  logic [PHYS_W-1:0] wb_prd_new;
  logic [31:0] wb_data;

  // Branch resolution outputs
  logic        br_valid;
  logic        act_taken;
  logic [31:0] target_pc;

  // Redirect interface
  logic        mispredict;
  logic        redirect_valid;
  logic [31:0] redirect_pc;

  // DUT instantiation
  BRU dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_uop(req_uop),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_uses_rd(wb_uses_rd),
    .wb_epoch(wb_epoch),
    .wb_rob_idx(wb_rob_idx),
    .wb_prd_new(wb_prd_new),
    .wb_data(wb_data),
    .br_valid(br_valid),
    .act_taken(act_taken),
    .target_pc(target_pc),
    .mispredict(mispredict),
    .redirect_valid(redirect_valid),
    .redirect_pc(redirect_pc)
  );

  // Clock generation
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // Test statistics
  int test_count = 0;
  int pass_count = 0;
  int fail_count = 0;

  // Test helper tasks
  task automatic reset_dut();
    rst_n = 0;
    req_valid = 0;
    wb_ready = 1;
    rs1_val = 0;
    rs2_val = 0;
    req_uop = '0;
    repeat(2) @(posedge clk);
    rst_n = 1;
    repeat(1) @(posedge clk);
  endtask

  task automatic send_branch(
    input logic [31:0] pc,
    input branch_type_e br_type,
    input logic [31:0] imm,
    input logic [31:0] r1_val,
    input logic [31:0] r2_val,
    input logic pred_taken,
    input logic [31:0] pred_target,
    input logic [ROB_W-1:0] rob_idx,
    input logic [1:0] epoch,
    input logic uses_rd_in,
    input logic [PHYS_W-1:0] prd
  );
    req_uop.bundle.pc = pc;
    req_uop.bundle.uop_class = UOP_BRANCH;
    req_uop.bundle.branch_type = br_type;
    req_uop.bundle.imm = imm;
    req_uop.bundle.pred_taken = pred_taken;
    req_uop.bundle.pred_target = pred_target;
    req_uop.rob_idx = rob_idx;
    req_uop.epoch = epoch;
    req_uop.bundle.uses_rd = uses_rd_in;
    req_uop.bundle.uses_rs1 = 1'b1;
    req_uop.bundle.uses_rs2 = 1'b1;
    req_uop.prd_new = prd;
    
    rs1_val = r1_val;
    rs2_val = r2_val;
    req_valid = 1;
    
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    req_valid = 0;
  endtask

  task automatic send_jal(
    input logic [31:0] pc,
    input logic [31:0] imm,
    input logic pred_taken,
    input logic [31:0] pred_target,
    input logic [ROB_W-1:0] rob_idx,
    input logic [1:0] epoch,
    input logic [PHYS_W-1:0] prd
  );
    req_uop.bundle.pc = pc;
    req_uop.bundle.uop_class = UOP_JUMP;
    req_uop.bundle.branch_type = BR_JAL;
    req_uop.bundle.imm = imm;
    req_uop.bundle.pred_taken = pred_taken;
    req_uop.bundle.pred_target = pred_target;
    req_uop.rob_idx = rob_idx;
    req_uop.epoch = epoch;
    req_uop.bundle.uses_rd = 1'b1;
    req_uop.bundle.uses_rs1 = 1'b0;
    req_uop.bundle.uses_rs2 = 1'b0;
    req_uop.prd_new = prd;
    
    rs1_val = 0;
    rs2_val = 0;
    req_valid = 1;
    
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    req_valid = 0;
  endtask

  task automatic send_jalr(
    input logic [31:0] pc,
    input logic [31:0] imm,
    input logic [31:0] r1_val,
    input logic pred_taken,
    input logic [31:0] pred_target,
    input logic [ROB_W-1:0] rob_idx,
    input logic [1:0] epoch,
    input logic [PHYS_W-1:0] prd
  );
    req_uop.bundle.pc = pc;
    req_uop.bundle.uop_class = UOP_JUMP;
    req_uop.bundle.branch_type = BR_JALR;
    req_uop.bundle.imm = imm;
    req_uop.bundle.pred_taken = pred_taken;
    req_uop.bundle.pred_target = pred_target;
    req_uop.rob_idx = rob_idx;
    req_uop.epoch = epoch;
    req_uop.bundle.uses_rd = 1'b1;
    req_uop.bundle.uses_rs1 = 1'b1;
    req_uop.bundle.uses_rs2 = 1'b0;
    req_uop.prd_new = prd;
    
    rs1_val = r1_val;
    rs2_val = 0;
    req_valid = 1;
    
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    req_valid = 0;
  endtask

  task automatic wait_for_wb(
    output logic exp_valid,
    output logic exp_taken,
    output logic [31:0] exp_target,
    output logic exp_mispredict,
    output logic [31:0] exp_redirect,
    output logic [31:0] exp_wb_data
  );
    @(posedge clk);
    while (!wb_valid) @(posedge clk);
    
    exp_valid = br_valid;
    exp_taken = act_taken;
    exp_target = target_pc;
    exp_mispredict = mispredict;
    exp_redirect = redirect_pc;
    exp_wb_data = wb_data;
  endtask

  task automatic check_result(
    input string test_name,
    input logic exp_taken,
    input logic [31:0] exp_target,
    input logic exp_mispredict,
    input logic [31:0] exp_redirect,
    input logic [31:0] exp_wb_data
  );
    logic got_valid;
    logic got_taken;
    logic [31:0] got_target;
    logic got_mispredict;
    logic [31:0] got_redirect;
    logic [31:0] got_wb_data;
    
    wait_for_wb(got_valid, got_taken, got_target, got_mispredict, got_redirect, got_wb_data);
    
    test_count++;
    if (got_taken === exp_taken && 
        got_target === exp_target &&
        got_mispredict === exp_mispredict &&
        got_redirect === exp_redirect &&
        got_wb_data === exp_wb_data) begin
      $display("[PASS] %s", test_name);
      pass_count++;
    end else begin
      $display("[FAIL] %s", test_name);
      $display("  Expected: taken=%b, target=%h, mispredict=%b, redirect=%h, wb_data=%h",
               exp_taken, exp_target, exp_mispredict, exp_redirect, exp_wb_data);
      $display("  Got:      taken=%b, target=%h, mispredict=%b, redirect=%h, wb_data=%h",
               got_taken, got_target, got_mispredict, got_redirect, got_wb_data);
      fail_count++;
    end
  endtask

  // Main test sequence
  initial begin
    $display("========================================");
    $display("BRU Testbench Starting");
    $display("========================================");
    
    reset_dut();
    
    // ========================================
    // Test 1: BEQ - Equal (taken, correct prediction)
    // ========================================
    $display("\n--- Test 1: BEQ Equal, Correct Prediction ---");
    send_branch(32'h1000, BR_BEQ, 32'h100, 32'h5, 32'h5, 1'b1, 32'h1100, 4'd0, 2'd0, 1'b0, 6'd10);
    check_result("BEQ Equal, Correct Pred", 1'b1, 32'h1100, 1'b0, 32'h1100, 32'h1004);
    
    // ========================================
    // Test 2: BEQ - Not Equal (not taken, correct prediction)
    // ========================================
    $display("\n--- Test 2: BEQ Not Equal, Correct Prediction ---");
    send_branch(32'h2000, BR_BEQ, 32'h100, 32'h5, 32'h6, 1'b0, 32'h2004, 4'd1, 2'd0, 1'b0, 6'd11);
    check_result("BEQ Not Equal, Correct Pred", 1'b0, 32'h2100, 1'b0, 32'h2004, 32'h2004);
    
    // ========================================
    // Test 3: BEQ - Misprediction (predicted taken, actually not taken)
    // ========================================
    $display("\n--- Test 3: BEQ Misprediction (pred taken, act not taken) ---");
    send_branch(32'h3000, BR_BEQ, 32'h100, 32'h5, 32'h6, 1'b1, 32'h3100, 4'd2, 2'd0, 1'b0, 6'd12);
    check_result("BEQ Mispredict (T->NT)", 1'b0, 32'h3100, 1'b1, 32'h3004, 32'h3004);
    
    // ========================================
    // Test 4: BNE - Not Equal (taken)
    // ========================================
    $display("\n--- Test 4: BNE Not Equal ---");
    send_branch(32'h4000, BR_BNE, 32'h200, 32'h5, 32'h6, 1'b1, 32'h4200, 4'd3, 2'd0, 1'b0, 6'd13);
    check_result("BNE Not Equal", 1'b1, 32'h4200, 1'b0, 32'h4200, 32'h4004);
    
    // ========================================
    // Test 5: BLT - Less Than (signed)
    // ========================================
    $display("\n--- Test 5: BLT Less Than ---");
    send_branch(32'h5000, BR_BLT, 32'h80, 32'hFFFFFFF0, 32'h10, 1'b1, 32'h5080, 4'd4, 2'd0, 1'b0, 6'd14);
    check_result("BLT Less Than", 1'b1, 32'h5080, 1'b0, 32'h5080, 32'h5004);
    
    // ========================================
    // Test 6: BGE - Greater or Equal (signed)
    // ========================================
    $display("\n--- Test 6: BGE Greater or Equal ---");
    send_branch(32'h6000, BR_BGE, 32'h40, 32'h10, 32'h10, 1'b1, 32'h6040, 4'd5, 2'd0, 1'b0, 6'd15);
    check_result("BGE Greater or Equal", 1'b1, 32'h6040, 1'b0, 32'h6040, 32'h6004);
    
    // ========================================
    // Test 7: BLTU - Less Than Unsigned
    // ========================================
    $display("\n--- Test 7: BLTU Less Than Unsigned ---");
    send_branch(32'h7000, BR_BLTU, 32'h20, 32'h10, 32'hFFFFFFFF, 1'b1, 32'h7020, 4'd6, 2'd0, 1'b0, 6'd16);
    check_result("BLTU Less Than Unsigned", 1'b1, 32'h7020, 1'b0, 32'h7020, 32'h7004);
    
    // ========================================
    // Test 8: BGEU - Greater or Equal Unsigned
    // ========================================
    $display("\n--- Test 8: BGEU Greater or Equal Unsigned ---");
    send_branch(32'h8000, BR_BGEU, 32'h60, 32'hFFFFFFFF, 32'h10, 1'b1, 32'h8060, 4'd7, 2'd0, 1'b0, 6'd17);
    check_result("BGEU Greater or Equal Unsigned", 1'b1, 32'h8060, 1'b0, 32'h8060, 32'h8004);
    
    // ========================================
    // Test 9: JAL - Unconditional Jump
    // ========================================
    $display("\n--- Test 9: JAL Unconditional Jump ---");
    send_jal(32'h9000, 32'h400, 1'b1, 32'h9400, 4'd8, 2'd0, 6'd18);
    check_result("JAL Unconditional", 1'b1, 32'h9400, 1'b0, 32'h9400, 32'h9004);
    
    // ========================================
    // Test 10: JAL - Misprediction (wrong target)
    // ========================================
    $display("\n--- Test 10: JAL Wrong Target ---");
    send_jal(32'hA000, 32'h400, 1'b1, 32'hA300, 4'd9, 2'd0, 6'd19);
    check_result("JAL Wrong Target", 1'b1, 32'hA400, 1'b1, 32'hA400, 32'hA004);
    
    // ========================================
    // Test 11: JALR - Indirect Jump
    // ========================================
    $display("\n--- Test 11: JALR Indirect Jump ---");
    send_jalr(32'hB000, 32'h10, 32'hC000, 1'b1, 32'hC010, 4'd10, 2'd0, 6'd20);
    check_result("JALR Indirect", 1'b1, 32'hC010, 1'b0, 32'hC010, 32'hB004);
    
    // ========================================
    // Test 12: JALR - LSB clearing
    // ========================================
    $display("\n--- Test 12: JALR LSB Clearing ---");
    send_jalr(32'hC000, 32'h7, 32'h1000, 1'b1, 32'h1006, 4'd11, 2'd0, 6'd21);
    check_result("JALR LSB Clear", 1'b1, 32'h1006, 1'b0, 32'h1006, 32'hC004);
    
    // ========================================
    // Test 13: Backpressure test (wb_ready deasserted)
    // ========================================
    $display("\n--- Test 13: Backpressure Test ---");
    wb_ready = 0;
    send_branch(32'hD000, BR_BEQ, 32'h100, 32'h5, 32'h5, 1'b1, 32'hD100, 4'd12, 2'd0, 1'b0, 6'd22);
    repeat(3) @(posedge clk);
    if (!wb_valid) $display("[PASS] BRU holds result when wb_ready=0");
    else $display("[FAIL] BRU should not assert wb_valid when wb_ready=0");
    wb_ready = 1;
    @(posedge clk);
    
    // ========================================
    // Test 14: Pipeline test (back-to-back operations)
    // ========================================
    $display("\n--- Test 14: Back-to-back Operations ---");
    fork
      begin
        send_branch(32'hE000, BR_BNE, 32'h50, 32'h1, 32'h2, 1'b1, 32'hE050, 4'd13, 2'd0, 1'b0, 6'd23);
      end
      begin
        @(posedge clk);
        @(posedge clk);
        send_branch(32'hF000, BR_BEQ, 32'h100, 32'h7, 32'h7, 1'b1, 32'hF100, 4'd14, 2'd0, 1'b0, 6'd24);
      end
    join
    repeat(5) @(posedge clk);
    
    // ========================================
    // Summary
    // ========================================
    repeat(2) @(posedge clk);
    $display("\n========================================");
    $display("Test Summary");
    $display("========================================");
    $display("Total Tests: %0d", test_count);
    $display("Passed:      %0d", pass_count);
    $display("Failed:      %0d", fail_count);
    $display("========================================");
    
    if (fail_count == 0)
      $display("ALL TESTS PASSED!");
    else
      $display("SOME TESTS FAILED!");
    
    $finish;
  end

  // Timeout watchdog
  initial begin
    #100000;
    $display("ERROR: Testbench timeout!");
    $finish;
  end

  // Optional: Waveform dumping
  initial begin
    $dumpfile("bru_tb.vcd");
    $dumpvars(0, BRU_tb);
  end

endmodule