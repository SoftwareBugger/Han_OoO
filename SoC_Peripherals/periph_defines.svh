`ifndef DEFINES_PERIPH_SVH
`define DEFINES_PERIPH_SVH

parameter int UART_BAUD_DIV_W = 16;
parameter int ADDR_W = 13;
parameter int PERIPH_NUM = 2;

parameter [31:0] DMEM_TEST_BASE = 32'h0000_2000; // keep away from 0x0 in case you map vectors
parameter int          DMEM_TEST_WORDS = 128;
parameter [31:0] SPI_BASE  = 32'h8000_0000;
parameter [31:0] UART_BASE = 32'h8000_1000;

// SPI register offsets (byte)
parameter [7:0] SPI_REG_TXRX   = 8'h00;
parameter [7:0] SPI_REG_STATUS = 8'h04;
parameter [7:0] SPI_REG_CTRL   = 8'h08;
parameter [7:0] SPI_REG_CLKDIV = 8'h0C;
parameter [7:0] SPI_REG_GPIO   = 8'h10;

// UART register offsets (byte)
parameter [7:0] UART_REG_DATA     = 8'h00;
parameter [7:0] UART_REG_STATUS   = 8'h04;
parameter [7:0] UART_REG_CTRL     = 8'h08;
parameter [7:0] UART_REG_BAUD_DIV = 8'h0C;

interface mmio_if #(parameter ADDR_W = 13) ();
    logic              mmio_valid;
    logic              mmio_ready;
    logic              mmio_we;
    logic [ADDR_W-1:0] mmio_addr;   // byte addr
    logic [31:0]       mmio_wdata;
    logic [3:0]        mmio_wstrb;
    logic [31:0]       mmio_rdata;

    logic              irq_o;

    modport master (
        input              mmio_ready,
        input             mmio_rdata,
        input              irq_o,
        output             mmio_valid,
        output             mmio_we,
        output             mmio_addr,
        output             mmio_wdata,
        output             mmio_wstrb
    );

    modport slave (
        input              mmio_valid,
        input              mmio_we,
        input              mmio_addr,
        input              mmio_wdata,
        input              mmio_wstrb,
        output             mmio_ready,
        output             mmio_rdata,
        output             irq_o
    );

endinterface

`endif // DEFINES_PERIPH_SVH