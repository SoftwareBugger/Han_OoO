`include "defines.svh"
`include "periph_defines.svh"
module SoC_system_top (
    input  logic clk,
    input  logic rst_n,
    // SoC peripheral interfaces 
    // SPI pins (TX-only)
    output logic              spi_sclk,
    output logic              spi_mosi,
    input  logic              spi_miso,    // unused for OLED, kept for future
    output logic              spi_cs_n,

    // extra OLED control pins (could be generic GPIO)
    output logic              spi_dc,
    output logic              spi_res_n,

    // UART pins
    input  logic              uart_rx_i,
    output logic              uart_tx_o
);
    // ================================================================
    // Internal interfaces (run on 25 MHz)
    // ================================================================
    dmem_if #(.LDTAG_W(4)) dmem_cpu();
    imem_if imem();

    // Debug wires from CPU
    logic        dbg_commit_valid, dbg_wb_valid, dbg_redirect_valid, dbg_mispredict;
    logic [31:0] dbg_commit_pc;

    cpu_core cpu_inst (
        .clk(clk),
        .rst_n(rst_n),
        .dmem(dmem_cpu),
        .imem(imem),

        .dbg_commit_valid   (dbg_commit_valid),
        .dbg_wb_valid       (dbg_wb_valid),
        .dbg_redirect_valid (dbg_redirect_valid),
        .dbg_mispredict_fire(dbg_mispredict),
        .dbg_commit_pc      (dbg_commit_pc)
    );

    // ================================================================
    // Memories (run on 25 MHz)
    // ================================================================
    imem #(
        .MEM_WORDS(8192),
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

    // Instantiate mem_system
    mem_system #(
        .MEM_SIZE_KB (64),       // 64 KB memory
        .LD_LATENCY  (2),
        .ST_LATENCY  (2),
        .LDTAG_W     (4),
        .ADDR_W      (12)        // 4 KB MMIO space
    ) u_mem_system (
        .clk        (clk),
        .rst_n      (rst_n),
        .dmem       (dmem_cpu),
        .spi_sclk   (spi_sclk),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .spi_cs_n   (spi_cs_n),
        .spi_dc     (spi_dc),
        .spi_res_n  (spi_res_n),
        .uart_rx_i  (uart_rx_i),
        .uart_tx_o  (uart_tx_o)
    );
endmodule