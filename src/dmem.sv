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
    parameter int LD_LATENCY  = 2,      // Fixed load latency in cycles
    parameter int ST_LATENCY  = 2,      // Fixed store latency in cycles
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
    // BRAM ip instantiation 
    // ================================================================
    genvar i;
    logic        ena [0:7];
    logic [0:0]  wea [0:7];
    logic [13:0] addra;
    logic [7:0]  dina [0:7];
    logic        enb [0:7];
    logic [13:0] addrb;
    logic [7:0]  doutb [0:7];
    logic        rstb_busy [0:7];
    logic        rsta_busy [0:7];

    generate
        for (i = 0; i < 8; i++) begin : INIT_MEM
            blk_mem_gen_0 dut (
                .clka      (clk),
                .wea       (wea[i]),
                .addra     (addra),
                .dina      (dina[i]),

                .clkb      (clk),
                .rstb      (1'b0),
                .addrb     (addrb),
                .doutb     (doutb[i]),

                .rsta_busy (rsta_busy[i]),
                .rstb_busy (rstb_busy[i])
            );

        end
    endgenerate

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
    // assign ld_dword_addr = ld_addr_reg >> 3;
    assign addrb = dmem.ld_addr[16:3];
    
    // Read from 64-bit wide memory
    always_comb begin
        ld_data64 = {doutb[7], doutb[6], doutb[5], doutb[4],
                         doutb[3], doutb[2], doutb[1], doutb[0]};
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
    always_comb begin
        //st_dword_addr = st_addr_reg >> 3;
        addra = dmem.st_addr[16:3];
        
        // Split wdata into bytes for BRAM inputs
        dina[0] = dmem.st_wdata[7:0];
        dina[1] = dmem.st_wdata[15:8];
        dina[2] = dmem.st_wdata[23:16];
        dina[3] = dmem.st_wdata[31:24];
        dina[4] = dmem.st_wdata[39:32];
        dina[5] = dmem.st_wdata[47:40];
        dina[6] = dmem.st_wdata[55:48];
        dina[7] = dmem.st_wdata[63:56];
        
        // Set write enables based on wstrb
        wea[0] = dmem.st_wstrb[0] & ena[0];
        wea[1] = dmem.st_wstrb[1] & ena[1];
        wea[2] = dmem.st_wstrb[2] & ena[2];
        wea[3] = dmem.st_wstrb[3] & ena[3];
        wea[4] = dmem.st_wstrb[4] & ena[4];
        wea[5] = dmem.st_wstrb[5] & ena[5];
        wea[6] = dmem.st_wstrb[6] & ena[6];
        wea[7] = dmem.st_wstrb[7] & ena[7];
        
        // Always enable BRAM for store operations
        ena[0] = dmem.st_valid && dmem.st_ready;
        ena[1] = dmem.st_valid && dmem.st_ready;
        ena[2] = dmem.st_valid && dmem.st_ready;
        ena[3] = dmem.st_valid && dmem.st_ready;
        ena[4] = dmem.st_valid && dmem.st_ready;
        ena[5] = dmem.st_valid && dmem.st_ready;
        ena[6] = dmem.st_valid && dmem.st_ready;
        ena[7] = dmem.st_valid && dmem.st_ready;

        enb[0] = dmem.ld_valid && dmem.ld_ready;
        enb[1] = dmem.ld_valid && dmem.ld_ready;
        enb[2] = dmem.ld_valid && dmem.ld_ready;
        enb[3] = dmem.ld_valid && dmem.ld_ready;
        enb[4] = dmem.ld_valid && dmem.ld_ready;
        enb[5] = dmem.ld_valid && dmem.ld_ready;
        enb[6] = dmem.ld_valid && dmem.ld_ready;
        enb[7] = dmem.ld_valid && dmem.ld_ready;


    end

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
                    // Assert completion signal
                    st_resp_valid_reg <= 1'b1;
                    st_active <= 1'b0;
                end
            end else if (dmem.st_valid && dmem.st_ready) begin
                // Accept new store request
                st_addr_reg <= dmem.st_addr;
                dmem.st_wdata <= dmem.st_wdata;
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