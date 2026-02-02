`include "defines.svh"
`include "periph_defines.svh"

module SoC_system_top (
    input  logic clk,
    input  logic rst_n,

    // ================= Peripheral interfaces =================
    // SPI pins (TX-only)
    output logic              spi_sclk,
    output logic              spi_mosi,
    input  logic              spi_miso,    // unused for OLED, kept for future
    output logic              spi_cs_n,

    // extra OLED control pins (could be generic GPIO)
    output logic              spi_dc,
    output logic              spi_res_n,
    output logic              spi_vccen,   // optional Vcc enable
    output logic              spi_pmoden,  // optional Pmod power enable

    // UART pins
    input  logic              uart_rx_i,
    output logic              uart_tx_o,

    // ================= Debug taps (for FPGA wrapper LEDs) =================
    output logic              dbg_commit_valid,
    output logic              dbg_wb_valid,
    output logic              dbg_redirect_valid,
    output logic              dbg_mispredict,
    output logic [31:0]       dbg_commit_pc,

    output logic              imem_req_valid,
    output logic              imem_req_ready,
    output logic              imem_resp_valid,
    output logic              imem_resp_ready,

    output logic              dmem_st_valid,
    output logic              dmem_st_ready,
    output logic [31:0]       dmem_st_addr,
    output logic [63:0]       dmem_st_wdata,
    output logic [7:0]        dmem_st_wstrb
);

    // ================================================================
    // Internal interfaces
    // ================================================================
    dmem_if #(.LDTAG_W(4)) dmem_cpu();
    imem_if imem();

    // Debug wires from CPU (now module outputs directly)
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
    // Memories
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

    // Export IMEM handshakes for LED pages
    assign imem_req_valid  = imem.imem_req_valid;
    assign imem_req_ready  = imem.imem_req_ready;
    assign imem_resp_valid = imem.imem_resp_valid;
    assign imem_resp_ready = imem.imem_resp_ready;

    // Instantiate mem_system (MMIO/peripherals)
    mem_system #(
        .MEM_SIZE_KB (64),
        .LD_LATENCY  (2),
        .ST_LATENCY  (2),
        .LDTAG_W     (4)
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
        .spi_vccen  (spi_vccen),
        .spi_pmoden (spi_pmoden),
        .uart_rx_i  (uart_rx_i),
        .uart_tx_o  (uart_tx_o)
    );

    // Export DMEM store channel signals for LED pages
    assign dmem_st_valid = dmem_cpu.st_valid;
    assign dmem_st_ready = dmem_cpu.st_ready;
    assign dmem_st_addr  = dmem_cpu.st_addr;
    assign dmem_st_wdata = dmem_cpu.st_wdata;
    assign dmem_st_wstrb = dmem_cpu.st_wstrb;

endmodule
