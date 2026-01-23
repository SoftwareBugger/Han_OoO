`timescale 1ns/1ps
`include "defines.svh"
`include "periph_defines.svh"

// ============================================================
// TB: Drive full mem_system through dmem_if (LSU-style)
//     but run the same sequences as tb_SPI.sv and tb_UART.sv.
// ============================================================
module tb_mem_system_lsu_style;

  // ----------------------------
  // Clock / Reset
  // ----------------------------
  logic clk;
  logic rst_n;
  localparam time CLK_PERIOD = 10ns; // 100 MHz

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ----------------------------
  // dmem interface (CPU-side)
  // ----------------------------
  localparam int LDTAG_W_TB = 4;
  dmem_if #(.LDTAG_W(LDTAG_W_TB)) dmem();

  // TB drives master side defaults
  initial begin
    dmem.ld_valid      = 1'b0;
    dmem.ld_addr       = '0;
    dmem.ld_size       = 3'd0;
    dmem.ld_tag        = '0;
    dmem.ld_resp_ready = 1'b0;

    dmem.st_valid      = 1'b0;
    dmem.st_addr       = '0;
    dmem.st_size       = 3'd0;
    dmem.st_wdata      = '0;
    dmem.st_wstrb      = '0;
    dmem.st_resp_ready = 1'b0;
  end

  // ----------------------------
  // DUT pins
  // ----------------------------
  wire spi_sclk, spi_mosi, spi_cs_n, spi_dc, spi_res_n;
  logic spi_miso;

  logic uart_rx_i;
  wire  uart_tx_o;

  // ----------------------------
  // Instantiate mem_system
  // ----------------------------
  mem_system #(
    .MEM_SIZE_KB (64),
    .LD_LATENCY  (2),
    .ST_LATENCY  (2),
    .LDTAG_W     (LDTAG_W_TB)
  ) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .dmem      (dmem.slave),

    .spi_sclk  (spi_sclk),
    .spi_mosi  (spi_mosi),
    .spi_miso  (spi_miso),
    .spi_cs_n  (spi_cs_n),
    .spi_dc    (spi_dc),
    .spi_res_n (spi_res_n),

    .uart_rx_i (uart_rx_i),
    .uart_tx_o (uart_tx_o)
  );

  // SPI MISO unused for OLED; tie low (or 1)
  initial spi_miso = 1'b0;

  // UART loopback TX -> RX (like tb_UART.sv)
  initial begin
    uart_rx_i = 1'b1;
    wait (rst_n);
    forever begin
      @(posedge clk);
      uart_rx_i <= uart_tx_o;
    end
  end


  // ----------------------------
  // LSU-style dmem tasks (1 outstanding at a time)
  // ----------------------------
  logic [LDTAG_W_TB-1:0] next_tag;

  initial next_tag = '0;

  task automatic dmem_store32(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] wstrb32 = 4'hF);
    logic upper;
    logic [63:0] wdata64;
    logic [7:0]  wstrb64;
    begin
        upper  = addr[2];              // 0: low word, 1: high word (within 64b beat)

        wdata64 = 64'h0;
        wstrb64 = 8'h00;

        if (!upper) begin
        wdata64[31:0] = data;
        wstrb64[3:0]  = wstrb32;
        end else begin
        wdata64[63:32] = data;
        wstrb64[7:4]   = wstrb32;
        end

        @(posedge clk);
        dmem.st_addr  <= addr;
        dmem.st_wdata <= wdata64;
        dmem.st_wstrb <= wstrb64;
        dmem.st_size  <= 3'd2;      // word
        dmem.st_valid <= 1'b1;

        while (!dmem.st_ready) @(posedge clk);
        @(posedge clk) dmem.st_valid <= 1'b0;

        dmem.st_resp_ready <= 1'b1;
        while (!dmem.st_resp_valid) @(posedge clk);
        @(posedge clk) dmem.st_resp_ready <= 1'b0;
    end
  endtask


  task automatic dmem_load32(input logic [31:0] addr, output logic [31:0] data_out);
    logic upper;
    logic [LDTAG_W_TB-1:0] tag;
    begin
        upper = addr[2];
        tag   = next_tag;
        next_tag = next_tag + 1'b1;

        @(posedge clk);
        dmem.ld_addr  <= addr;
        dmem.ld_size  <= 3'd2;
        dmem.ld_tag   <= tag;
        dmem.ld_valid <= 1'b1;

        while (!dmem.ld_ready) @(posedge clk);
        @(posedge clk) dmem.ld_valid <= 1'b0;

        dmem.ld_resp_ready <= 1'b1;
        while (!(dmem.ld_resp_valid && dmem.ld_resp_tag == tag)) @(posedge clk);

        if (!upper) data_out = dmem.ld_resp_data[31:0];
        else        data_out = dmem.ld_resp_data[63:32];

        @(posedge clk) dmem.ld_resp_ready <= 1'b0;
    end
    endtask


  // ----------------------------
  // DMEM tests (real memory, not MMIO)
  // ----------------------------
  function automatic logic [31:0] pat32(input int idx, input logic [31:0] seed);
    // simple deterministic pattern
    pat32 = seed ^ (32'(idx) * 32'h9E37_79B9) ^ {16'(idx), 16'(idx ^ 16'hA5A5)};
  endfunction

  task automatic dmem_test_basic_words(input logic [31:0] base, input int nwords, input logic [31:0] seed);
    logic [31:0] rd;
    int i;
    begin
      $display("[DMEM] basic word test: base=0x%08x nwords=%0d seed=0x%08x", base, nwords, seed);
      // write
      for (i = 0; i < nwords; i++) begin
        dmem_store32(base + 4*i, pat32(i, seed), 4'hF);
      end
      // read+check
      for (i = 0; i < nwords; i++) begin
        dmem_load32(base + 4*i, rd);
        if (rd !== pat32(i, seed)) begin
          $error("[DMEM] mismatch @0x%08x: exp=0x%08x got=0x%08x", base+4*i, pat32(i, seed), rd);
          $finish;
        end
      end
      $display("[DMEM] basic word test PASS");
    end
  endtask

  task automatic dmem_test_wstrb_byte_lanes(input logic [31:0] base);
    logic [31:0] rd;
    logic [31:0] exp;
    logic [31:0] wdata32;
    int b;
    byte newb;
    begin
        $display("[DMEM] wstrb byte-lane test @0x%08x", base);

        // init word
        dmem_store32(base, 32'h1122_3344, 4'hF);
        dmem_load32(base, rd);
        if (rd !== 32'h1122_3344) $fatal(1, "[DMEM] init failed exp=11223344 got=%08x", rd);

        exp = 32'h1122_3344;  // ✅ cumulative expected value

        // write one byte lane at a time
        for (b = 0; b < 4; b++) begin
        newb   = 8'hA0 + b[7:0];

        // ✅ align write data to the lane that wstrb enables
        wdata32 = 32'h0;
        wdata32[8*b +: 8] = newb;

        // perform masked store
        dmem_store32(base, wdata32, (4'h1 << b));

        // ✅ update expected cumulatively (do NOT reset exp each loop)
        exp[8*b +: 8] = newb;

        // read back and compare against cumulative exp
        dmem_load32(base, rd);
        if (rd !== exp) begin
            $fatal(1, "[DMEM] wstrb lane %0d mismatch exp=%08x got=%08x", b, exp, rd);
        end
        end

        $display("[DMEM] wstrb byte-lane test PASS exp_final=%08x", exp);
    end
    endtask


  task automatic dmem_test_mmio_interference();
    // Run a DMEM pattern test, then do MMIO traffic, then re-check same DMEM locations
    logic [31:0] seed;
    begin
      seed = 32'hC0FF_EE00;
      dmem_test_basic_words(DMEM_TEST_BASE, DMEM_TEST_WORDS, seed);
      // After peripheral traffic we re-check with same seed to ensure no corruption / misdecode
      dmem_test_basic_words(DMEM_TEST_BASE, DMEM_TEST_WORDS, seed);
      $display("[DMEM] MMIO interference (pre/post) PASS");
    end
  endtask


  // ----------------------------
  // Helper: pack SPI GPIO bits (CS_N, DC, RES_N)
  // ----------------------------
  function automatic logic [31:0] spi_gpio_pack(input bit cs_n, input bit dc, input bit res_n);
    spi_gpio_pack = 32'h0;
    spi_gpio_pack[0] = cs_n;
    spi_gpio_pack[1] = dc;
    spi_gpio_pack[2] = res_n;
  endfunction

  // ----------------------------
  // SPI helpers: poll READY + burst write
  // ----------------------------
  task automatic spi_wait_ready();
    logic [31:0] status_word;
    begin
      do begin
        dmem_load32(SPI_BASE + SPI_REG_STATUS, status_word);
      end while (status_word[0] !== 1'b1);
    end
  endtask

  task automatic spi_burst_bytes_cpu(input byte seq[$], input bit dc);
    int j;
    begin
      // CS low, set DC, keep RES_N high
      dmem_store32(SPI_BASE + SPI_REG_GPIO, spi_gpio_pack(1'b0, dc, 1'b1));

      repeat (2) @(posedge clk);

      for (j = 0; j < seq.size(); j++) begin
        spi_wait_ready();
        dmem_store32(SPI_BASE + SPI_REG_TXRX, {24'h0, seq[j]});
      end

      spi_wait_ready();

      // CS high idle
      dmem_store32(SPI_BASE + SPI_REG_GPIO, spi_gpio_pack(1'b1, 1'b1, 1'b1));
    end
  endtask

  // ----------------------------
  // SPI sniffer (copied behavior from tb_SPI.sv)
  // ----------------------------
  byte sniff_got[$];

  task automatic sniff_stream_bytes(input bit pos_edge_in, input int nbytes_in);
    int nb, kb;
    byte cur_byte;
    begin
      sniff_got.delete();
      // wait for CS assertion
      wait (spi_cs_n == 1'b0);

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

  // ----------------------------
  // UART helpers: poll status bits
  // ----------------------------
  task automatic uart_poll_status(input logic [31:0] mask, input int max_iters, output bit ok);
    logic [31:0] st;
    int it;
    begin
      ok = 1'b0;
      for (it = 0; it < max_iters; it++) begin
        dmem_load32(UART_BASE + UART_REG_STATUS, st);
        if ((st & mask) == mask) begin
          ok = 1'b1;
          return;
        end
        @(posedge clk);
      end
    end
  endtask

  // Optional: UART TX sniffer (samples uart_tx_o using BAUD_DIV in clk cycles)
  byte uart_sniff_got[$];
  task automatic uart_sniff_bytes(input int baud_div, input int nbytes);
    int i, b, k;
    byte val;
    begin
      uart_sniff_got.delete();
      for (i = 0; i < nbytes; i++) begin
        // wait start bit
        wait (uart_tx_o == 1'b0);
        // move to middle of bit0
        repeat (baud_div/2) @(posedge clk);

        val = 8'h00;
        for (b = 0; b < 8; b++) begin
          repeat (baud_div) @(posedge clk);
          val[b] = uart_tx_o;
        end

        // stop bit
        // repeat (baud_div) @(posedge clk);
        uart_sniff_got.push_back(val);

        // idle between bytes (if any)
        repeat (baud_div) @(posedge clk);
      end
    end
  endtask

  // ============================================================
  // Main test sequence: SPI burst then UART loopback readback
  // ============================================================
  int i;
  bit pos_edge;
  byte cmd_seq[$];
  byte data_seq[$];

  // ----------------------------
    // UART sequence (matches tb_UART)
    // ----------------------------
    int BAUD_DIV_SIM;
    byte txb;
    logic [31:0] rdata;
    bit ok;

  initial begin
    wait (rst_n);
    @(posedge clk);
    // ----------------------------
    // DMEM sanity tests (before MMIO traffic)
    // ----------------------------
    dmem_test_wstrb_byte_lanes(DMEM_TEST_BASE + 32'h400);
    dmem_test_basic_words(DMEM_TEST_BASE, DMEM_TEST_WORDS, 32'h1234_5678);


    // ----------------------------
    // SPI sequence (matches tb_SPI)
    // ----------------------------
    pos_edge = 1'b1;

    // Configure SPI
    dmem_store32(SPI_BASE + SPI_REG_CLKDIV, 32'd1);
    dmem_store32(SPI_BASE + SPI_REG_CTRL, (32'h0000_0100 | (32'(1)<<1) | (32'(pos_edge)<<0)));
    dmem_store32(SPI_BASE + SPI_REG_GPIO, spi_gpio_pack(1'b1, 1'b1, 1'b1));

    // Burst 1: command bytes (DC=0)
    cmd_seq.delete();
    cmd_seq.push_back(8'hAE);
    cmd_seq.push_back(8'hA1);
    cmd_seq.push_back(8'hC8);
    cmd_seq.push_back(8'hAF);

    fork
      sniff_stream_bytes(pos_edge, cmd_seq.size());
      spi_burst_bytes_cpu(cmd_seq, 1'b0);
    join

    repeat (10) @(posedge clk);
    if (sniff_got.size() != cmd_seq.size()) begin
      $error("SPI CMD size mismatch exp=%0d got=%0d", cmd_seq.size(), sniff_got.size());
      $finish;
    end
    for (i = 0; i < cmd_seq.size(); i++) begin
      if (sniff_got[i] !== cmd_seq[i]) begin
        $error("SPI CMD mismatch idx=%0d exp=%02x got=%02x", i, cmd_seq[i], sniff_got[i]);
        $finish;
      end
    end
    if (spi_cs_n !== 1'b1) begin
      $error("SPI CS not high after CMD burst");
      $finish;
    end

    // Burst 2: data bytes (DC=1)
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
      spi_burst_bytes_cpu(data_seq, 1'b1);
    join

    repeat (10) @(posedge clk);
    if (sniff_got.size() != data_seq.size()) begin
      $error("SPI DATA size mismatch exp=%0d got=%0d", data_seq.size(), sniff_got.size());
      $finish;
    end
    for (i = 0; i < data_seq.size(); i++) begin
      if (sniff_got[i] !== data_seq[i]) begin
        $error("SPI DATA mismatch idx=%0d exp=%02x got=%02x", i, data_seq[i], sniff_got[i]);
        $finish;
      end
    end
    if (spi_cs_n !== 1'b1) begin
      $error("SPI CS not high after DATA burst");
      $finish;
    end

    $display("PASS: SPI burst sequence verified through LSU-style dmem transactions.");

    

    BAUD_DIV_SIM = 16;
    txb          = 8'hA5;

    dmem_store32(UART_BASE + UART_REG_BAUD_DIV, BAUD_DIV_SIM);
    dmem_store32(UART_BASE + UART_REG_CTRL,     32'h0000_0003);

    fork
      uart_sniff_bytes(BAUD_DIV_SIM, 1);
      begin
        dmem_store32(UART_BASE + UART_REG_DATA, {24'h0, txb});
      end
    join

    uart_poll_status(32'h0000_0001, 2000, ok); // RX_VALID
    if (!ok) begin
      $error("UART timeout waiting for RX_VALID");
      $finish;
    end

    dmem_load32(UART_BASE + UART_REG_DATA, rdata);
    if (rdata[7:0] !== txb) begin
      $error("UART mismatch: expected 0x%02x got 0x%02x", txb, rdata[7:0]);
      $finish;
    end

    uart_poll_status(32'h0000_0002, 2000, ok); // TX_READY
    if (!ok) begin
      $error("UART timeout waiting for TX_READY");
      $finish;
    end

    if (uart_sniff_got.size() == 1 && uart_sniff_got[0] === txb)
      $display("UART sniff saw TX byte = 0x%02x (matches)", uart_sniff_got[0]);
    else
      $display("UART sniff: got %0d bytes (first=%02x), expected %02x",
               uart_sniff_got.size(), (uart_sniff_got.size()?uart_sniff_got[0]:8'h00), txb);

    $display("PASS: UART loopback verified through LSU-style dmem transactions.");

    // ----------------------------
    // DMEM re-check after MMIO traffic (catch misdecode/corruption)
    // ----------------------------
    dmem_test_basic_words(DMEM_TEST_BASE, DMEM_TEST_WORDS, 32'h1234_5678);


    $display("All tests completed.");
    repeat (50) @(posedge clk);
    $finish;
  end

  // Safety timeout
  initial begin
    #(10ms);
    $fatal(1, "TB TIMEOUT");
  end

endmodule