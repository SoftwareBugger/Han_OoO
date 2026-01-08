`timescale 1ns/1ps
`include "defines.svh"

module ALU_tb;

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
  logic [31:0] wb_pc;
  logic        wb_uses_rd;
  logic [ROB_W-1:0]  wb_rob_idx;
  logic [PHYS_W-1:0] wb_prd_new;
  logic [1:0]  wb_epoch;
  logic [31:0] wb_data;

  // DUT instantiation
  ALU dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_uop(req_uop),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_pc(wb_pc),
    .wb_uses_rd(wb_uses_rd),
    .wb_rob_idx(wb_rob_idx),
    .wb_prd_new(wb_prd_new),
    .wb_epoch(wb_epoch),
    .wb_data(wb_data)
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

  task automatic send_alu_op(
    input logic [31:0] pc,
    input uop_op_e op,
    input src_sel_e src1_sel,
    input src_sel_e src2_sel,
    input logic [31:0] r1_val,
    input logic [31:0] r2_val,
    input logic [31:0] imm_val,
    input logic uses_rd_in,
    input logic [ROB_W-1:0] rob_idx,
    input logic [1:0] epoch,
    input logic [PHYS_W-1:0] prd
  );
    req_uop.bundle.pc = pc;
    req_uop.bundle.uop_class = UOP_ALU;
    req_uop.bundle.op = op;
    req_uop.bundle.src1_select = src1_sel;
    req_uop.bundle.src2_select = src2_sel;
    req_uop.bundle.imm = imm_val;
    req_uop.bundle.uses_rd = uses_rd_in;
    req_uop.bundle.uses_rs1 = (src1_sel == SRC_RS1);
    req_uop.bundle.uses_rs2 = (src2_sel == SRC_RS2);
    req_uop.rob_idx = rob_idx;
    req_uop.epoch = epoch;
    req_uop.prd_new = prd;
    
    rs1_val = r1_val;
    rs2_val = r2_val;
    req_valid = 1;
    
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    req_valid = 0;
  endtask

  task automatic wait_for_wb(
    output logic [31:0] result
  );
    @(posedge clk);
    while (!wb_valid) @(posedge clk);
    result = wb_data;
  endtask

  task automatic check_result(
    input string test_name,
    input logic [31:0] expected
  );
    logic [31:0] got_result;
    
    wait_for_wb(got_result);
    
    test_count++;
    if (got_result === expected) begin
      $display("[PASS] %s: Expected=%h, Got=%h", test_name, expected, got_result);
      pass_count++;
    end else begin
      $display("[FAIL] %s: Expected=%h, Got=%h", test_name, expected, got_result);
      fail_count++;
    end
  endtask

  // Main test sequence
  initial begin
    $display("========================================");
    $display("ALU Testbench Starting");
    $display("========================================");
    
    reset_dut();
    
    // ========================================
    // Test 1: ADD - Register-Register
    // ========================================
    $display("\n--- Test 1: ADD (R-type) ---");
    send_alu_op(32'h1000, OP_ADD, SRC_RS1, SRC_RS2, 32'd100, 32'd50, 32'h0, 1'b1, 4'd0, 2'd0, 6'd10);
    check_result("ADD 100+50", 32'd150);
    
    // ========================================
    // Test 2: ADDI - Add Immediate
    // ========================================
    $display("\n--- Test 2: ADDI ---");
    send_alu_op(32'h1004, OP_ADDI, SRC_RS1, SRC_IMM, 32'd100, 32'h0, 32'd25, 1'b1, 4'd1, 2'd0, 6'd11);
    check_result("ADDI 100+25", 32'd125);
    
    // ========================================
    // Test 3: SUB - Subtraction
    // ========================================
    $display("\n--- Test 3: SUB ---");
    send_alu_op(32'h1008, OP_SUB, SRC_RS1, SRC_RS2, 32'd100, 32'd30, 32'h0, 1'b1, 4'd2, 2'd0, 6'd12);
    check_result("SUB 100-30", 32'd70);
    
    // ========================================
    // Test 4: AND - Bitwise AND
    // ========================================
    $display("\n--- Test 4: AND ---");
    send_alu_op(32'h100C, OP_AND, SRC_RS1, SRC_RS2, 32'hFF00FF00, 32'h0F0F0F0F, 32'h0, 1'b1, 4'd3, 2'd0, 6'd13);
    check_result("AND", 32'h0F000F00);
    
    // ========================================
    // Test 5: ANDI - Bitwise AND Immediate
    // ========================================
    $display("\n--- Test 5: ANDI ---");
    send_alu_op(32'h1010, OP_ANDI, SRC_RS1, SRC_IMM, 32'hFFFFFFFF, 32'h0, 32'h00FF, 1'b1, 4'd4, 2'd0, 6'd14);
    check_result("ANDI", 32'h000000FF);
    
    // ========================================
    // Test 6: OR - Bitwise OR
    // ========================================
    $display("\n--- Test 6: OR ---");
    send_alu_op(32'h1014, OP_OR, SRC_RS1, SRC_RS2, 32'hF0F0F0F0, 32'h0F0F0F0F, 32'h0, 1'b1, 4'd5, 2'd0, 6'd15);
    check_result("OR", 32'hFFFFFFFF);
    
    // ========================================
    // Test 7: ORI - Bitwise OR Immediate
    // ========================================
    $display("\n--- Test 7: ORI ---");
    send_alu_op(32'h1018, OP_ORI, SRC_RS1, SRC_IMM, 32'h12345678, 32'h0, 32'h00FF, 1'b1, 4'd6, 2'd0, 6'd16);
    check_result("ORI", 32'h123456FF);
    
    // ========================================
    // Test 8: XOR - Bitwise XOR
    // ========================================
    $display("\n--- Test 8: XOR ---");
    send_alu_op(32'h101C, OP_XOR, SRC_RS1, SRC_RS2, 32'hAAAAAAAA, 32'h55555555, 32'h0, 1'b1, 4'd7, 2'd0, 6'd17);
    check_result("XOR", 32'hFFFFFFFF);
    
    // ========================================
    // Test 9: XORI - Bitwise XOR Immediate
    // ========================================
    $display("\n--- Test 9: XORI ---");
    send_alu_op(32'h1020, OP_XORI, SRC_RS1, SRC_IMM, 32'h000000FF, 32'h0, 32'h00FF, 1'b1, 4'd8, 2'd0, 6'd18);
    check_result("XORI", 32'h00000000);
    
    // ========================================
    // Test 10: SLL - Shift Left Logical
    // ========================================
    $display("\n--- Test 10: SLL ---");
    send_alu_op(32'h1024, OP_SLL, SRC_RS1, SRC_RS2, 32'h00000001, 32'd4, 32'h0, 1'b1, 4'd9, 2'd0, 6'd19);
    check_result("SLL 1<<4", 32'h00000010);
    
    // ========================================
    // Test 11: SLLI - Shift Left Logical Immediate
    // ========================================
    $display("\n--- Test 11: SLLI ---");
    send_alu_op(32'h1028, OP_SLLI, SRC_RS1, SRC_IMM, 32'h00000001, 32'h0, 32'd8, 1'b1, 4'd10, 2'd0, 6'd20);
    check_result("SLLI 1<<8", 32'h00000100);
    
    // ========================================
    // Test 12: SRL - Shift Right Logical
    // ========================================
    $display("\n--- Test 12: SRL ---");
    send_alu_op(32'h102C, OP_SRL, SRC_RS1, SRC_RS2, 32'h80000000, 32'd4, 32'h0, 1'b1, 4'd11, 2'd0, 6'd21);
    check_result("SRL 0x80000000>>4", 32'h08000000);
    
    // ========================================
    // Test 13: SRLI - Shift Right Logical Immediate
    // ========================================
    $display("\n--- Test 13: SRLI ---");
    send_alu_op(32'h1030, OP_SRLI, SRC_RS1, SRC_IMM, 32'hFFFF0000, 32'h0, 32'd8, 1'b1, 4'd12, 2'd0, 6'd22);
    check_result("SRLI 0xFFFF0000>>8", 32'h00FFFF00);
    
    // ========================================
    // Test 14: SRA - Shift Right Arithmetic
    // ========================================
    $display("\n--- Test 14: SRA ---");
    send_alu_op(32'h1034, OP_SRA, SRC_RS1, SRC_RS2, 32'h80000000, 32'd4, 32'h0, 1'b1, 4'd13, 2'd0, 6'd23);
    check_result("SRA (signed) 0x80000000>>4", 32'hF8000000);
    
    // ========================================
    // Test 15: SRAI - Shift Right Arithmetic Immediate
    // ========================================
    $display("\n--- Test 15: SRAI ---");
    send_alu_op(32'h1038, OP_SRAI, SRC_RS1, SRC_IMM, 32'hFFFFFF00, 32'h0, 32'd4, 1'b1, 4'd14, 2'd0, 6'd24);
    check_result("SRAI (signed) 0xFFFFFF00>>4", 32'hFFFFFFF0);
    
    // ========================================
    // Test 16: SLT - Set Less Than (signed)
    // ========================================
    $display("\n--- Test 16: SLT (true case) ---");
    send_alu_op(32'h103C, OP_SLT, SRC_RS1, SRC_RS2, 32'hFFFFFFF0, 32'd10, 32'h0, 1'b1, 4'd15, 2'd0, 6'd25);
    check_result("SLT -16 < 10", 32'd1);
    
    $display("\n--- Test 17: SLT (false case) ---");
    send_alu_op(32'h1040, OP_SLT, SRC_RS1, SRC_RS2, 32'd10, 32'hFFFFFFF0, 32'h0, 1'b1, 4'd16, 2'd0, 6'd26);
    check_result("SLT 10 < -16", 32'd0);
    
    // ========================================
    // Test 18: SLTI - Set Less Than Immediate (signed)
    // ========================================
    $display("\n--- Test 18: SLTI ---");
    send_alu_op(32'h1044, OP_SLTI, SRC_RS1, SRC_IMM, 32'd5, 32'h0, 32'd10, 1'b1, 4'd17, 2'd0, 6'd27);
    check_result("SLTI 5 < 10", 32'd1);
    
    // ========================================
    // Test 19: SLTU - Set Less Than Unsigned
    // ========================================
    $display("\n--- Test 19: SLTU ---");
    send_alu_op(32'h1048, OP_SLTU, SRC_RS1, SRC_RS2, 32'd10, 32'hFFFFFFFF, 32'h0, 1'b1, 4'd18, 2'd0, 6'd28);
    check_result("SLTU 10 < 0xFFFFFFFF", 32'd1);
    
    // ========================================
    // Test 20: SLTIU - Set Less Than Immediate Unsigned
    // ========================================
    $display("\n--- Test 20: SLTIU ---");
    send_alu_op(32'h104C, OP_SLTIU, SRC_RS1, SRC_IMM, 32'hFFFFFFFF, 32'h0, 32'd10, 1'b1, 4'd19, 2'd0, 6'd29);
    check_result("SLTIU 0xFFFFFFFF < 10", 32'd0);
    
    // ========================================
    // Test 21: LUI - Load Upper Immediate
    // ========================================
    $display("\n--- Test 21: LUI ---");
    send_alu_op(32'h1050, OP_LUI, SRC_ZERO, SRC_IMM, 32'h0, 32'h0, 32'h12345000, 1'b1, 4'd20, 2'd0, 6'd30);
    check_result("LUI 0x12345000", 32'h12345000);
    
    // ========================================
    // Test 22: AUIPC - Add Upper Immediate to PC
    // ========================================
    $display("\n--- Test 22: AUIPC ---");
    send_alu_op(32'h1054, OP_AUIPC, SRC_RS1, SRC_IMM, 32'h1054, 32'h0, 32'h1000, 1'b1, 4'd21, 2'd0, 6'd31);
    check_result("AUIPC 0x1054+0x1000", 32'h2054);
    
    // ========================================
    // Test 23: Edge Case - Add with overflow
    // ========================================
    $display("\n--- Test 23: ADD Overflow ---");
    send_alu_op(32'h1058, OP_ADD, SRC_RS1, SRC_RS2, 32'hFFFFFFFF, 32'h00000001, 32'h0, 1'b1, 4'd22, 2'd0, 6'd32);
    check_result("ADD overflow", 32'h00000000);
    
    // ========================================
    // Test 24: Edge Case - Shift by 0
    // ========================================
    $display("\n--- Test 24: SLLI by 0 ---");
    send_alu_op(32'h105C, OP_SLLI, SRC_RS1, SRC_IMM, 32'h12345678, 32'h0, 32'd0, 1'b1, 4'd23, 2'd0, 6'd33);
    check_result("SLLI by 0", 32'h12345678);
    
    // ========================================
    // Test 25: Edge Case - Shift by 31
    // ========================================
    $display("\n--- Test 25: SLLI by 31 ---");
    send_alu_op(32'h1060, OP_SLLI, SRC_RS1, SRC_IMM, 32'h00000001, 32'h0, 32'd31, 1'b1, 4'd24, 2'd0, 6'd34);
    check_result("SLLI 1<<31", 32'h80000000);
    
    // ========================================
    // Test 26: Backpressure test (wb_ready deasserted)
    // ========================================
    $display("\n--- Test 26: Backpressure Test ---");
    wb_ready = 0;
    send_alu_op(32'h1064, OP_ADD, SRC_RS1, SRC_RS2, 32'd10, 32'd20, 32'h0, 1'b1, 4'd25, 2'd0, 6'd35);
    repeat(3) @(posedge clk);
    if (!wb_valid) begin
      $display("[PASS] ALU holds result when wb_ready=0");
    end else begin
      $display("[FAIL] ALU should not assert wb_valid when wb_ready=0");
    end
    wb_ready = 1;
    check_result("Backpressure ADD 10+20", 32'd30);
    
    // ========================================
    // Test 27: Back-to-back operations
    // ========================================
    $display("\n--- Test 27: Back-to-back Operations ---");
    fork
      begin
        send_alu_op(32'h1068, OP_ADD, SRC_RS1, SRC_RS2, 32'd1, 32'd2, 32'h0, 1'b1, 4'd26, 2'd0, 6'd36);
      end
      begin
        @(posedge clk);
        @(posedge clk);
        send_alu_op(32'h106C, OP_SUB, SRC_RS1, SRC_RS2, 32'd10, 32'd3, 32'h0, 1'b1, 4'd27, 2'd0, 6'd37);
      end
    join
    
    // Wait for both results
    check_result("Back-to-back 1st: 1+2", 32'd3);
    check_result("Back-to-back 2nd: 10-3", 32'd7);
    
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
//   initial begin
//     #100000;
//     $display("ERROR: Testbench timeout!");
//     $finish;
//   end

//   // Optional: Waveform dumping
//   initial begin
//     $dumpfile("alu_tb.vcd");
//     $dumpvars(0, ALU_tb);
//   end

endmodule