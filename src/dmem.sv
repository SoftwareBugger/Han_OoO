`include "defines.svh"

// ================================================================
// FPGA-Friendly Fixed-Latency Data Memory with Store Completion
// ================================================================
// - 64-bit wide memory array (maps to FPGA BRAM efficiently)
// - Stall-based operation: one load and one store at a time
// - Fixed latency for both reads and writes
// - Store completion signal to LSU
// ================================================================
`ifdef DEBUG_DMEM
`define DEBUG_DMEM
`endif

module dmem_model #(
    parameter int MEM_SIZE_KB = 64,
    parameter int LD_LATENCY  = 3,      // Fixed load latency in cycles
    parameter int ST_LATENCY  = 3,      // Fixed store latency in cycles
    parameter int LDTAG_W     = 4
)(
    input  logic clk,
    input  logic rst_n,
    dmem_if.slave dmem
);

    // ================================================================
    // Memory Array - 64-bit wide for FPGA BRAM efficiency
    // ================================================================
    localparam int MEM_DWORDS = (MEM_SIZE_KB * 1024) / 8;  // Number of 64-bit words
    logic [63:0] mem [0:MEM_DWORDS-1];

    // ================================================================
    // Load Request State
    // ================================================================
    logic [31:0]        ld_addr_reg;
    logic [LDTAG_W-1:0] ld_tag_reg;
    logic               ld_active;
    int                 ld_counter;

    // ================================================================
    // Store Request State
    // ================================================================
    logic [31:0] st_addr_reg;
    logic [63:0] st_wdata_reg;
    logic [7:0]  st_wstrb_reg;
    logic        st_active;
    int          st_counter;
    logic        st_resp_valid_reg;

    // ================================================================
    // Ready signals: Only ready when not processing a request
    // ================================================================
    assign dmem.ld_ready = !ld_active;
    assign dmem.st_ready = !st_active;

    // ================================================================
    // Load response signals
    // ================================================================
    logic [31:0] ld_dword_addr;  // 64-bit doubleword address
    logic [63:0] ld_data64;
    logic        ld_resp_valid_reg;
    logic [63:0] ld_resp_data_reg;
    logic [LDTAG_W-1:0] ld_resp_tag_reg;

    // Byte address -> doubleword index (addr[31:3])
    assign ld_dword_addr = ld_addr_reg >> 3;
    
    // Read from 64-bit wide memory
    always_comb begin
        if (ld_dword_addr < MEM_DWORDS)
            ld_data64 = mem[ld_dword_addr];
        else
            ld_data64 = 64'hDEADBEEF_DEADBEEF;
    end

    assign dmem.ld_resp_valid = ld_resp_valid_reg;
    assign dmem.ld_resp_data  = ld_resp_data_reg;
    assign dmem.ld_resp_tag   = ld_resp_tag_reg;
    assign dmem.ld_resp_err   = 1'b0;

    // ================================================================
    // Store response signal
    // ================================================================
    assign dmem.st_resp_valid = st_resp_valid_reg;

    // ================================================================
    // Store signals
    // ================================================================
    logic [31:0] st_dword_addr;
    logic [63:0] st_old_data;
    logic [63:0] st_new_data;

    // ================================================================
    // Sequential Logic
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_active <= 1'b0;
            ld_counter <= 0;
            ld_addr_reg <= '0;
            ld_tag_reg <= '0;
            ld_resp_valid_reg <= 1'b0;
            ld_resp_data_reg <= '0;
            ld_resp_tag_reg <= '0;
            
            st_active <= 1'b0;
            st_counter <= 0;
            st_addr_reg <= '0;
            st_wdata_reg <= '0;
            st_wstrb_reg <= '0;
            st_resp_valid_reg <= 1'b0;
            
        end else begin
            
            // =========================================================
            // LOAD: Stall-based operation
            // =========================================================
            
            // Clear response valid if accepted
            if (ld_resp_valid_reg && dmem.ld_resp_ready) begin
                ld_resp_valid_reg <= 1'b0;
            end
            
            if (ld_active) begin
                // Currently processing a load request
                if (ld_counter > 0) begin
                    // Still stalling
                    ld_counter <= ld_counter - 1;
                end else begin
                    // Latency complete, generate response
                    ld_resp_valid_reg <= 1'b1;
                    ld_resp_data_reg <= ld_data64;
                    ld_resp_tag_reg <= ld_tag_reg;
                    ld_active <= 1'b0;
                    
                    `ifdef DEBUG_DMEM
                    $display("[%0t] DMEM LD complete: addr=%h data=%h tag=%0d", 
                             $time, ld_addr_reg, ld_data64, ld_tag_reg);
                    `endif
                end
            end else if (dmem.ld_valid && dmem.ld_ready) begin
                // Accept new load request
                ld_addr_reg <= dmem.ld_addr;
                ld_tag_reg <= dmem.ld_tag;
                ld_active <= 1'b1;
                ld_counter <= LD_LATENCY - 1;  // -1 because we count this cycle
                
                `ifdef DEBUG_DMEM
                $display("[%0t] DMEM LD req accepted: addr=%h tag=%0d, will stall for %0d cycles", 
                         $time, dmem.ld_addr, dmem.ld_tag, LD_LATENCY);
                `endif
            end

            // =========================================================
            // STORE: Stall-based operation with completion signal
            // =========================================================
            
            // Clear store response valid if accepted
            if (st_resp_valid_reg && dmem.st_resp_ready) begin
                st_resp_valid_reg <= 1'b0;
            end
            
            if (st_active) begin
                // Currently processing a store request
                if (st_counter > 0) begin
                    // Still stalling
                    st_counter <= st_counter - 1;
                end else begin
                    // Latency complete, execute store
                    st_dword_addr = st_addr_reg >> 3;
                    
                    if (st_dword_addr < MEM_DWORDS) begin
                        // Read-modify-write with byte enables
                        st_old_data = mem[st_dword_addr];
                        st_new_data = st_old_data;
                        
                        // Apply byte-level writes based on wstrb
                        if (st_wstrb_reg[0]) st_new_data[7:0]    = st_wdata_reg[7:0];
                        if (st_wstrb_reg[1]) st_new_data[15:8]   = st_wdata_reg[15:8];
                        if (st_wstrb_reg[2]) st_new_data[23:16]  = st_wdata_reg[23:16];
                        if (st_wstrb_reg[3]) st_new_data[31:24]  = st_wdata_reg[31:24];
                        if (st_wstrb_reg[4]) st_new_data[39:32]  = st_wdata_reg[39:32];
                        if (st_wstrb_reg[5]) st_new_data[47:40]  = st_wdata_reg[47:40];
                        if (st_wstrb_reg[6]) st_new_data[55:48]  = st_wdata_reg[55:48];
                        if (st_wstrb_reg[7]) st_new_data[63:56]  = st_wdata_reg[63:56];
                        
                        mem[st_dword_addr] <= st_new_data;
                        
                        `ifdef DEBUG_DMEM
                        $display("[%0t] DMEM ST complete: addr=%h [%0d] data=%h->%h wstrb=%b", 
                                 $time, st_addr_reg, st_dword_addr, st_old_data, st_new_data, st_wstrb_reg);
                        `endif
                    end
                    
                    // Assert completion signal
                    st_resp_valid_reg <= 1'b1;
                    st_active <= 1'b0;
                end
            end else if (dmem.st_valid && dmem.st_ready) begin
                // Accept new store request
                st_addr_reg <= dmem.st_addr;
                st_wdata_reg <= dmem.st_wdata;
                st_wstrb_reg <= dmem.st_wstrb;
                st_active <= 1'b1;
                st_counter <= ST_LATENCY - 1;  // -1 because we count this cycle
                
                `ifdef DEBUG_DMEM
                $display("[%0t] DMEM ST req accepted: addr=%h data=%h wstrb=%b, will stall for %0d cycles", 
                         $time, dmem.st_addr, dmem.st_wdata, dmem.st_wstrb, ST_LATENCY);
                `endif
            end
        end
    end

endmodule