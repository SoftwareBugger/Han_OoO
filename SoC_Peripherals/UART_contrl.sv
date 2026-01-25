`timescale 1ns/1ps
`include "periph_defines.svh"
// ============================================================
// MMIO wrapper around your UART core (bus-agnostic front-end)
// Later: swap this MMIO for AXI-lite/APB adapter without
// touching UART/UART_tx/UART_rx.
// ============================================================
module uart_mmio (
  input  logic              clk,
  input  logic              rst_n,

  // UART pins
  input  logic              uart_rx_i,
  output logic              uart_tx_o,

  // Simple MMIO (one-cycle ready, single outstanding)
  mmio_if.slave mmio
);
  logic              mmio_valid;
  logic              mmio_ready;
  logic              mmio_we;
  logic [ADDR_W-1:0] mmio_addr;   // byte addr
  logic [31:0]       mmio_wdata;
  logic [3:0]        mmio_wstrb;
  logic  [31:0]       mmio_rdata;

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
  // Register map (byte offsets)
  // ---------------------------

  // ---------------------------
  // Bus: always-ready (simple)
  // ---------------------------
 assign mmio_ready = 1'b1;
 logic bus_fire;
 assign bus_fire = mmio_valid & mmio_ready;
 logic [ADDR_W-1:0] addr;
 assign addr[7:0] = {mmio_addr[ADDR_W-1:2], 2'b00};

  // ---------------------------
  // MMIO registers
  // ---------------------------
  logic [31:0] ctrl_reg;
  logic [31:0] baud_div_reg;

  // CTRL bits
 logic tx_en;
 assign tx_en     = ctrl_reg[0];
 logic rx_en;
 assign rx_en     = ctrl_reg[1];
 logic irq_en_rx;
 assign irq_en_rx = ctrl_reg[2];
 logic irq_en_tx;
 assign irq_en_tx = ctrl_reg[3];

  // Narrow BAUD_DIV (define+assign style)
 logic [UART_BAUD_DIV_W-1:0] baud_div;
  assign baud_div = baud_div_reg[UART_BAUD_DIV_W-1:0];

  // apply write strobes
  function [31:0] apply_wstrb;
    input [31:0] oldv;
    input [31:0] wv;
    input [3:0]  st;
    begin
      apply_wstrb = oldv;
      if (st[0]) apply_wstrb[7:0]   = wv[7:0];
      if (st[1]) apply_wstrb[15:8]  = wv[15:8];
      if (st[2]) apply_wstrb[23:16] = wv[23:16];
      if (st[3]) apply_wstrb[31:24] = wv[31:24];
    end
  endfunction

  // ---------------------------
  // UART core signals
  // ---------------------------
 logic       rx_rdy_core;
  logic        clr_rx_rdy_core;
 logic [7:0] rx_data_core;

  logic        trmt_core;
  logic  [7:0] tx_data_core;
 logic       tx_ready_core; // your "tx_done" == ready/idle level
  

  UART u_uart (
    .clk        (clk),
    .rst_n      (rst_n),
    .RX         (uart_rx_i),
    .TX         (uart_tx_o),

    .rx_rdy     (rx_rdy_core),
    .clr_rx_rdy (clr_rx_rdy_core),
    .rx_data    (rx_data_core),

    .trmt       (trmt_core),
    .tx_data    (tx_data_core),
    .tx_ready    (tx_ready_core),

    .baud_div   (baud_div)          // <<< NEW port logicd in
  );

  // ---------------------------
  // 1-deep RX holding register
  // ---------------------------
  logic  [7:0] rx_hold;
  logic        rx_hold_valid;
  logic        rx_overrun; // sticky until STATUS read

  // ---------------------------
  // 1-deep TX holding register
  // ---------------------------
  logic  [7:0] tx_hold;
  logic        tx_hold_valid;

  // DATA access pulses
 logic data_read_pulse;
  assign data_read_pulse = bus_fire & ~mmio_we & (addr[7:0] == UART_REG_DATA);
 logic data_write_pulse;
  assign data_write_pulse = bus_fire &  mmio_we & (addr[7:0] == UART_REG_DATA);

  // STATUS read clears sticky flags (nice UX)
 logic status_read_pulse;
  assign status_read_pulse = bus_fire & ~mmio_we & (addr[7:0] == UART_REG_STATUS);
  // ---------------------------
  // RX capture + clear behavior
  // ---------------------------
  // - Latch a received byte into rx_hold if empty
  // - If rx_hold already full, set overrun and drop new byte
  // - Clear core rdy when we accept, or when CPU reads DATA
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_hold       <= 8'h00;
      rx_hold_valid <= 1'b0;
      rx_overrun    <= 1'b0;
    end else begin
      if (rx_en) begin
        if (rx_rdy_core) begin
          if (!rx_hold_valid) begin
            rx_hold       <= rx_data_core;
            rx_hold_valid <= 1'b1;
          end else begin
            rx_overrun <= 1'b1;
          end
        end
      end

      if (data_read_pulse) begin
        rx_hold_valid <= 1'b0; // pop on read
      end

      if (status_read_pulse) begin
        rx_overrun <= 1'b0;
      end
    end
  end

  // clr_rx_rdy can be asserted either when we successfully accept the byte,
  // or when CPU reads DATA (in case you want read-to-clear semantics).
  always_comb begin
    clr_rx_rdy_core = 1'b0;
    // if (rx_rdy_core && rx_en && !rx_hold_valid) clr_rx_rdy_core = 1'b1; // accepted
    if (data_read_pulse)                         clr_rx_rdy_core = 1'b1; // read clears
  end

  // ---------------------------
  // TX launch behavior
  // ---------------------------
  // - CPU write DATA loads tx_hold (if empty, or overwrite policy)
  // - When core is ready, we issue 1-cycle trmt pulse and consume tx_hold
  // Note: safest contract: accept CPU write only when tx_hold_valid==0.
  // If you prefer overwrite, remove the guard.
 logic tx_can_accept;
 assign tx_can_accept = !tx_hold_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_hold       <= 8'h00;
      tx_hold_valid <= 1'b0;
    end else begin
      if (data_write_pulse && tx_can_accept) begin
        tx_hold       <= mmio_wdata[7:0];
        tx_hold_valid <= 1'b1;
      end // consume when we actually kick TX
      else if (trmt_core) begin
        tx_hold_valid <= 1'b0;
      end
    end
  end

  // Drive UART core TX inputs
  always_comb begin
    tx_data_core = tx_hold;
    trmt_core    = 1'b0;
    if (tx_en && tx_hold_valid && tx_ready_core) begin
      trmt_core = 1'b1; // 1-cycle pulse
    end
  end

  // ---------------------------
  // MMIO register writes
  // ---------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg     <= 32'h0000_0003; // TX_EN=1, RX_EN=1
      baud_div_reg <= 32'd0;
    end else begin
      if (bus_fire && mmio_we) begin
        case (addr[7:0])
          UART_REG_CTRL:     ctrl_reg     <= apply_wstrb(ctrl_reg, mmio_wdata, mmio_wstrb);
          UART_REG_BAUD_DIV: baud_div_reg <= apply_wstrb(baud_div_reg, mmio_wdata, mmio_wstrb);
          default: ;
        endcase
      end
    end
  end

  // ---------------------------
  // MMIO reads
  // ---------------------------
  always_comb begin
    mmio_rdata = 32'h0;
    case (addr[7:0])
      UART_REG_DATA: begin
        mmio_rdata[7:0] = rx_hold;
      end
      UART_REG_STATUS: begin
        mmio_rdata[0] = rx_hold_valid;   // RX_VALID
        mmio_rdata[1] = tx_ready_core;   // TX_READY/IDLE (your tx_done)
        mmio_rdata[3] = tx_hold_valid;   // TX_PENDING
        mmio_rdata[4] = rx_overrun;      // RX_OVERRUN sticky
        mmio_rdata[5] = tx_can_accept;   // TX_CAN_ACCEPT (holding logic empty)
      end
      UART_REG_CTRL: begin
        mmio_rdata = ctrl_reg;
      end
      UART_REG_BAUD_DIV: begin
        mmio_rdata = baud_div_reg;
      end
      default: begin
        mmio_rdata = 32'h0;
      end
    endcase
  end

  // ---------------------------
  // Optional IRQ
  // ---------------------------
 logic irq_rx;
 assign irq_rx = irq_en_rx & rx_hold_valid;
 logic irq_tx;
 assign irq_tx = irq_en_tx & tx_ready_core & ~tx_hold_valid;
 assign irq_o = irq_rx | irq_tx;

endmodule