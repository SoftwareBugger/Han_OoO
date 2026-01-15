// ============================================================================
// FPGA Top-Level Integration Example
// ============================================================================
module SoC_top #(
    parameter bit USE_CACHE = 0
)(
    input  logic clk,
    input  logic rst_n,
    
    // External memory interface (e.g., AXI to DDR)
    // ... AXI ports here ...
    
    // Debug/status outputs
    output logic [7:0] status_leds
);

    // Internal interfaces
    dmem_if #(.LDTAG_W(4)) dmem_cpu();
    dmem_if #(.LDTAG_W(4)) dmem_backing();
    imem_if imem();

    // CPU core instance
    cpu_core cpu_inst (
        .clk(clk),
        .rst_n(rst_n),
        .dmem(dmem_cpu),
        .imem(imem)
    );

    // Instruction memory (BRAM)
    imem #(
        .MEM_WORDS(8192),
        .HEXFILE("program.hex"),
        .LATENCY(1),
        .RESP_FIFO_DEPTH(4)
    ) imem_inst (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(imem.imem_req_valid),
        .req_ready(imem.imem_req_ready),
        .req_addr(imem.imem_req_addr),
        .resp_valid(imem.imem_resp_valid),
        .resp_ready(imem.imem_resp_ready),
        .resp_inst(imem.imem_resp_inst)
    );

    generate
        if (USE_CACHE) begin : gen_with_cache
            // Data memory with cache
            dmem_with_cache #(
                .CACHE_SIZE_KB(8),
                .CACHE_LINE_SIZE(64),
                .CACHE_WAYS(2),
                .MEM_SIZE_KB(256),
                .MEM_LATENCY(10),
                .LDTAG_W(4),
                .VERBOSE(0)
            ) dmem_cache_inst (
                .clk(clk),
                .rst_n(rst_n),
                .dmem_cpu(dmem_cpu),
                .dmem_mem(dmem_backing)
            );
            
            // Backing memory (BRAM or external)
            dmem_model #(
                .MEM_SIZE_KB(256),
                .LD_LATENCY_MIN(10),
                .LD_LATENCY_MAX(10),
                .ST_LATENCY(1),
                .LD_REQ_FIFO_DEPTH(8),
                .LD_RESP_FIFO_DEPTH(8),
                .ST_REQ_FIFO_DEPTH(8),
                .LDTAG_W(4),
                .ENABLE_STALL(0),
                .HEXFILE(""),
                .VERBOSE(0)
            ) dmem_backing_inst (
                .clk(clk),
                .rst_n(rst_n),
                .dmem(dmem_backing)
            );
            
        end else begin : gen_direct
            // Direct BRAM (no cache)
            dmem_model #(
                .MEM_SIZE_KB(64),
                .LD_LATENCY_MIN(2),
                .LD_LATENCY_MAX(2),
                .ST_LATENCY(0),
                .LD_REQ_FIFO_DEPTH(4),
                .LD_RESP_FIFO_DEPTH(4),
                .ST_REQ_FIFO_DEPTH(4),
                .LDTAG_W(4),
                .ENABLE_STALL(0),
                .HEXFILE("data.hex"),
                .VERBOSE(0)
            ) dmem_direct_inst (
                .clk(clk),
                .rst_n(rst_n),
                .dmem(dmem_cpu)
            );
        end
    endgenerate

    // Status indicators
    assign status_leds = {4'b0, dmem_cpu.ld_valid, dmem_cpu.st_valid, 
                          dmem_cpu.ld_ready, dmem_cpu.st_ready};

endmodule