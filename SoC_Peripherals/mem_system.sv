`include "periph_defines.svh"
`include "defines.svh"
module mem_system #(
    parameter int MEM_SIZE_KB = 64,
    parameter int LD_LATENCY  = 2,      // Fixed load latency in cycles for data memory
    parameter int ST_LATENCY  = 2,      // Fixed store latency in cycles for data memory, peripheral MMIOs are just 1 cycle
    parameter int LDTAG_W     = 4
)(
    input  logic clk,
    input  logic rst_n,
    dmem_if.slave dmem,

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
    // Internal signals
    dmem_if mem_dmem();
    mmio_if spi_mmio();
    mmio_if uart_mmio();

    // Instantiate MMIO interconnect
    mmio u_mmio (
        .clk        (clk),
        .rst_n      (rst_n),
        .cpu_dmem   (dmem),
        .mem_dmem   (mem_dmem.master),
        .spi_mmio   (spi_mmio.master),
        .uart_mmio  (uart_mmio.master)
    );

    // Instantiate real memory
    dmem_model #(
        .MEM_SIZE_KB (MEM_SIZE_KB),
        .LD_LATENCY  (LD_LATENCY),
        .ST_LATENCY  (ST_LATENCY),
        .LDTAG_W     (LDTAG_W)
    ) u_mem (
        .clk        (clk),
        .rst_n      (rst_n),
        .dmem       (mem_dmem.slave)
    );

    // Instantiate SPI peripheral
    spi_mmio_gpio_cs u_spi (
        .clk        (clk),
        .rst_n      (rst_n),
        .spi_sclk   (spi_sclk),          // connect to top-level as needed
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .spi_cs_n   (spi_cs_n),
        .spi_dc     (spi_dc),
        .spi_res_n  (spi_res_n),
        .mmio       (spi_mmio.slave)
    );

    // Instantiate UART peripheral
    uart_mmio u_uart (
        .clk        (clk),
        .rst_n      (rst_n),
        .uart_rx_i  (uart_rx_i),
        .uart_tx_o  (uart_tx_o),
        .mmio       (uart_mmio.slave)
    );
endmodule