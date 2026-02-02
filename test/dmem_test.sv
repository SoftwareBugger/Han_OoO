`timescale 1ns/1ps
`include "defines.svh"
module dmem_comparison_tb;

    // ================================================================
    // Parameters
    // ================================================================
    parameter int MEM_SIZE_KB = 64;
    parameter int LD_LATENCY  = 3;
    parameter int ST_LATENCY  = 3;
    parameter int LDTAG_W     = 4;
    parameter int CLK_PERIOD  = 10;

    // ================================================================
    // Clock and Reset
    // ================================================================
    logic clk;
    logic rst_n;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ================================================================
    // Interfaces for both DUTs
    // ================================================================
    dmem_if #(.LDTAG_W(LDTAG_W)) dmem_model_if(clk, rst_n);
    dmem_if #(.LDTAG_W(LDTAG_W)) dmem_ip_if(clk, rst_n);

    // ================================================================
    // Instantiate Both Memory Modules
    // ================================================================
    dmem_model #(
        .MEM_SIZE_KB(MEM_SIZE_KB),
        .LD_LATENCY(LD_LATENCY),
        .ST_LATENCY(ST_LATENCY),
        .LDTAG_W(LDTAG_W)
    ) u_dmem_model (
        .clk(clk),
        .rst_n(rst_n),
        .dmem(dmem_model_if.slave)
    );

    dmem_ip #(
        .MEM_SIZE_KB(MEM_SIZE_KB),
        .LD_LATENCY(LD_LATENCY),
        .ST_LATENCY(ST_LATENCY),
        .LDTAG_W(LDTAG_W)
    ) u_dmem_ip (
        .clk(clk),
        .rst_n(rst_n),
        .dmem(dmem_ip_if.slave)
    );

    // ================================================================
    // Test Statistics
    // ================================================================
    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;
    
    // ================================================================
    // Test Variables
    // ================================================================
    logic [31:0] addr_var;
    logic [63:0] data_var;
    logic [7:0] strb_var;
    logic [LDTAG_W-1:0] tag_var;
    int i;

    // ================================================================
    // Helper Tasks
    // ================================================================
    
    // Task to drive identical load requests to both modules
    task automatic drive_load(
        input logic [31:0] addr,
        input logic [LDTAG_W-1:0] tag
    );
        @(posedge clk);
        // Drive model
        dmem_model_if.ld_valid = 1'b1;
        dmem_model_if.ld_addr = addr;
        dmem_model_if.ld_tag = tag;
        
        // Drive IP
        dmem_ip_if.ld_valid = 1'b1;
        dmem_ip_if.ld_addr = addr;
        dmem_ip_if.ld_tag = tag;
        
        // Wait for both to accept (ready & valid handshake)
        @(posedge clk);
        while (!(dmem_model_if.ld_ready && dmem_model_if.ld_valid) || 
               !(dmem_ip_if.ld_ready && dmem_ip_if.ld_valid)) begin
            @(posedge clk);
        end
        
        // Deassert valid after handshake
        @(posedge clk);
        dmem_model_if.ld_valid = 1'b0;
        dmem_ip_if.ld_valid = 1'b0;
        
        $display("[%0t] Load request sent: addr=0x%h, tag=%0d", $time, addr, tag);
    endtask

    // Task to drive identical store requests to both modules
    task automatic drive_store(
        input logic [31:0] addr,
        input logic [63:0] wdata,
        input logic [7:0] wstrb
    );
        @(posedge clk);
        // Drive model
        dmem_model_if.st_valid = 1'b1;
        dmem_model_if.st_addr = addr;
        dmem_model_if.st_wdata = wdata;
        dmem_model_if.st_wstrb = wstrb;
        
        // Drive IP
        dmem_ip_if.st_valid = 1'b1;
        dmem_ip_if.st_addr = addr;
        dmem_ip_if.st_wdata = wdata;
        dmem_ip_if.st_wstrb = wstrb;
        
        // Wait for both to accept (ready & valid handshake)
        @(posedge clk);
        while (!(dmem_model_if.st_ready && dmem_model_if.st_valid) || 
               !(dmem_ip_if.st_ready && dmem_ip_if.st_valid)) begin
            @(posedge clk);
        end
        
        // Deassert valid after handshake
        @(posedge clk);
        dmem_model_if.st_valid = 1'b0;
        dmem_ip_if.st_valid = 1'b0;
        
        $display("[%0t] Store request sent: addr=0x%h, data=0x%h, strb=0b%b", 
                 $time, addr, wdata, wstrb);
    endtask

    // Task to wait for and compare load responses
    task automatic check_load_response(
        input logic [31:0] expected_addr,
        input logic [LDTAG_W-1:0] expected_tag
    );
        logic [63:0] model_data, ip_data;
        logic [LDTAG_W-1:0] model_tag, ip_tag;
        logic model_err, ip_err;
        int model_cycles, ip_cycles;
        
        model_cycles = 0;
        ip_cycles = 0;
        
        // Set ready signals
        dmem_model_if.ld_resp_ready = 1'b1;
        dmem_ip_if.ld_resp_ready = 1'b1;
        
        // Wait for model response
        fork
            begin
                while (!dmem_model_if.ld_resp_valid) begin
                    @(posedge clk);
                    model_cycles++;
                end
                model_data = dmem_model_if.ld_resp_data;
                model_tag = dmem_model_if.ld_resp_tag;
                model_err = dmem_model_if.ld_resp_err;
                @(posedge clk);
            end
            begin
                while (!dmem_ip_if.ld_resp_valid) begin
                    @(posedge clk);
                    ip_cycles++;
                end
                ip_data = dmem_ip_if.ld_resp_data;
                ip_tag = dmem_ip_if.ld_resp_tag;
                ip_err = dmem_ip_if.ld_resp_err;
                @(posedge clk);
            end
        join
        
        dmem_model_if.ld_resp_ready = 1'b0;
        dmem_ip_if.ld_resp_ready = 1'b0;
        
        total_tests++;
        
        // Compare responses
        if (model_data === ip_data && 
            model_tag === ip_tag && 
            model_err === ip_err &&
            model_cycles === ip_cycles) begin
            passed_tests++;
            $display("[%0t] ✓ PASS Load Response: addr=0x%h, tag=%0d, data=0x%h, cycles=%0d", 
                     $time, expected_addr, expected_tag, model_data, model_cycles);
        end else begin
            failed_tests++;
            $display("[%0t] ✗ FAIL Load Response: addr=0x%h, tag=%0d", 
                     $time, expected_addr, expected_tag);
            $display("         MODEL: data=0x%h, tag=%0d, err=%0b, cycles=%0d", 
                     model_data, model_tag, model_err, model_cycles);
            $display("         IP:    data=0x%h, tag=%0d, err=%0b, cycles=%0d", 
                     ip_data, ip_tag, ip_err, ip_cycles);
        end
    endtask

    // Task to wait for and compare store responses
    task automatic check_store_response(
        input logic [31:0] expected_addr
    );
        int model_cycles, ip_cycles;
        
        model_cycles = 0;
        ip_cycles = 0;
        
        // Set ready signals
        dmem_model_if.st_resp_ready = 1'b1;
        dmem_ip_if.st_resp_ready = 1'b1;
        
        // Wait for both responses
        fork
            begin
                while (!dmem_model_if.st_resp_valid) begin
                    @(posedge clk);
                    model_cycles++;
                end
                @(posedge clk);
            end
            begin
                while (!dmem_ip_if.st_resp_valid) begin
                    @(posedge clk);
                    ip_cycles++;
                end
                @(posedge clk);
            end
        join
        
        dmem_model_if.st_resp_ready = 1'b0;
        dmem_ip_if.st_resp_ready = 1'b0;
        
        total_tests++;
        
        if (model_cycles === ip_cycles) begin
            passed_tests++;
            $display("[%0t] ✓ PASS Store Response: addr=0x%h, cycles=%0d", 
                     $time, expected_addr, model_cycles);
        end else begin
            failed_tests++;
            $display("[%0t] ✗ FAIL Store Response: addr=0x%h", $time, expected_addr);
            $display("         MODEL cycles=%0d, IP cycles=%0d", model_cycles, ip_cycles);
        end
    endtask

    // ================================================================
    // Main Test Sequence
    // ================================================================
    initial begin
        // Initialize signals
        dmem_model_if.ld_valid = 1'b0;
        dmem_model_if.ld_addr = '0;
        dmem_model_if.ld_tag = '0;
        dmem_model_if.ld_resp_ready = 1'b0;
        dmem_model_if.st_valid = 1'b0;
        dmem_model_if.st_addr = '0;
        dmem_model_if.st_wdata = '0;
        dmem_model_if.st_wstrb = '0;
        dmem_model_if.st_resp_ready = 1'b0;

        dmem_ip_if.ld_valid = 1'b0;
        dmem_ip_if.ld_addr = '0;
        dmem_ip_if.ld_tag = '0;
        dmem_ip_if.ld_resp_ready = 1'b0;
        dmem_ip_if.st_valid = 1'b0;
        dmem_ip_if.st_addr = '0;
        dmem_ip_if.st_wdata = '0;
        dmem_ip_if.st_wstrb = '0;
        dmem_ip_if.st_resp_ready = 1'b0;

        // Reset
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("\n========================================");
        $display("Starting Memory Comparison Tests");
        $display("========================================\n");

        // ================================================================
        // Test 1: Basic Store and Load
        // ================================================================
        $display("\n--- Test 1: Basic Store and Load ---");
        drive_store(32'h0000_0000, 64'hDEAD_BEEF_CAFE_BABE, 8'b1111_1111);
        check_store_response(32'h0000_0000);
        
        drive_load(32'h0000_0000, 4'd1);
        check_load_response(32'h0000_0000, 4'd1);

        // ================================================================
        // Test 2: Multiple Stores with Different Byte Enables
        // ================================================================
        $display("\n--- Test 2: Byte-Enable Testing ---");
        
        // Write full 64-bit word
        drive_store(32'h0000_0008, 64'h1111_2222_3333_4444, 8'b1111_1111);
        check_store_response(32'h0000_0008);
        
        // Modify lower 32 bits
        drive_store(32'h0000_0008, 64'hXXXX_XXXX_AAAA_BBBB, 8'b0000_1111);
        check_store_response(32'h0000_0008);
        
        drive_load(32'h0000_0008, 4'd2);
        check_load_response(32'h0000_0008, 4'd2);
        
        // Modify upper 32 bits
        drive_store(32'h0000_0008, 64'hCCCC_DDDD_XXXX_XXXX, 8'b1111_0000);
        check_store_response(32'h0000_0008);
        
        drive_load(32'h0000_0008, 4'd3);
        check_load_response(32'h0000_0008, 4'd3);

        // ================================================================
        // Test 3: Sequential Loads and Stores
        // ================================================================
        $display("\n--- Test 3: Sequential Operations ---");
        
        for (int i = 0; i < 8; i++) begin
            drive_store(32'h0000_0100 + (i*8), 64'h5555_0000 + i, 8'b1111_1111);
            check_store_response(32'h0000_0100 + (i*8));
        end
        
        for (int i = 0; i < 8; i++) begin
            drive_load(32'h0000_0100 + (i*8), i[3:0]);
            check_load_response(32'h0000_0100 + (i*8), i[3:0]);
        end

        // ================================================================
        // Test 4: Interleaved Loads and Stores
        // ================================================================
        $display("\n--- Test 4: Interleaved Operations ---");
        
        drive_store(32'h0000_0200, 64'hAAAA_AAAA_AAAA_AAAA, 8'b1111_1111);
        drive_load(32'h0000_0000, 4'd4);
        drive_store(32'h0000_0208, 64'hBBBB_BBBB_BBBB_BBBB, 8'b1111_1111);
        drive_load(32'h0000_0008, 4'd5);
        
        check_store_response(32'h0000_0200);
        check_load_response(32'h0000_0000, 4'd4);
        check_store_response(32'h0000_0208);
        check_load_response(32'h0000_0008, 4'd5);

        // ================================================================
        // Test 5: Boundary Conditions
        // ================================================================
        $display("\n--- Test 5: Boundary Conditions ---");
        
        // Test at different offsets within doubleword
        drive_store(32'h0000_0300, 64'h0011_2233_4455_6677, 8'b1111_1111);
        check_store_response(32'h0000_0300);
        
        drive_load(32'h0000_0300, 4'd6);
        check_load_response(32'h0000_0300, 4'd6);
        
        drive_load(32'h0000_0304, 4'd7);  // Same doubleword, different address
        check_load_response(32'h0000_0304, 4'd7);

        // ================================================================
        // Test 6: Stress Test - Rapid Operations
        // ================================================================
        $display("\n--- Test 6: Stress Test ---");
        
        for (i = 0; i < 16; i++) begin
            addr_var = 32'h0000_1000 + (i*8);
            data_var = {i[31:0], ~i[31:0]};
            drive_store(addr_var, data_var, 8'b1111_1111);
        end
        
        for (i = 0; i < 16; i++) begin
            check_store_response(32'h0000_1000 + (i*8));
        end
        
        for (i = 0; i < 16; i++) begin
            addr_var = 32'h0000_1000 + (i*8);
            drive_load(addr_var, i[3:0]);
        end
        
        for (i = 0; i < 16; i++) begin
            check_load_response(32'h0000_1000 + (i*8), i[3:0]);
        end

        // ================================================================
        // Test 7: Various Byte Enable Patterns
        // ================================================================
        $display("\n--- Test 7: Various Byte Enable Patterns ---");
        
        addr_var = 32'h0000_2000;
        
        // Test different byte enable patterns
        drive_store(addr_var, 64'h0123_4567_89AB_CDEF, 8'b1111_1111);
        check_store_response(addr_var);
        
        drive_store(addr_var, 64'hXXXX_XXXX_XXXX_00FF, 8'b0000_0001);
        check_store_response(addr_var);
        
        drive_store(addr_var, 64'hXXXX_XXXX_XX00_FFXX, 8'b0000_0110);
        check_store_response(addr_var);
        
        drive_store(addr_var, 64'hXXXX_00FF_XXXX_XXXX, 8'b0001_1000);
        check_store_response(addr_var);
        
        drive_store(addr_var, 64'h00FF_XXXX_XXXX_XXXX, 8'b1100_0000);
        check_store_response(addr_var);
        
        drive_load(addr_var, 4'd15);
        check_load_response(addr_var, 4'd15);
        
        // ================================================================
        // Test 8: Alternating Pattern
        // ================================================================
        $display("\n--- Test 8: Alternating Pattern ---");
        
        for (i = 0; i < 10; i++) begin
            addr_var = 32'h0000_3000 + (i*8);
            data_var = (i[0]) ? 64'hAAAA_AAAA_AAAA_AAAA : 64'h5555_5555_5555_5555;
            tag_var = i[3:0];
            
            drive_store(addr_var, data_var, 8'b1111_1111);
            check_store_response(addr_var);
            drive_load(addr_var, tag_var);
            check_load_response(addr_var, tag_var);
        end
        
        // ================================================================
        // Test 9: Read-Modify-Write Pattern
        // ================================================================
        $display("\n--- Test 9: Read-Modify-Write Pattern ---");
        
        addr_var = 32'h0000_4000;
        
        // Initial write
        drive_store(addr_var, 64'h0000_0000_0000_0000, 8'b1111_1111);
        check_store_response(addr_var);
        
        // Read original
        drive_load(addr_var, 4'd1);
        check_load_response(addr_var, 4'd1);
        
        // Modify lower 32 bits
        drive_store(addr_var, 64'hXXXX_XXXX_1234_5678, 8'b0000_1111);
        check_store_response(addr_var);
        
        // Read back
        drive_load(addr_var, 4'd2);
        check_load_response(addr_var, 4'd2);
        
        // Modify upper 32 bits
        drive_store(addr_var, 64'hABCD_EF00_XXXX_XXXX, 8'b1111_0000);
        check_store_response(addr_var);
        
        // Final read
        drive_load(addr_var, 4'd3);
        check_load_response(addr_var, 4'd3);

        // ================================================================
        // Final Summary
        // ================================================================
        repeat(10) @(posedge clk);
        
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Total Tests:  %0d", total_tests);
        $display("Passed:       %0d", passed_tests);
        $display("Failed:       %0d", failed_tests);
        $display("========================================");
        
        if (failed_tests == 0) begin
            $display("\n✓✓✓ ALL TESTS PASSED ✓✓✓\n");
        end else begin
            $display("\n✗✗✗ SOME TESTS FAILED ✗✗✗\n");
        end
        
        $finish;
    end

    // ================================================================
    // Timeout Watchdog
    // ================================================================
    initial begin
        #100000;
        $display("\n✗✗✗ TIMEOUT - Test did not complete ✗✗✗\n");
        $finish;
    end

endmodule