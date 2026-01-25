`timescale 1ns/1ps

module tb_blk_mem_gen_0;

  // --------------------------------------------------------------------------
  // Match your stub ports exactly:
  //   Port A: write 8-bit
  //   Port B: read  8-bit (registered)
  // --------------------------------------------------------------------------
  logic        clka, ena;
  logic [0:0]  wea;
  logic [13:0] addra;
  logic [7:0]  dina;

  logic        clkb, rstb, enb;
  logic [13:0] addrb;
  wire  [7:0]  doutb;

  wire         rsta_busy, rstb_busy;

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  blk_mem_gen_0 dut (
    .clka      (clka),
    .ena       (ena),
    .wea       (wea),
    .addra     (addra),
    .dina      (dina),

    .clkb      (clkb),
    .rstb      (rstb),
    .enb       (enb),
    .addrb     (addrb),
    .doutb     (doutb),

    .rsta_busy (rsta_busy),
    .rstb_busy (rstb_busy)
  );

  // --------------------------------------------------------------------------
  // Clocks (intentionally different to stress dual-clock behavior)
  // --------------------------------------------------------------------------
  initial clka = 1'b0;
  always  #5  clka = ~clka;   // 100 MHz

  initial clkb = 1'b0;
  always  #7  clkb = ~clkb;   // ~71.4 MHz

  // --------------------------------------------------------------------------
  // Golden model: byte-addressed, depth = 16384 bytes (ADDR width 14)
  // --------------------------------------------------------------------------
  logic [7:0] golden [0:(1<<14)-1];

  // --------------------------------------------------------------------------
  // Helpers / Tasks
  // --------------------------------------------------------------------------
  task automatic a_write_byte(input logic [13:0] addr, input logic [7:0] data);
    // One-cycle write pulse on Port A
    @(posedge clka);
    ena   <= 1'b1;
    wea   <= 1'b1;
    addra <= addr;
    dina  <= data;

    golden[addr] = data; // update golden immediately (write is synchronous in BRAM, but this is reference)

    @(posedge clka);
    ena   <= 1'b0;
    wea   <= 1'b0;
    addra <= '0;
    dina  <= '0;
  endtask

  task automatic b_set_read_addr(input logic [13:0] addr, input logic enable);
    // Drive Port B address/enable (read data returns with 1-cycle latency)
    @(posedge clkb);
    enb   <= enable;
    addrb <= addr;
  endtask

  // --------------------------------------------------------------------------
  // Read-latency checker (1-cycle pipeline on Port B)
  //
  // On each posedge clkb:
  //   - doutb should correspond to previous cycle's (enb, addrb) when not in reset
  //   - during rstb, we skip checking and clear pipeline
  // --------------------------------------------------------------------------
  logic        prev_enb;
  logic [13:0] prev_addrb;

  always_ff @(posedge clkb) begin
    if (rstb) begin
      prev_enb   <= 1'b0;
      prev_addrb <= '0;
    end else begin
      // Check output for previous request (1-cycle latency)
      if (prev_enb) begin
        if (doutb !== golden[prev_addrb]) begin
          $error("[B-READ MISMATCH] t=%0t addr=0x%0h exp=0x%02h got=0x%02h",
                 $time, prev_addrb, golden[prev_addrb], doutb);
          $fatal(1);
        end
      end

      // Advance pipeline capture
      prev_enb   <= enb;
      prev_addrb <= addrb;
    end
  end

  // --------------------------------------------------------------------------
  // Test sequences
  // --------------------------------------------------------------------------
  initial begin
    integer i;
    logic [13:0] addr;
    logic [7:0]  data;

    // init
    ena   = 1'b0;
    wea   = 1'b0;
    addra = '0;
    dina  = '0;

    rstb  = 1'b1;
    enb   = 1'b0;
    addrb = '0;

    prev_enb   = 1'b0;
    prev_addrb = '0;

    // init golden memory
    for (i = 0; i < (1<<14); i++) golden[i] = 8'h00;

    // hold reset for a few B clocks
    repeat (4) @(posedge clkb);
    rstb <= 1'b0;

    // ----------------------------------------------------------------------
    // 1) Basic directed write/read
    // ----------------------------------------------------------------------
    $display("== Test 1: directed writes/reads ==");

    a_write_byte(14'h0000, 8'hAA);
    a_write_byte(14'h0001, 8'h55);
    a_write_byte(14'h1234, 8'hDE);
    a_write_byte(14'h3FFF, 8'h7E);

    // Issue reads (checker validates 1-cycle delayed outputs)
    b_set_read_addr(14'h0000, 1'b1);
    b_set_read_addr(14'h0001, 1'b1);
    b_set_read_addr(14'h1234, 1'b1);
    b_set_read_addr(14'h3FFF, 1'b1);
    b_set_read_addr(14'h0000, 1'b0); // disable, flush pipeline quietly

    // Let pipeline drain
    repeat (4) @(posedge clkb);

    // ----------------------------------------------------------------------
    // 2) Random writes + random reads interleaved
    // ----------------------------------------------------------------------
    $display("== Test 2: random interleaved writes/reads ==");

    for (i = 0; i < 200; i++) begin
      // random write
      addr = $urandom_range(0, (1<<14)-1);
      data = $urandom_range(0, 255);
      a_write_byte(addr, data);

      // random read request on B (may be while writes happen on A)
      addr = $urandom_range(0, (1<<14)-1);
      b_set_read_addr(addr, 1'b1);

      // occasionally insert bubbles
      if (($urandom_range(0, 3) == 0)) begin
        b_set_read_addr($urandom_range(0, (1<<14)-1), 1'b0);
      end
    end

    // Drain
    repeat (10) @(posedge clkb);

    // ----------------------------------------------------------------------
    // 3) Burst write then burst read (good for LSU-ish streaming)
    // ----------------------------------------------------------------------
    $display("== Test 3: burst write then burst read ==");

    for (i = 0; i < 256; i++) begin
      a_write_byte(14'h2000 + i[13:0], i[7:0]);
    end

    // burst read
    for (i = 0; i < 256; i++) begin
      b_set_read_addr(14'h2000 + i[13:0], 1'b1);
    end
    b_set_read_addr(14'h0000, 1'b0);
    repeat (10) @(posedge clkb);

    // ----------------------------------------------------------------------
    // 4) Reset behavior sanity (optional)
    // ----------------------------------------------------------------------
    $display("== Test 4: rstb pulse ==");

    @(posedge clkb);
    rstb <= 1'b1;
    repeat (2) @(posedge clkb);
    rstb <= 1'b0;

    // after reset, keep reading to ensure checker still works
    for (i = 0; i < 16; i++) begin
      b_set_read_addr(14'h2000 + i[13:0], 1'b1);
    end
    b_set_read_addr(14'h0000, 1'b0);
    repeat (10) @(posedge clkb);

    $display("ALL TESTS PASSED ✅");
    $finish;
  end

endmodule
