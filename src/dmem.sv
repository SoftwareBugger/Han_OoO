`include "defines.svh"

// ================================================================
// Simple Fixed-Latency Data Memory
// ================================================================
// Load: Fixed N-cycle latency, always ready
// Store: Immediate write, always ready
// ================================================================
`ifdef DEBUG_DMEM
`define DEBUG_DMEM
module dmem_model #(
    parameter int MEM_SIZE_KB = 64,
    parameter int LD_LATENCY  = 1,      // Fixed load latency in cycles
    parameter int LDTAG_W     = 4
)(
    input  logic clk,
    input  logic rst_n,
    dmem_if.slave dmem
);

    // ================================================================
    // Memory Array
    // ================================================================
    localparam int MEM_WORDS = (MEM_SIZE_KB * 1024) / 4;
    logic [31:0] mem [0:MEM_WORDS-1];

    // ================================================================
    // Load Pipeline: Fixed Latency
    // ================================================================
    localparam int STAGES = (LD_LATENCY <= 0) ? 1 : LD_LATENCY;
    
    typedef struct packed {
        logic [31:0]        addr;
        logic [LDTAG_W-1:0] tag;
        logic               valid;
    } ld_pipe_t;
    
    ld_pipe_t ld_pipe [0:STAGES-1];

    // ================================================================
    // Always ready for requests
    // ================================================================
    assign dmem.ld_ready = 1'b1;
    assign dmem.st_ready = 1'b1;

    // ================================================================
    // Response from last pipeline stage
    // ================================================================
    logic [31:0] ld_word_addr;
    logic [31:0] ld_word_data;
    logic [63:0] ld_data64;

    assign ld_word_addr = ld_pipe[STAGES-1].addr >> 2;
    
    always_comb begin
        if (ld_word_addr < MEM_WORDS)
            ld_word_data = mem[ld_word_addr];
        else
            ld_word_data = 32'hDEADBEEF;
    end
    
    assign ld_data64 = {ld_word_data, ld_word_data};

    assign dmem.ld_resp_valid = ld_pipe[STAGES-1].valid;
    assign dmem.ld_resp_data  = ld_data64;
    assign dmem.ld_resp_tag   = ld_pipe[STAGES-1].tag;
    assign dmem.ld_resp_err   = 1'b0;

    // ================================================================
    // Store signals (declared outside always block)
    // ================================================================
    logic [31:0] st_word_addr;
    logic [31:0] st_data32;
    logic [3:0]  st_wstrb4;
    logic [31:0] st_old_data, st_new_data;

    // ================================================================
    // Sequential Logic
    // ================================================================
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i++) begin
                ld_pipe[i].addr  <= '0;
                ld_pipe[i].tag   <= '0;
                ld_pipe[i].valid <= 1'b0;
            end
        end else begin
            
            // =========================================================
            // LOAD: Shift pipeline
            // =========================================================
            for (i = STAGES-1; i >= 1; i--) begin
                ld_pipe[i] <= ld_pipe[i-1];
            end
            
            // New request enters at stage 0
            ld_pipe[0].addr  <= dmem.ld_addr;
            ld_pipe[0].tag   <= dmem.ld_tag;
            ld_pipe[0].valid <= dmem.ld_valid;

            // =========================================================
            // STORE: Immediate write to memory
            // =========================================================
            if (dmem.st_valid) begin
                st_word_addr = dmem.st_addr >> 2;
                st_data32    = dmem.st_addr[2] ? dmem.st_wdata[63:32] : dmem.st_wdata[31:0];
                st_wstrb4    = dmem.st_wstrb[3:0];
                
                if (st_word_addr < MEM_WORDS) begin
                    st_old_data = mem[st_word_addr];
                    st_new_data = st_old_data;
                    
                    if (st_wstrb4[0]) st_new_data[7:0]   = st_data32[7:0];
                    if (st_wstrb4[1]) st_new_data[15:8]  = st_data32[15:8];
                    if (st_wstrb4[2]) st_new_data[23:16] = st_data32[23:16];
                    if (st_wstrb4[3]) st_new_data[31:24] = st_data32[31:24];
                    
                    mem[st_word_addr] <= st_new_data;
                    
                    `ifdef DEBUG_DMEM
                    $display("[%0t] DMEM ST: addr=%h data=%h->%h", 
                             $time, dmem.st_addr, st_old_data, st_new_data);
                    `endif
                end
            end
            
            `ifdef DEBUG_DMEM
            if (dmem.ld_valid) begin
                $display("[%0t] DMEM LD req: addr=%h tag=%0d", 
                         $time, dmem.ld_addr, dmem.ld_tag);
            end
            if (dmem.ld_resp_valid && dmem.ld_resp_ready) begin
                $display("[%0t] DMEM LD resp: data=%h tag=%0d", 
                         $time, dmem.ld_resp_data, dmem.ld_resp_tag);
            end
            `endif
        end
    end

endmodule
`endif