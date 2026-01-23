`timescale 1ns/1ps
`include "periph_defines.svh"
// ============================================================
// MMIO wrapper around your SPI core (bus-agnostic front-end)
// Later: swap this MMIO for AXI-lite/APB adapter without
// touching SPI/SPI_TX/SPI_RX.
// ============================================================
module spi_mmio_gpio_cs (
  input  logic              clk,
  input  logic              rst_n,

  // SPI pins (TX-only)
  output logic              spi_sclk,
  output logic              spi_mosi,
  input  logic              spi_miso,    // unused for OLED, kept for future
  output logic              spi_cs_n,

  // extra OLED control pins (could be generic GPIO)
  output logic              spi_dc,
  output logic              spi_res_n,

  // MMIO
   mmio_if.slave mmio
);

  logic              mmio_valid;
  logic              mmio_ready;
  logic              mmio_we;
  logic [ADDR_W-1:0] mmio_addr;
  logic [31:0]       mmio_wdata;
  logic [3:0]        mmio_wstrb;
  logic [31:0]       mmio_rdata;
  logic              irq_o;

  assign mmio_valid = mmio.mmio_valid;
  assign mmio_we    = mmio.mmio_we;
  assign mmio_addr  = mmio.mmio_addr;
  assign mmio_wdata = mmio.mmio_wdata;
  assign mmio_wstrb = mmio.mmio_wstrb;
  assign mmio.mmio_rdata = mmio_rdata;
  assign mmio.mmio_ready = mmio_ready;
  assign mmio.irq_o  = irq_o;

  // ---------------------------
  // Register map
  // ---------------------------
  // Always-ready simple bus
  assign mmio_ready = 1'b1;
  logic fire;
  assign fire = mmio_valid & mmio_ready;
  logic [ADDR_W-1:0] addr;
  assign addr = {mmio_addr[ADDR_W-1:2], 2'b00};

  // apply byte strobes
  function automatic [31:0] apply_wstrb(input [31:0] oldv, input [31:0] wv, input [3:0] st);
    apply_wstrb = oldv;
    if (st[0]) apply_wstrb[7:0]   = wv[7:0];
    if (st[1]) apply_wstrb[15:8]  = wv[15:8];
    if (st[2]) apply_wstrb[23:16] = wv[23:16];
    if (st[3]) apply_wstrb[31:24] = wv[31:24];
  endfunction

  // ---------------------------
  // MMIO regs
  // ---------------------------
  logic [31:0] ctrl_reg;
  logic [31:0] clkdiv_reg;
  logic [31:0] gpio_reg;

  logic en;
  assign en       = ctrl_reg[8];
  logic pos_edge;
  assign pos_edge = ctrl_reg[0];
  logic width8;
  assign width8   = ctrl_reg[1];

  // GPIO outputs: SW owns these
  // bit0 CS_N (active low)
  // bit1 DC
  // bit2 RES_N
  always_comb begin
    spi_cs_n  = gpio_reg[0];
    spi_dc    = gpio_reg[1];
    spi_res_n = gpio_reg[2];
  end

  // ---------------------------
  // SPI core handshake
  // ---------------------------
  logic spi_ready;     // done==ready level
  logic spi_wrt;

  // Only start when:
  // - write to TXRX
  // - enabled
  // - CS asserted (optional policy: require CS low)
  // - spi_ready
  logic wr_txrx;
  assign wr_txrx = fire & mmio_we & (addr[7:0] == SPI_REG_TXRX);

  always_comb begin
    spi_wrt = 1'b0;
    if (wr_txrx && en && (gpio_reg[0] == 1'b0) && spi_ready) begin
      spi_wrt = 1'b1;
    end
  end

  // Pack byte into tx_data[15:8] if your SPI_TX expects that for width8
  logic [15:0] tx_data;
  assign tx_data = {mmio_wdata[7:0], 8'h00};

  SPI_TX u_spi (
    .clk      (clk),
    .rst_n    (rst_n),
    .SS_n     (),          // IGNORE internal SS from SPI_TX (not used)
    .SCLK     (spi_sclk),
    .wrt      (spi_wrt),
    .done     (spi_ready),
    .tx_data  (tx_data),
    .MOSI     (spi_mosi),
    .pos_edge (pos_edge),
    .width8   (width8),
    .clkdiv   (clkdiv_reg[15:0])  // if your SPI_TX has clkdiv port
  );

  // ---------------------------
  // MMIO writes
  // ---------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg   <= 32'h0000_0102; // EN=1 (bit8), width8=1 (bit1), pos_edge=0
      clkdiv_reg <= 32'd4;
      gpio_reg   <= 32'h0000_0007; // CS_N=1, DC=1, RES_N=1 (safe inactive)
    end else if (fire && mmio_we) begin
      unique case (addr[7:0])
        SPI_REG_CTRL:   ctrl_reg   <= apply_wstrb(ctrl_reg,   mmio_wdata, mmio_wstrb);
        SPI_REG_CLKDIV: clkdiv_reg <= apply_wstrb(clkdiv_reg, mmio_wdata, mmio_wstrb);
        SPI_REG_GPIO:   gpio_reg   <= apply_wstrb(gpio_reg,   mmio_wdata, mmio_wstrb);
        default: ;
      endcase
    end
  end

  // ---------------------------
  // MMIO reads
  // ---------------------------
  always_comb begin
    mmio_rdata = 32'h0;
    unique case (addr[7:0])
      SPI_REG_STATUS: begin
        mmio_rdata[0] = spi_ready;      // READY
        mmio_rdata[1] = ~spi_ready;     // BUSY (simple)
        mmio_rdata[8] = (gpio_reg[0]==1'b0); // CS_ASSERTED (debug)
      end
      SPI_REG_CTRL:   mmio_rdata = ctrl_reg;
      SPI_REG_CLKDIV: mmio_rdata = clkdiv_reg;
      SPI_REG_GPIO:   mmio_rdata = gpio_reg;
      default:    mmio_rdata = 32'h0;
    endcase
  end

  // Optional IRQ: raise when ready after a write (simple)
  // For now, keep it off:
  assign irq_o = 1'b0;

endmodule
