`timescale 1ns/1ps
`include "defines.svh"

module tb_fetch;

  // -------------------------
  // Clock / reset
  // -------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk; // 100MHz

  logic rst_n;
  
  // -------------------------
  // DUT I/O
  // -------------------------
  logic        redirect_valid;
  logic [31:0] redirect_pc;

  logic        update_valid;
  logic [31:0] update_pc;
  logic        update_taken;
  logic [31:0] update_target;
  logic        update_mispredict;

  logic        decode_ready;
  logic        decode_valid;
  decoded_bundle_t decoded_bundle_fields;

  imem_if imem_inf ();

  // -------------------------
  // Instantiate fetch (PC+imem+decode)
  // -------------------------
  fetch dut (
    .clk(clk),
    .rst_n(rst_n),
    .redirect_valid(redirect_valid),
    .redirect_pc(redirect_pc),
    .update_valid(update_valid),
    .update_pc(update_pc),
    .update_taken(update_taken),
    .update_target(update_target),
    .update_mispredict(update_mispredict),
    .decode_ready(decode_ready),
    .decode_valid(decode_valid),
    .decoded_bundle_fields(decoded_bundle_fields),
    .imem_m(imem_inf.master)
  );

  imem imem_inst (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(imem_inf.slave.imem_req_valid),
    .req_ready(imem_inf.slave.imem_req_ready),
    .req_addr(imem_inf.slave.imem_req_addr),
    .resp_valid(imem_inf.slave.imem_resp_valid),
    .resp_ready(imem_inf.slave.imem_resp_ready),
    .resp_inst(imem_inf.slave.imem_resp_inst)
  );

  defparam imem_inst.HEXFILE = "prog.hex";

  // -------------------------
  // Test control
  // -------------------------
  integer test_num = 0;
  integer errors = 0;
  
  // -------------------------
  // Waveform dump
  // -------------------------
  initial begin
    $dumpfile("tb_fetch_comprehensive.vcd");
    $dumpvars(0);
  end

  // -------------------------
  // Trace output
  // -------------------------
  integer f;
  initial begin
    f = $fopen("fetch_trace_comprehensive.log", "w");
    if (f == 0) $fatal(1, "Failed to open trace log");
  end

  wire out_fire = decode_valid && decode_ready;

  always_ff @(posedge clk) begin
    if (rst_n && out_fire) begin
      $fwrite(f, "T=%0t PC=%08x class=%0d op=%0d predT=%0d predTGT=%08x\n",
              $time, decoded_bundle_fields.pc, decoded_bundle_fields.uop_class,
              decoded_bundle_fields.op,
              decoded_bundle_fields.pred_taken, decoded_bundle_fields.pred_target);
    end
    if (rst_n && redirect_valid) begin
      $fwrite(f, "T=%0t REDIRECT to=%08x\n", $time, redirect_pc);
    end
    if (rst_n && update_valid) begin
      $fwrite(f, "T=%0t UPDATE pc=%08x taken=%0d tgt=%08x mis=%0d\n",
              $time, update_pc, update_taken, update_target, update_mispredict);
    end
  end

  // -------------------------
  // Helper tasks
  // -------------------------
  task automatic reset_dut();
    begin
      rst_n = 1'b0;
      redirect_valid = 1'b0;
      redirect_pc = 32'b0;
      update_valid = 1'b0;
      update_pc = 32'b0;
      update_taken = 1'b0;
      update_target = 32'b0;
      update_mispredict = 1'b0;
      decode_ready = 1'b1;
      repeat (5) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
      errors = 0;
    end
  endtask

  task automatic do_redirect(input logic [31:0] tgt);
    begin
      redirect_valid = 1'b1;
      redirect_pc = tgt;
      @(posedge clk);
      redirect_valid = 1'b0;
      redirect_pc = 32'b0;
    end
  endtask

  task automatic do_predictor_update(
    input logic [31:0] pc,
    input logic taken,
    input logic [31:0] target,
    input logic mispredict
  );
    begin
      @(posedge clk);
      update_valid <= 1'b1;
      update_pc <= pc;
      update_taken <= taken;
      update_target <= target;
      update_mispredict <= mispredict;
      @(posedge clk);
      update_valid <= 1'b0;
    end
  endtask

  task automatic wait_for_pc(input logic [31:0] expected_pc, input int timeout);
    begin
      int cycles;
      cycles = 0;
      while (cycles < timeout) begin
        if (out_fire && decoded_bundle_fields.pc == expected_pc) begin
          $display("  Found PC=%08x at T=%0t", expected_pc, $time);
          return;
        end
        @(posedge clk);
        cycles = cycles + 1;
      end
      $display("  ERROR: Timeout waiting for PC=%08x", expected_pc);
      errors = errors + 1;
    end
  endtask

  task automatic apply_backpressure(input int cycles);
    begin
      int i;
      decode_ready = 1'b0;
      for (i = 0; i < cycles; i = i + 1) begin
        @(posedge clk);
      end
      decode_ready = 1'b1;
    end
  endtask

  // -------------------------
  // Test 1: Basic sequential fetch from reset
  // -------------------------
  task automatic test_1_sequential_fetch();
    begin
      test_num = 1;
      $display("\n=== TEST 1: Sequential Fetch from Reset ===");
      reset_dut();
      
      wait_for_pc(32'h00000000, 20);
      wait_for_pc(32'h00000004, 20);
      wait_for_pc(32'h00000008, 20);
      wait_for_pc(32'h0000000C, 20);
      
      $display("TEST 1: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Test 2: Simple redirect
  // -------------------------
  task automatic test_2_simple_redirect();
    begin
      test_num = 2;
      $display("\n=== TEST 2: Simple Redirect ===");
      reset_dut();
      
      wait_for_pc(32'h00000000, 20);
      wait_for_pc(32'h00000004, 20);
      
      $display("  Redirecting to 0x20...");
      do_redirect(32'h00000020);
      
      wait_for_pc(32'h00000020, 20);
      wait_for_pc(32'h00000024, 20);
      
      $display("TEST 2: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Test 3: Multiple rapid redirects
  // -------------------------
  task automatic test_3_rapid_redirects();
    begin
      test_num = 3;
      $display("\n=== TEST 3: Rapid Redirects ===");
      reset_dut();
      
      wait_for_pc(32'h00000000, 20);
      
      do_redirect(32'h00000010);
      wait_for_pc(32'h00000010, 20);
      
      do_redirect(32'h00000030);
      wait_for_pc(32'h00000030, 20);
      
      do_redirect(32'h00000050);
      wait_for_pc(32'h00000050, 20);
      
      $display("TEST 3: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Test 4: Backpressure handling
  // -------------------------
  task automatic test_4_backpressure();
    begin
      test_num = 4;
      $display("\n=== TEST 4: Decode Backpressure ===");
      reset_dut();
      
      wait_for_pc(32'h00000000, 20);
      
      $display("  Applying backpressure...");
      apply_backpressure(10);
      
      wait_for_pc(32'h00000004, 30);
      wait_for_pc(32'h00000008, 30);
      
      $display("TEST 4: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Test 5: Redirect during backpressure
  // -------------------------
  task automatic test_5_redirect_during_backpressure();
    begin
      int i;
      test_num = 5;
      $display("\n=== TEST 5: Redirect During Backpressure ===");
      reset_dut();
      
      wait_for_pc(32'h00000000, 20);
      
      decode_ready = 1'b0;
      for (i = 0; i < 3; i = i + 1) @(posedge clk);
      
      $display("  Redirecting during backpressure...");
      do_redirect(32'h00000040);
      
      for (i = 0; i < 5; i = i + 1) @(posedge clk);
      decode_ready = 1'b1;
      
      wait_for_pc(32'h00000040, 20);
      wait_for_pc(32'h00000044, 20);
      
      $display("TEST 5: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Test 6: Branch predictor training
  // -------------------------
  task automatic test_6_predictor_training();
    begin
      int i;
      test_num = 6;
      $display("\n=== TEST 6: Branch Predictor Training ===");
      reset_dut();
      
      $display("  Training: 0x10 -> 0x30 (taken)");
      do_predictor_update(32'h00000010, 1'b1, 32'h00000030, 1'b0);
      
      do_redirect(32'h00000008);
      wait_for_pc(32'h00000008, 20);
      wait_for_pc(32'h0000000C, 20);
      wait_for_pc(32'h00000010, 20);
      
      for (i = 0; i < 5; i = i + 1) @(posedge clk);
      
      $display("  Note: Check trace for pred_taken/pred_target");
      $display("TEST 6: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Test 7: Check no duplicate requests - THE CRITICAL TEST!
  // -------------------------
  task automatic test_7_no_duplicate_requests();
    begin
      logic [31:0] last_req_addr;
      logic last_req_valid;
      int req_count;
      int cycle_count;
      
      test_num = 7;
      
      $display("\n=== TEST 7: No Duplicate Requests (CRITICAL) ===");
      reset_dut();
      
      last_req_addr = 32'hFFFFFFFF;
      last_req_valid = 1'b0;
      req_count = 0;
      cycle_count = 0;
      
      // Monitor requests for 50 cycles
      while (cycle_count < 50) begin
        @(posedge clk);
        if (imem_inf.slave.imem_req_valid && imem_inf.slave.imem_req_ready) begin
          if (last_req_valid && (imem_inf.slave.imem_req_addr == last_req_addr)) begin
            $display("  ERROR: Duplicate consecutive request for addr=%08x at T=%0t", 
                     imem_inf.slave.imem_req_addr, $time);
            errors = errors + 1;
          end
          $display("  REQ: addr=%08x at T=%0t", imem_inf.slave.imem_req_addr, $time);
          last_req_addr = imem_inf.slave.imem_req_addr;
          last_req_valid = 1'b1;
          req_count = req_count + 1;
        end
        cycle_count = cycle_count + 1;
      end
      
      $display("  Captured %0d requests in 50 cycles", req_count);
      
      if (errors == 0)
        $display("  No duplicate requests detected - PASS");
      
      $display("TEST 7: %s\n", errors == 0 ? "PASSED" : "FAILED");
    end
  endtask

  // -------------------------
  // Main test sequence
  // -------------------------
  integer total_errors;
  initial begin
    int i;
    total_errors = 0;
    
    test_1_sequential_fetch();
    total_errors = total_errors + errors;
    
    test_2_simple_redirect();
    total_errors = total_errors + errors;
    
    test_3_rapid_redirects();
    total_errors = total_errors + errors;
    
    test_4_backpressure();
    total_errors = total_errors + errors;
    
    test_5_redirect_during_backpressure();
    total_errors = total_errors + errors;
    
    test_6_predictor_training();
    total_errors = total_errors + errors;
    
    test_7_no_duplicate_requests();
    total_errors = total_errors + errors;
    
    // Summary
    for (i = 0; i < 10; i = i + 1) @(posedge clk);
    $display("\n==================================================");
    $display("TOTAL ERRORS: %0d", total_errors);
    if (total_errors == 0)
      $display("ALL TESTS PASSED!");
    else
      $display("SOME TESTS FAILED!");
    $display("==================================================\n");
    
    $fclose(f);
    $finish;
  end

  // Timeout safety
  initial begin
    #100000;
    $display("TIMEOUT - Test took too long");
    $finish;
  end

endmodule