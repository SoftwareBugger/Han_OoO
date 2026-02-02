`timescale 1ns/1ps
`include "periph_defines.svh"

module tb_spi_mmio_gpio_cs_burst;

  localparam int ADDR_W = 12;

  // ----------------------------
  // Clock / Reset
  // ----------------------------
  logic clk;
  logic rst_n;
  localparam time CLK_PERIOD = 10ns;

  // ----------------------------
  // MMIO (no interface)
  // ----------------------------
  logic              mmio_valid;
  wire               mmio_ready;
  logic              mmio_we;
  logic [ADDR_W-1:0] mmio_addr;
  logic [31:0]       mmio_wdata;
  logic [3:0]        mmio_wstrb;
  wire  [31:0]       mmio_rdata;

  // ----------------------------
  // SPI pins
  // ----------------------------
  wire spi_sclk;
  wire spi_mosi;
  wire spi_cs_n;
  wire spi_dc;
  wire spi_res_n;

  // ----------------------------
  // Register map (assumed)
  // ----------------------------
  localparam logic [ADDR_W-1:0] REG_TXRX   = 12'h000;
  localparam logic [ADDR_W-1:0] REG_STATUS = 12'h004; // bit0 READY
  localparam logic [ADDR_W-1:0] REG_CTRL   = 12'h008; // bit0 pos_edge, bit1 width8, bit8 EN
  localparam logic [ADDR_W-1:0] REG_CLKDIV = 12'h00C;
  localparam logic [ADDR_W-1:0] REG_GPIO   = 12'h010; // bit0 CS_N, bit1 DC, bit2 RES_N

  // GPIO helpers (edit if you mapped bits differently)
  function automatic [31:0] gpio_pack(input bit cs_n, input bit dc, input bit res_n);
    gpio_pack = 32'((cs_n<<0) | (dc<<1) | (res_n<<2));
  endfunction

  mmio_if mmio();
  assign mmio.mmio_valid = mmio_valid;
  assign mmio.mmio_we    = mmio_we;
  assign mmio.mmio_addr  = mmio_addr;
  assign mmio.mmio_wdata = mmio_wdata;
  assign mmio.mmio_wstrb = mmio_wstrb;
  assign mmio_rdata      = mmio.mmio_rdata;
  assign mmio_ready      = mmio.mmio_ready;
  assign mmio.irq_o      = mmio.irq_o;


  // ----------------------------
  // DUT (rename if needed)
  // ----------------------------
  spi_mmio_gpio_cs #(.ADDR_W(ADDR_W)) dut (
    .clk       (clk),
    .rst_n     (rst_n),

    .spi_sclk  (spi_sclk),
    .spi_mosi  (spi_mosi),
    .spi_miso  (1'b0),
    .spi_cs_n  (spi_cs_n),
    .spi_dc    (spi_dc),
    .spi_res_n (spi_res_n),

    .mmio(mmio.slave)
  );

  // ============================================================
  // Clock / reset
  // ============================================================
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ============================================================
  // Queued MMIO master
  // ============================================================
  typedef struct packed {
    logic              we;
    logic [ADDR_W-1:0] addr;
    logic [31:0]       wdata;
    logic [3:0]        wstrb;
    logic [7:0]        tag;    // for reads
  } mmio_req_t;

  typedef struct packed {
    logic [7:0]  tag;
    logic [31:0] rdata;
  } mmio_rsp_t;

  mmio_req_t req_q[$];
  mmio_rsp_t rsp_q[$];

  logic      req_active;
  mmio_req_t req_cur;

  logic [7:0] next_tag;
  event       rsp_event;

  // Shared scratch (module scope)
  mmio_req_t tmp_req;
  mmio_rsp_t tmp_rsp;

  logic [7:0]  tmp_tag;
  logic [31:0] tmp_rdata;

  int i; // shared loop index

  // Init driver outputs
  initial begin
    mmio_valid = 1'b0;
    mmio_we    = 1'b0;
    mmio_addr  = '0;
    mmio_wdata = '0;
    mmio_wstrb = 4'h0;

    req_active = 1'b0;
    next_tag   = 8'd1;
  end

  // Enqueue write (no timing)
  task automatic mmio_enqueue_write(input logic [ADDR_W-1:0] addr, input logic [31:0] data);
    begin
      tmp_req.we    = 1'b1;
      tmp_req.addr  = addr;
      tmp_req.wdata = data;
      tmp_req.wstrb = 4'hF;
      tmp_req.tag   = 8'h00;
      req_q.push_back(tmp_req);
    end
  endtask

  // Enqueue read (no timing) -> tag
  task automatic mmio_enqueue_read(input logic [ADDR_W-1:0] addr, output logic [7:0] tag_out);
    begin
      tag_out  = next_tag;
      next_tag = next_tag + 8'd1;

      tmp_req.we    = 1'b0;
      tmp_req.addr  = addr;
      tmp_req.wdata = 32'h0;
      tmp_req.wstrb = 4'h0;
      tmp_req.tag   = tag_out;
      req_q.push_back(tmp_req);
    end
  endtask

  // Blocking read (wait for matching response tag)
  task automatic mmio_read_blocking(input logic [ADDR_W-1:0] addr, output logic [31:0] data_out);
    begin
      mmio_enqueue_read(addr, tmp_tag);

      while (1) begin
        @rsp_event;
        for (i = 0; i < rsp_q.size(); i++) begin
          if (rsp_q[i].tag == tmp_tag) begin
            data_out = rsp_q[i].rdata;
            rsp_q.delete(i);
            return;
          end
        end
      end
    end
  endtask

  // MMIO driver FSM (IMPORTANT: drive from popped tmp_req to avoid ghost requests)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_active <= 1'b0;

      mmio_valid <= 1'b0;
      mmio_we    <= 1'b0;
      mmio_addr  <= '0;
      mmio_wdata <= '0;
      mmio_wstrb <= 4'h0;
    end else begin
      // Load next request if idle
      if (!req_active && (req_q.size() != 0)) begin
        tmp_req = req_q.pop_front();    // BLOCKING pop (crucial)

        req_cur    <= tmp_req;
        req_active <= 1'b1;

        mmio_valid <= 1'b1;
        mmio_we    <= tmp_req.we;
        mmio_addr  <= tmp_req.addr;
        mmio_wdata <= tmp_req.wdata;
        mmio_wstrb <= tmp_req.wstrb;
      end

      // Handshake
      if (req_active && mmio_valid && mmio_ready) begin
        // Capture read response immediately (0-wait bus)
        if (!mmio_we) begin
          tmp_rsp.tag   = req_cur.tag;
          tmp_rsp.rdata = mmio_rdata;
          rsp_q.push_back(tmp_rsp);
          -> rsp_event;
        end

        // Finish
        req_active <= 1'b0;

        mmio_valid <= 1'b0;
        mmio_we    <= 1'b0;
        mmio_addr  <= '0;
        mmio_wdata <= '0;
        mmio_wstrb <= 4'h0;
      end
    end
  end

  // ============================================================
  // OPTION A: Universal burst task (1/2/N)
  // ============================================================
  logic [31:0] status_word;
  int j;

  task automatic spi_burst_bytes(input byte seq[$], input bit dc);
    begin
      // Assert CS low once, set DC, keep RES_N=1
      mmio_enqueue_write(REG_GPIO, gpio_pack(1'b0, dc, 1'b1));

      // (optional) setup slack
      repeat (2) @(posedge clk);

      // For each byte: poll READY then write TXRX
      for (j = 0; j < seq.size(); j++) begin
        do begin
          mmio_read_blocking(REG_STATUS, status_word);
        end while (status_word[0] !== 1'b1);

        mmio_enqueue_write(REG_TXRX, {24'h0, seq[j]});
      end

      // Wait for final READY before deasserting CS
      do begin
        mmio_read_blocking(REG_STATUS, status_word);
      end while (status_word[0] !== 1'b1);

      // Deassert CS high (DC can be anything; keep RES_N=1)
      mmio_enqueue_write(REG_GPIO, gpio_pack(1'b1, 1'b1, 1'b1));
    end
  endtask

  // ============================================================
  // Wire sniffer: reconstruct continuous stream while CS low
  // ============================================================
  byte sniff_got[$];
  bit  pos_edge;
  int  nb;
  int  kb;
  byte cur_byte;

  task automatic sniff_stream_bytes(input bit pos_edge_in, input int nbytes_in);
    begin
      sniff_got.delete();

      // Wait for CS assertion
      wait(spi_cs_n == 1'b0);

      for (nb = 0; nb < nbytes_in; nb++) begin
        cur_byte = 8'h00;
        for (kb = 0; kb < 8; kb++) begin
          // sample on opposite edge of shift edge
          if (pos_edge_in) @(posedge spi_sclk);
          else             @(negedge spi_sclk);
          cur_byte = {cur_byte[6:0], spi_mosi};
        end
        sniff_got.push_back(cur_byte);
      end
    end
  endtask

  // ============================================================
  // Test vectors
  // ============================================================
  byte cmd_seq[$];
  byte data_seq[$];

  // ============================================================
  // Main test
  // ============================================================
  initial begin
    wait (rst_n);

    // Choose SPI edge mode (match your DUT meaning)
    pos_edge = 1'b1;

    // Configure SPI: fast divider
    mmio_enqueue_write(REG_CLKDIV, 32'd1);

    // CTRL: EN=1 (bit8), width8=1 (bit1), pos_edge (bit0)
    mmio_enqueue_write(REG_CTRL, (32'h0000_0100 | (32'(1)<<1) | (32'(pos_edge)<<0)));

    // Idle GPIO high: CS high, DC high, RES high
    mmio_enqueue_write(REG_GPIO, gpio_pack(1'b1, 1'b1, 1'b1));

    // -------- Burst 1: command bytes (DC=0) --------
    cmd_seq.delete();
    cmd_seq.push_back(8'hAE);
    cmd_seq.push_back(8'hA1);
    cmd_seq.push_back(8'hC8);
    cmd_seq.push_back(8'hAF);

    fork
      sniff_stream_bytes(pos_edge, cmd_seq.size());
      spi_burst_bytes(cmd_seq, 1'b0);
    join

    // Verify burst 1
    repeat (10) @(posedge clk);
    if (sniff_got.size() != cmd_seq.size()) begin
      $error("CMD size mismatch exp=%0d got=%0d", cmd_seq.size(), sniff_got.size());
      $finish;
    end
    for (i = 0; i < cmd_seq.size(); i++) begin
      if (sniff_got[i] !== cmd_seq[i]) begin
        $error("CMD mismatch idx=%0d exp=%02x got=%02x", i, cmd_seq[i], sniff_got[i]);
        $finish;
      end
    end
    if (spi_cs_n !== 1'b1) begin
      $error("CS not high after CMD burst");
      $finish;
    end

    // -------- Burst 2: data bytes (DC=1) --------
    data_seq.delete();
    data_seq.push_back(8'h00);
    data_seq.push_back(8'h11);
    data_seq.push_back(8'h22);
    data_seq.push_back(8'h33);
    data_seq.push_back(8'h44);
    data_seq.push_back(8'h55);
    data_seq.push_back(8'h66);
    data_seq.push_back(8'h77);

    fork
      sniff_stream_bytes(pos_edge, data_seq.size());
      spi_burst_bytes(data_seq, 1'b1);
    join

    // Verify burst 2
    repeat (10) @(posedge clk);
    if (sniff_got.size() != data_seq.size()) begin
      $error("DATA size mismatch exp=%0d got=%0d", data_seq.size(), sniff_got.size());
      $finish;
    end
    for (i = 0; i < data_seq.size(); i++) begin
      if (sniff_got[i] !== data_seq[i]) begin
        $error("DATA mismatch idx=%0d exp=%02x got=%02x", i, data_seq[i], sniff_got[i]);
        $finish;
      end
    end
    if (spi_cs_n !== 1'b1) begin
      $error("CS not high after DATA burst");
      $finish;
    end

    $display("PASS: Option-A burst TB verified CMD+DATA bursts with GPIO CS.");
    repeat (20) @(posedge clk);
    $finish;
  end

endmodule
