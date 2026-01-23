`timescale 1ns/1ps
`include "periph_defines.svh"

module tb_uart_mmio;

  // ----------------------------
  // Clock / Reset
  // ----------------------------
  logic clk;
  logic rst_n;
  localparam time CLK_PERIOD = 10ns; // 100 MHz

  // ----------------------------
  // DUT IO
  // ----------------------------
  logic  uart_rx_i;
  wire   uart_tx_o;

  // ----------------------------
  // Keep MMIO discrete signals
  // ----------------------------
  logic         mmio_valid;
  wire          mmio_ready;
  logic         mmio_we;
  logic [11:0]  mmio_addr;
  logic [31:0]  mmio_wdata;
  logic [3:0]   mmio_wstrb;
  wire  [31:0]  mmio_rdata;

  wire          irq_o;

  // ----------------------------
  // Register offsets
  // ----------------------------
  localparam logic [11:0] REG_DATA     = 12'h000;
  localparam logic [11:0] REG_STATUS   = 12'h004;
  localparam logic [11:0] REG_CTRL     = 12'h008;
  localparam logic [11:0] REG_BAUD_DIV = 12'h00C;

  // ----------------------------
  // Test variables
  // ----------------------------
  int          BAUD_DIV_SIM;
  byte         txb;
  logic [31:0] rdata;
  bit          ok;

  // ----------------------------
  // MMIO interface instance (MATCH width!)
  // ----------------------------
  mmio_if #(.ADDR_W(12)) mmio();

  // ----------------------------
  // Bridge: mmio_* -> interface fields (names from periph_defines.svh)
  // TB drives these, DUT sees them via mmio.slave
  // ----------------------------
  assign mmio.mmio_valid = mmio_valid;
  assign mmio.mmio_we    = mmio_we;
  assign mmio.mmio_addr  = mmio_addr;
  assign mmio.mmio_wdata = mmio_wdata;
  assign mmio.mmio_wstrb = mmio_wstrb;

  // DUT drives these back to TB
  assign mmio_ready = mmio.mmio_ready;
  assign mmio_rdata = mmio.mmio_rdata;
  assign irq_o      = mmio.irq_o;

  // ----------------------------
  // DUT
  // ----------------------------
  uart_mmio #(.ADDR_W(12)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .uart_rx_i (uart_rx_i),
    .uart_tx_o (uart_tx_o),
    .mmio      (mmio.slave)
  );

  // ----------------------------
  // Clock generation
  // ----------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  // ----------------------------
  // Reset
  // ----------------------------
  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ----------------------------
  // Loopback: TX -> RX
  // ----------------------------
  initial begin
    uart_rx_i = 1'b1;
    wait (rst_n);
    forever begin
      @(posedge clk);
      uart_rx_i <= uart_tx_o;
    end
  end

  // ----------------------------
  // MMIO tasks (still use mmio_* signals)
  // Add a ready-wait so it can’t “miss” if you later stall ready.
  // ----------------------------
  task automatic mmio_write32(input logic [11:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      mmio_valid <= 1'b1;
      mmio_we    <= 1'b1;
      mmio_addr  <= addr;
      mmio_wdata <= data;
      mmio_wstrb <= 4'hF;

      // wait for handshake (safe even if ready is always 1)
      do @(posedge clk); while (!mmio_ready);

      mmio_valid <= 1'b0;
      mmio_we    <= 1'b0;
      mmio_addr  <= '0;
      mmio_wdata <= '0;
      mmio_wstrb <= '0;
    end
  endtask

  task automatic mmio_read32(input logic [11:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      mmio_valid <= 1'b1;
      mmio_we    <= 1'b0;
      mmio_addr  <= addr;
      mmio_wdata <= '0;
      mmio_wstrb <= 4'h0;

      // wait for handshake
      @(posedge clk);;

      // rdata is combinational in your UART wrapper, so sample now
      data = mmio_rdata;

      mmio_valid <= 1'b0;
      mmio_addr  <= '0;
    end
  endtask

  task automatic poll_status(input logic [31:0] mask, input int max_iters, output bit passed);
    int i;
    logic [31:0] s;
    begin
      passed = 1'b0;
      for (i = 0; i < max_iters; i++) begin
        mmio_read32(REG_STATUS, s);
        if ( (s & mask) == mask ) begin
          passed = 1'b1;
          break;
        end
      end
    end
  endtask

  // ----------------------------
  // Init MMIO defaults
  // ----------------------------
  initial begin
    mmio_valid = 1'b0;
    mmio_we    = 1'b0;
    mmio_addr  = '0;
    mmio_wdata = '0;
    mmio_wstrb = '0;
  end

  // ----------------------------
  // Main test sequence
  // ----------------------------
  initial begin
    BAUD_DIV_SIM = 16;
    txb          = 8'hA5;
    rdata        = 32'h0;
    ok           = 1'b0;

    wait (rst_n);
    @(posedge clk);

    mmio_write32(REG_BAUD_DIV, BAUD_DIV_SIM);
    mmio_write32(REG_CTRL,     32'h0000_0003);
    mmio_write32(REG_DATA,     {24'h0, txb});

    poll_status(32'h0000_0001, 2000, ok);
    if (!ok) begin
      $error("Timeout waiting for RX_VALID");
      $finish;
    end

    mmio_read32(REG_DATA, rdata);
    if (rdata[7:0] !== txb) begin
      $error("Mismatch: expected 0x%02x got 0x%02x", txb, rdata[7:0]);
      $finish;
    end else begin
      $display("PASS: loopback received 0x%02x", rdata[7:0]);
    end

    poll_status(32'h0000_0002, 2000, ok);
    if (!ok) begin
      $error("Timeout waiting for TX_READY");
      $finish;
    end

    $display("All tests completed.");
    repeat (50) @(posedge clk);
    $finish;
  end

  // Safety timeout (prevents “freeze” forever)
  initial begin
    #(5ms);
    $fatal(1, "TB TIMEOUT");
  end

endmodule
