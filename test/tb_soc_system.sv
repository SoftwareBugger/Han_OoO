`timescale 1ns/1ps
`include "defines.svh"
`include "periph_defines.svh"

// ============================================================
// TB: Full SoC system testbench
//   - Instantiates SoC_system_top (CPU + mem_system + peripherals)
//   - Logs the SAME commit/WB/dispatch/misc JSONL streams as proc_tb,
//     but through an extra hierarchy layer (soc_dut.cpu_inst.*)
//   - Sniffs peripheral outputs (SPI + UART) and logs them to periph.jsonl
//     while the program is driving MMIO.
//
// Notes:
//   * This TB assumes cpu_core internal debug/trace signals are named
//     the same as in proc_tb.sv (commit_entry, wb_pkt, etc.).
//   * If you renamed signals inside cpu_core, update the hierarchical
//     paths in the `CPU_*` aliases below.
// ============================================================
module tb_soc_system;

  // -------------------------
  // Clock / Reset
  // -------------------------
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk; // 100 MHz

  event console_ready_ev;
  event response_ready_ev;

  // Set this to the exact phrase your SoC prints when UART console is ready.
  // Examples: "READY\n", "> ", "UART ready\r\n"
  string CONSOLE_READY_STR = "UART console ready.> ";


  task automatic do_reset();
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
  endtask

    // ------------------------------------------------------------
    // UART host model (PC side) at the *pins*
    //   - Drives uart_rx_i (host->SoC RX)
    //   - Decodes uart_tx_o (SoC TX->host)
    // Timing is in clk cycles, using baud_div_mon (cycles/bit).
    // ------------------------------------------------------------

    event uart_cfg_ev;  // fired when firmware programs BAUD_DIV

    function automatic int bit_clks();
      // guard against 0 or crazy values
      if (baud_div_mon <= 0) bit_clks = 1;
      else                  bit_clks = baud_div_mon;
    endfunction

    task automatic uart_host_send_byte(input byte b);
      int i;
      // start bit
      uart_rx_i <= 1'b0;
      repeat (bit_clks()) @(posedge clk);

      // data bits, LSB first
      for (i = 0; i < 8; i++) begin
        uart_rx_i <= b[i];
        repeat (bit_clks()) @(posedge clk);
      end

      // stop bit
      uart_rx_i <= 1'b1;
      repeat (bit_clks()) @(posedge clk);

      // a little idle spacing (optional)
      repeat (bit_clks()) @(posedge clk);
    endtask

    task automatic uart_host_send_string(input string s);
      int k;
      for (k = 0; k < s.len(); k++) begin
        uart_host_send_byte(byte'(s[k]));
      end
    endtask

    task automatic uart_host_recv_byte(output byte b);
      int i;

      // wait for start bit
      wait (uart_tx_o == 1'b0);

      // sample in the middle of bit0
      repeat (bit_clks()/2) @(posedge clk);

      // now sample each data bit at bit boundaries
      b = 8'h00;
      for (i = 0; i < 8; i++) begin
        repeat (bit_clks()) @(posedge clk);
        b[i] = uart_tx_o;
      end

      // stop bit (ignore value, but wait it)
      repeat (bit_clks()) @(posedge clk);

      // consume a little idle time to avoid retrigger issues
      repeat (bit_clks()/2) @(posedge clk);
    endtask


  // -------------------------
  // SoC pins
  // -------------------------
  wire  spi_sclk, spi_mosi, spi_cs_n, spi_dc, spi_res_n;
  logic spi_miso;

  logic uart_rx_i;
  wire  uart_tx_o;

  // -------------------------
  // DUT: full SoC system
  // -------------------------
  SoC_system_top soc_dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .spi_sclk  (spi_sclk),
    .spi_mosi  (spi_mosi),
    .spi_miso  (spi_miso),
    .spi_cs_n  (spi_cs_n),
    .spi_dc    (spi_dc),
    .spi_res_n (spi_res_n),
    .uart_rx_i (uart_rx_i),
    .uart_tx_o (uart_tx_o)
  );

  // SPI MISO unused for OLED; tie low
  initial spi_miso = 1'b0;

  // UART loopback (optional). If you want pure "TX sniff only", comment this out.
  // initial begin
  //   uart_rx_i = 1'b1;
  //   wait (rst_n);
  //   forever begin
  //     @(posedge clk);
  //     uart_rx_i <= uart_tx_o;
  //   end
  // end

  // -------------------------
  // Trace output (same files as proc_tb + one peripheral file)
  // -------------------------
  integer tf_wb;
  integer tf_commit;
  integer tf_misc;
  integer tf_dispatch;
  integer tf_periph;
  integer tf_spi;

  longint cycle;
  int unsigned commits;
  int unsigned cycles_since_commit;

  // Paths: CPU is one layer deeper than proc_tb
  // (alias comments only; SystemVerilog doesn't support hierarchical aliasing cleanly)
  //   CPU = soc_dut.cpu_inst

  // Cast packed structs to bit-vectors before printing (VRFC friendliness)
  localparam int COMMIT_BITS  = $bits(soc_dut.cpu_inst.commit_entry);
  localparam int RECOVER_BITS = $bits(soc_dut.cpu_inst.recover_entry);
  localparam int WB_BITS      = $bits(soc_dut.cpu_inst.wb_pkt);

  logic [COMMIT_BITS-1:0]  commit_entry_bits;
  logic [RECOVER_BITS-1:0] recover_entry_bits;
  logic [WB_BITS-1:0]      wb_pkt_bits;

  always_comb begin
    commit_entry_bits  = soc_dut.cpu_inst.commit_entry;
    recover_entry_bits = soc_dut.cpu_inst.recover_entry;
    wb_pkt_bits        = soc_dut.cpu_inst.wb_pkt;
  end

  function automatic string hex32(input logic [31:0] x);
    return $sformatf("0x%08x", x);
  endfunction

  initial begin
    // Delete old file (ignore error if it doesn't exist)
    // void'($system("rm -f C:\\RTL\\Han_OoO\\test\\periph.jsonl"));
    tf_wb       = $fopen("C:\\RTL\\Han_OoO\\test\\wb.jsonl",       "w");
    tf_commit   = $fopen("C:\\RTL\\Han_OoO\\test\\commit.jsonl",   "w");
    tf_misc     = $fopen("C:\\RTL\\Han_OoO\\test\\misc.jsonl",     "w");
    tf_dispatch = $fopen("C:\\RTL\\Han_OoO\\test\\dispatch.jsonl", "w");
    tf_periph = $fopen("C:\\RTL\\Han_OoO\\test\\periph.jsonl", "a");
    tf_spi     = $fopen("C:\\RTL\\Han_OoO\\test\\spi.jsonl",     "w");

    if (tf_wb       == 0) $fatal(1, "Cannot open wb.jsonl");
    if (tf_commit   == 0) $fatal(1, "Cannot open commit.jsonl");
    if (tf_misc     == 0) $fatal(1, "Cannot open misc.jsonl");
    if (tf_dispatch == 0) $fatal(1, "Cannot open dispatch.jsonl");
    if (tf_periph   == 0) $fatal(1, "Cannot open periph.jsonl");
    if (tf_spi      == 0) $fatal(1, "Cannot open spi.jsonl");
  end

  // -------------------------
  // Run control
  // -------------------------
  initial begin
    cycle = 0;
    commits = 0;
    cycles_since_commit = 0;

    do_reset();

    // Run bounded time if no explicit done condition yet
    repeat (2000000000) @(posedge clk);

    $display("TIMEOUT: no finish condition hit");
    $fclose(tf_wb);
    $fclose(tf_commit);
    $fclose(tf_misc);
    $fclose(tf_dispatch);
    $fclose(tf_periph);
    $fclose(tf_spi);
    $finish;
  end

  always_ff @(posedge clk) begin
    cycle <= cycle + 1;
  end

  // -------------------------
  // CPU trace events (same semantics as proc_tb)
  // -------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      commits <= 0;
      cycles_since_commit <= 0;
    end else begin
      cycles_since_commit <= cycles_since_commit + 1;

      // Redirect -> misc.jsonl
      if (soc_dut.cpu_inst.redirect_valid) begin
        $fwrite(tf_misc,
          "{\"type\":\"redirect\",\"cycle\":%0d,\"redirect_pc\":\"%s\"}\n",
          cycle, hex32(soc_dut.cpu_inst.redirect_pc)
        );
      end

      // Recover / flush -> misc.jsonl
      if (soc_dut.cpu_inst.recover_valid) begin
        $fwrite(tf_misc,
          "{\"type\":\"recover\",\"cycle\":%0d,\"recover_rob\":%0d,\"recover_entry_hex\":\"0x%0x\"}\n",
          cycle, soc_dut.cpu_inst.recover_rob_idx, recover_entry_bits
        );
      end

      if (soc_dut.cpu_inst.flush_valid) begin
        $fwrite(tf_misc,
          "{\"type\":\"flush\",\"cycle\":%0d,\"flush_rob\":%0d,\"flush_epoch\":%0d}\n",
          cycle, soc_dut.cpu_inst.flush_rob_idx, soc_dut.cpu_inst.flush_epoch
        );
      end

      // WB -> wb.jsonl
      if (soc_dut.cpu_inst.wb_valid && soc_dut.cpu_inst.wb_ready) begin
        $fwrite(tf_wb,
          "{\"type\":\"wb\",\"cycle\":%0d,\"pc\":\"0x%08x\",\"rob\":%0d,\"epoch\":%0d,\"uses_rd\":%0d,\"prd_new\":%0d,\"data_valid\":%0d,\"data\":\"0x%08x\",\"done\":%0d,\"is_branch\":%0d,\"mispredict\":%0d,\"redirect\":%0d,\"redirect_pc\":\"0x%08x\",\"act_taken\":%0d,\"is_load\":%0d,\"is_store\":%0d,\"mem_exc\":%0d,\"mem_addr\":\"0x%08x\"}\n",
          cycle,
          soc_dut.cpu_inst.wb_pkt.pc,
          soc_dut.cpu_inst.wb_pkt.rob_idx, soc_dut.cpu_inst.wb_pkt.epoch,
          soc_dut.cpu_inst.wb_pkt.uses_rd, soc_dut.cpu_inst.wb_pkt.prd_new,
          soc_dut.cpu_inst.wb_pkt.data_valid, soc_dut.cpu_inst.wb_pkt.data, soc_dut.cpu_inst.wb_pkt.done,
          soc_dut.cpu_inst.wb_pkt.is_branch, soc_dut.cpu_inst.wb_pkt.mispredict, soc_dut.cpu_inst.wb_pkt.redirect,
          soc_dut.cpu_inst.wb_pkt.redirect_pc, soc_dut.cpu_inst.wb_pkt.act_taken,
          soc_dut.cpu_inst.wb_pkt.is_load, soc_dut.cpu_inst.wb_pkt.is_store,
          soc_dut.cpu_inst.wb_pkt.mem_exc, soc_dut.cpu_inst.wb_pkt.mem_addr
        );
      end

      // Commit -> commit.jsonl
      if (soc_dut.cpu_inst.commit_valid && soc_dut.cpu_inst.commit_ready && ~soc_dut.cpu_inst.recover_valid) begin
        commits <= commits + 1;
        cycles_since_commit <= 0;

        $fwrite(tf_commit,
          "{\"type\":\"commit\",\"cycle\":%0d,\"commit_rob\":%0d,\"global_epoch\":%0d,\"valid\":%0d,\"done\":%0d,\"epoch\":%0d,\"uses_rd\":%0d,\"rd_arch\":%0d,\"pd_new\":\"0x%0x\",\"pd_old\":\"0x%0x\",\"is_branch\":%0d,\"mispredict\":%0d,\"is_load\":%0d,\"is_store\":%0d,\"pc\":\"0x%08x\",\"data\":\"0x%08x\"}\n",
          cycle,
          soc_dut.cpu_inst.commit_rob_idx,
          soc_dut.cpu_inst.global_epoch,
          soc_dut.cpu_inst.commit_entry.valid,
          soc_dut.cpu_inst.commit_entry.done,
          soc_dut.cpu_inst.commit_entry.epoch,
          soc_dut.cpu_inst.commit_entry.uses_rd,
          soc_dut.cpu_inst.commit_entry.rd_arch,
          soc_dut.cpu_inst.commit_entry.pd_new,
          soc_dut.cpu_inst.commit_entry.pd_old,
          soc_dut.cpu_inst.commit_entry.is_branch,
          soc_dut.cpu_inst.commit_entry.mispredict,
          soc_dut.cpu_inst.commit_entry.is_load,
          soc_dut.cpu_inst.commit_entry.is_store,
          soc_dut.cpu_inst.commit_entry.pc,
          soc_dut.cpu_inst.commit_entry.uses_rd ? soc_dut.cpu_inst.prf_inst.mem[soc_dut.cpu_inst.commit_entry.pd_new] : 0
        );

        if (commits > 50000000) begin
          $display("Stopping: commit limit reached");
          $finish;
        end
      end

      // Dispatch -> dispatch.jsonl
      if (soc_dut.cpu_inst.disp_valid && soc_dut.cpu_inst.disp_ready) begin
        $fwrite(tf_dispatch,
          "{\"type\":\"dispatch\",\"cycle\":%0d,\"pc\":\"0x%08x\",\"op\":%0d,\"uop_class\":%0d,\"branch_type\":%0d,\"mem_size\":%0d,\"uses_rs1\":%0d,\"uses_rs2\":%0d,\"uses_rd\":%0d,\"rs1_arch\":%0d,\"rs2_arch\":%0d,\"rd_arch\":%0d,\"imm\":\"0x%08x\",\"pred_taken\":%0d,\"pred_target\":\"0x%08x\",\"rob\":%0d,\"epoch\":%0d,\"prs1\":%0d,\"rdy1\":%0d,\"prs2\":%0d,\"rdy2\":%0d,\"prd_new\":%0d}\n",
          cycle,
          soc_dut.cpu_inst.disp_uop.bundle.pc,
          soc_dut.cpu_inst.disp_uop.bundle.op,
          soc_dut.cpu_inst.disp_uop.bundle.uop_class,
          soc_dut.cpu_inst.disp_uop.bundle.branch_type,
          soc_dut.cpu_inst.disp_uop.bundle.mem_size,
          soc_dut.cpu_inst.disp_uop.bundle.uses_rs1,
          soc_dut.cpu_inst.disp_uop.bundle.uses_rs2,
          soc_dut.cpu_inst.disp_uop.bundle.uses_rd,
          soc_dut.cpu_inst.disp_uop.bundle.rs1_arch,
          soc_dut.cpu_inst.disp_uop.bundle.rs2_arch,
          soc_dut.cpu_inst.disp_uop.bundle.rd_arch,
          soc_dut.cpu_inst.disp_uop.bundle.imm,
          soc_dut.cpu_inst.disp_uop.bundle.pred_taken,
          soc_dut.cpu_inst.disp_uop.bundle.pred_target,
          soc_dut.cpu_inst.disp_uop.rob_idx,
          soc_dut.cpu_inst.disp_uop.epoch,
          soc_dut.cpu_inst.disp_uop.prs1,
          soc_dut.cpu_inst.disp_uop.rdy1,
          soc_dut.cpu_inst.disp_uop.prs2,
          soc_dut.cpu_inst.disp_uop.rdy2,
          soc_dut.cpu_inst.disp_uop.prd_new
        );
      end
    end
  end

  // -------------------------
  // Peripheral sniffing
  // -------------------------

  // Track BAUD_DIV programmed by CPU (default if never written)
  int baud_div_mon;
  logic [31:0] mmio_st_addr;
  logic [31:0] mmio_st_wdata32;

  // Helper: extract the correct 32b word from a 64b store beat, based on addr[2]
  function automatic logic [31:0] store_wdata32(input logic [31:0] addr, input logic [63:0] wdata64);
    if (addr[2]) store_wdata32 = wdata64[63:32];
    else         store_wdata32 = wdata64[31:0];
  endfunction

  // Tap the CPU->mem_system interface inside SoC to observe MMIO writes
  // Update baud_div_mon when program writes UART_REG_BAUD_DIV.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      baud_div_mon <= 16; // safe default for your earlier tests
    end else begin
      if (soc_dut.dmem_cpu.st_valid && soc_dut.dmem_cpu.st_ready) begin
        mmio_st_addr   = soc_dut.dmem_cpu.st_addr;
        mmio_st_wdata32 = store_wdata32(mmio_st_addr, soc_dut.dmem_cpu.st_wdata);

        if (mmio_st_addr == (UART_BASE + UART_REG_BAUD_DIV)) begin
          baud_div_mon <= mmio_st_wdata32;
          -> uart_cfg_ev;
          $fwrite(tf_periph,
            "{\"type\":\"uart_cfg\",\"cycle\":%0d,\"baud_div\":%0d}\n",
            cycle, mmio_st_wdata32
          );
        end

      end
    end
  end

  // Log GPIO/control pin changes for SPI + UART line changes (raw)
  logic spi_cs_n_q, spi_dc_q, spi_res_n_q;
  logic uart_tx_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spi_cs_n_q  <= 1'b1;
      spi_dc_q    <= 1'b1;
      spi_res_n_q <= 1'b1;
      uart_tx_q   <= 1'b1;
    end else begin
      if (spi_cs_n !== spi_cs_n_q) begin
        $fwrite(tf_periph,
          "{\"type\":\"spi_cs\",\"cycle\":%0d,\"cs_n\":%0d}\n",
          cycle, spi_cs_n
        );
        spi_cs_n_q <= spi_cs_n;
      end

      if (spi_dc !== spi_dc_q) begin
        $fwrite(tf_periph,
          "{\"type\":\"spi_dc\",\"cycle\":%0d,\"dc\":%0d}\n",
          cycle, spi_dc
        );
        spi_dc_q <= spi_dc;
      end

      if (spi_res_n !== spi_res_n_q) begin
        $fwrite(tf_periph,
          "{\"type\":\"spi_res_n\",\"cycle\":%0d,\"res_n\":%0d}\n",
          cycle, spi_res_n
        );
        spi_res_n_q <= spi_res_n;
      end

      // if (uart_tx_o !== uart_tx_q) begin
      //   $fwrite(tf_periph,
      //     "{\"type\":\"uart_tx_edge\",\"cycle\":%0d,\"tx\":%0d}\n",
      //     cycle, uart_tx_o
      //   );
      //   uart_tx_q <= uart_tx_o;
      // end
    end
  end

  // SPI byte sniffer:
  //   - waits for CS asserted low
  //   - samples MOSI on rising edge of SCLK (SPI mode 0 typical)
  //   - logs each byte with current DC value (command/data)
  byte cur_byte;
  int  kb;
  localparam [32:0] spi_msg = 32'hDEADBEEF; // example SPI message to send
  initial begin : spi_sniffer
    wait (rst_n);
    forever begin
      // wait for CS assertion
      wait (spi_cs_n == 1'b0);
      while (spi_cs_n == 1'b0) begin
        cur_byte = 8'h00;
        for (kb = 0; kb < 8; kb++) begin
          @(posedge spi_sclk);
          cur_byte = {cur_byte[6:0], spi_mosi};
        end
        $fwrite(tf_periph,
          "{\"type\":\"spi_byte\",\"cycle\":%0d,\"dc\":%0d,\"byte\":\"0x%02x\"}\n",
          cycle, spi_dc, cur_byte
        );
      end
    end
  end

  // THIS MAKES SPI BUGGY??
  int kb2;
  int spi_index; 
  int byte_count;
  initial begin : spi_sender
    wait (rst_n);
    forever begin
      // wait for CS assertion
      wait (spi_cs_n == 1'b0);
      byte_count = 0;
      while (spi_cs_n == 1'b0) begin
        // cur_byte = 8'h00;
        for (kb2 = 0; kb2 < 8; kb2++) begin
          spi_miso <= spi_msg[31 - (kb2 + 8*byte_count)]; // example MISO response
          @(negedge spi_sclk);
          // @(posedge spi_sclk);
          // cur_byte = {cur_byte[6:0], spi_mosi};
        end
        // $fwrite(tf_periph,
        //   "{\"type\":\"spi_byte\",\"cycle\":%0d,\"dc\":%0d,\"byte\":\"0x%02x\"}\n",
        //   cycle, spi_dc, cur_byte
        // );
        byte_count = byte_count + 1;
        if (byte_count >=4) begin
          byte_count = 0;
        end
      end
    end
  end

  // UART TX sniffer:
  //   - decodes uart_tx_o using baud_div_mon (in clk cycles / bit)
  //   - logs bytes to periph.jsonl
  // Example: replace soc_dut.uart_inst... with your real instance path
  // always_ff @(posedge soc_dut.u_mem_system.u_uart.rx_rdy_core) begin
  //   if (rst_n) begin
  //     $fwrite(tf_periph,
  //       "{\"type\":\"uart_rx_byte\",\"cycle\":%0d,\"byte\":\"0x%04x\"}\n",
  //       cycle, soc_dut.u_mem_system.u_uart.rx_data_core
  //     );
  //   end
  // end

  // int b;
  // byte val;
  // initial begin : uart_sniffer
  //   wait (rst_n);
  //   forever begin
  //     // wait start bit (line goes low)
  //     wait (uart_tx_o == 1'b0);

  //     // move to middle of bit0
  //     repeat (baud_div_mon/2) @(posedge clk);

  //     val = 8'h00;
  //     for (b = 0; b < 8; b++) begin
  //       repeat (baud_div_mon) @(posedge clk);
  //       val[b] = uart_tx_o;
  //     end

  //     // stop bit
  //     repeat (baud_div_mon) @(posedge clk);

  //     $fwrite(tf_periph,
  //       "{\"type\":\"uart_byte\",\"cycle\":%0d,\"baud_div\":%0d,\"byte\":\"0x%02x\"}\n",
  //       cycle, baud_div_mon, val
  //     );

  //     // idle between bytes (avoid double-trigger if line stays low spuriously)
  //     repeat (baud_div_mon) @(posedge clk);
  //   end
  // end

  // ------------------------------------------------------------
// UART load monitor (LSU memory response -> uart_ld.jsonl)
// Captures when ld_resp_valid & ld_resp_ready (response accepted)
// Logs response data + the tracked ld_addr_q, filtered to UART MMIO range.
// Hierarchy per your request: soc_dut.cpu_inst.execute_inst.lsu_u
// ------------------------------------------------------------

    integer tf_uart_ld;

    initial begin
    tf_uart_ld = $fopen("C:\\RTL\\Han_OoO\\test\\uart_ld.jsonl", "w");
    if (tf_uart_ld == 0) begin
        $display("ERROR: could not open uart_ld.jsonl");
        $finish;
    end
    end

    // Adjust if your UART window differs
    localparam logic [31:0] UART_BASE = 32'h8000_1000;
    localparam logic [31:0] UART_MASK = 32'hFFFF_F000; // 4KB window

    logic [31:0] resp_addr;
    logic [63:0] resp_data;

    always_ff @(posedge clk) begin
    if (!rst_n) begin
        // nothing
    end else begin
        // Memory response accepted into LSU (load response handshake)
        if (soc_dut.cpu_inst.execute_inst.lsu_u.wb_buf_enq) begin


        // Address associated with this response (tracked by LSU)
        resp_addr = soc_dut.cpu_inst.execute_inst.lsu_u.ld_addr_q;

        // Raw 64-bit response data from memory/MMIO
        resp_data = soc_dut.cpu_inst.execute_inst.lsu_u.dmem.ld_resp_data;

        // Filter: only UART MMIO reads (UART_BASE 4KB page)
        if ( (resp_addr) == UART_BASE ) begin
            $fwrite(tf_uart_ld,
            "{\"type\":\"uart_ld\",\"cycle\":%0d,\"addr\":\"0x%08x\",\"data\":\"0x%016x\"}\n",
            cycle, resp_addr, resp_data
            );
        end
        end
    end
    end

  // ------------------------------------------------------------
  // Host behavior:
  //   - Wait until firmware programs baud_div
  //   - Send some bytes into SoC RX
  //   - Decode SoC TX and log as uart_tx_byte
  // ------------------------------------------------------------
  byte rx_b;
  string tb_hello_str = "hello from tb\n";
  string tb_ping_str  = "ping\n";
  string prog_prefix = ".You typed: ";
  string prog_suffix = ".> ";
  initial begin : uart_host_threads
    

    wait (rst_n);
    // wait until firmware sets baud, so timing matches
    @uart_cfg_ev;

    // Give firmware a moment to finish init
    repeat (2000) @(posedge clk);

    // Wait until SoC prints the ready marker/prompt
    @console_ready_ev;

    // Example: send a line (your firmware should read & respond/echo)
    uart_host_send_string(tb_hello_str);

    
    @response_ready_ev;

    // Then optionally keep feeding bytes periodically
    forever begin
      uart_host_send_string(tb_ping_str);
      
      @response_ready_ev;
    end

    repeat (50000) @(posedge clk);
  end

  // Decode SoC TX forever and log to periph.jsonl
  byte b;

  // small rolling buffer to detect the "ready" banner/prompt
  string rx_hist = "";
  int    max_hist = 256;
  bit    ready_seen = 0;
  int L;
  initial begin : uart_tx_decoder

    wait (rst_n);
    @uart_cfg_ev;

    for (int i = 0; i < CONSOLE_READY_STR.len(); i++) begin
      uart_host_recv_byte(b);

      // log every TX byte
      $fwrite(tf_periph,
        "{\"type\":\"uart_tx_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\",\"char\":\"%s\"}\n",
        cycle, b, (b >= 32 && b < 127) ? {byte'(b)} : "."
      );
    end
    -> console_ready_ev;

    for (int i = 0; i < prog_prefix.len() + tb_hello_str.len() + prog_suffix.len() - 1; i++) begin
      uart_host_recv_byte(b);
      // log every TX byte
      $fwrite(tf_periph,
        "{\"type\":\"uart_tx_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\",\"char\":\"%s\"}\n",
        cycle, b, (b >= 32 && b < 127) ? {byte'(b)} : "."
      );
    end
    -> response_ready_ev;

    forever begin
      for (int i = 0; i < prog_prefix.len() + tb_ping_str.len() + prog_suffix.len() - 1; i++) begin
        uart_host_recv_byte(b);
        // log every TX byte
        $fwrite(tf_periph,
          "{\"type\":\"uart_tx_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\",\"char\":\"%s\"}\n",
          cycle, b, (b >= 32 && b < 127) ? {byte'(b)} : "."
        );
      end
      -> response_ready_ev;
    end

    // // build history (keep raw bytes; for non-printables keep them as-is or map to '.')
    // // easiest: append exact byte value as a 1-char string when printable, else append the byte anyway
    // // If you want to match "\n" etc, make sure your CONSOLE_READY_STR matches what firmware prints.
    // rx_hist = {rx_hist, {byte'(b)}};

    // // cap history
    // if (rx_hist.len() > max_hist)
    //   rx_hist = rx_hist.substr(rx_hist.len()-max_hist, max_hist);

    // // detect the ready string once
    // if (!ready_seen) begin
    //   L = CONSOLE_READY_STR.len();
    //   if (L > 0 && rx_hist.len() >= L) begin
    //     if (rx_hist.substr(rx_hist.len()-L, L) == CONSOLE_READY_STR) begin
    //       ready_seen = 1;
    //       $fwrite(tf_periph,
    //         "{\"type\":\"uart_console_ready\",\"cycle\":%0d,\"str\":\"%s\"}\n",
    //         cycle, CONSOLE_READY_STR
    //       );
          
    //     end
    //   end
    // end
  end

  // ============================================================
  // ============================================================
  // SPI monitor + MISO responder
  // - Captures SPI_CTRL[0] (pos_edge) from MMIO writes
  // - Samples MOSI/MISO on opposite edge (stable sampling)
  // - Logs to a separate file: spi.jsonl (opened above)
  // - Optionally drives MISO with a simple response stream
  // ============================================================

  // -----------------------------
  // EDIT THIS: your MMIO address for SPI_CTRL
  // If your TB mmio_addr is an OFFSET (not absolute), set it to SPI_CTRL offset.
  // If your TB mmio_addr is absolute, set it to (SPI_BASE + SPI_CTRL).
  // -----------------------------
  localparam logic [31:0] SPI_CTRL_ADDR = 32'h0000_0008;

  // Enable/disable TB driving MISO (keep 0 if you only want sniffing)
  bit tb_spi_drive_miso = 1'b1;

  // -----------------------------
  // Shadow of SPI CTRL (captured from MMIO write)
  // -----------------------------
  logic [31:0] tb_spi_ctrl_shadow;
  logic        tb_spi_ctrl_seen;

  // Capture SPI_CTRL writes from the SPI MMIO block
  // NOTE: adjust this hierarchy if your mem_system path differs.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tb_spi_ctrl_shadow <= '0;
      tb_spi_ctrl_seen   <= 1'b0;
    end else begin
      if (soc_dut.u_mem_system.spi_mmio.mmio_valid &&
          soc_dut.u_mem_system.spi_mmio.mmio_ready &&
          soc_dut.u_mem_system.spi_mmio.mmio_we    &&
          (soc_dut.u_mem_system.spi_mmio.mmio_addr == SPI_CTRL_ADDR)) begin
        tb_spi_ctrl_shadow <= soc_dut.u_mem_system.spi_mmio.mmio_wdata;
        tb_spi_ctrl_seen   <= 1'b1;
        $display("[%0t] TB captured SPI_CTRL write: 0x%08x (pos_edge=%0d)",
                 $time, soc_dut.u_mem_system.spi_mmio.mmio_wdata,
                 soc_dut.u_mem_system.spi_mmio.mmio_wdata[0]);
      end
    end
  end

  // -----------------------------
  // SPI monitor state
  // -----------------------------
  typedef enum int { EDGE_POSEDGE = 0, EDGE_NEGEDGE = 1 } spi_edge_e;

  event ev_spi_mosi_byte;
  event ev_spi_miso_byte;
  event ev_spi_any_byte;
  event ev_spi_slave_tx_byte;

  byte spi_last_mosi;
  byte spi_last_miso;
  byte spi_last_slave_tx;

  byte spi_mosi_q[$];
  byte spi_miso_q[$];

  // Response stream for MISO (TB as slave).
  // You can push bytes into this queue from other TB code if you want.
  byte spi_resp_q[$];

  // Extract pos_edge bit from CTRL[0]
  function automatic bit spi_pos_edge_from_ctrl(input logic [31:0] spi_ctrl);
    return spi_ctrl[0];
  endfunction

  // If pos_edge=1, your controller updates on posedge and is stable on negedge -> sample on negedge.
  // If pos_edge=0, your controller updates on negedge and is stable on posedge -> sample on posedge.
  bit pos_edge;
  function automatic spi_edge_e spi_sample_edge_from_ctrl(input logic [31:0] spi_ctrl);
    pos_edge = spi_pos_edge_from_ctrl(spi_ctrl);
    return pos_edge ? EDGE_NEGEDGE : EDGE_POSEDGE;
  endfunction

  // Helper: wait for a selected SCLK edge
  task automatic spi_wait_edge(input spi_edge_e edge_sel, input logic sclk);
    if (edge_sel == EDGE_POSEDGE) @(posedge sclk);
    else                          @(negedge sclk);
  endtask

  // Capture one byte (MSB-first) assuming CS is already low.
  task automatic spi_capture_byte_while_cs_low(
    input  spi_edge_e edge_sel,
    input  logic cs_n,
    input  logic sclk,
    input  logic sdata,
    output byte  out_b,
    output bit   ok
  );
    out_b = 8'h00;
    ok    = 1'b0;

    if (cs_n) return;

    for (int i = 7; i >= 0; i--) begin
      spi_wait_edge(edge_sel, sclk);
      if (cs_n) return;
      out_b[i] = sdata;
    end

    ok = 1'b1;
  endtask

  // Monitor MOSI stream while CS is low (logs ALL bytes in a burst)
  byte b_0;
  bit  ok_0;
  task automatic spi_monitor_mosi(
    input spi_edge_e edge_sel,
    input logic cs_n,
    input logic sclk,
    input logic mosi
  );
    forever begin
      @(negedge cs_n);
      while (!cs_n) begin
        spi_capture_byte_while_cs_low(edge_sel, cs_n, sclk, mosi, b_0, ok_0);
        if (!ok_0) break;

        spi_last_mosi = b_0;
        spi_mosi_q.push_back(b_0);
        -> ev_spi_mosi_byte;
        -> ev_spi_any_byte;

        // JSON log (separate file)
        $fwrite(tf_spi,
          "{\"type\":\"spi_mosi_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\",\"dc\":%0d}\n",
          cycle, b_0, spi_dc
        );

        $display("[%0t] SPI MOSI byte: 0x%02x (dc=%0d)", $time, b_0, spi_dc);
      end
    end
  endtask

  byte b_1;
  bit  ok_1;
  // Monitor MISO stream while CS is low (logs ALL bytes in a burst)
  task automatic spi_monitor_miso(
    input spi_edge_e edge_sel,
    input logic cs_n,
    input logic sclk,
    input logic miso
  );
    forever begin
      @(negedge cs_n);
      while (!cs_n) begin
        spi_capture_byte_while_cs_low(edge_sel, cs_n, sclk, miso, b_1, ok_1);
        if (!ok_1) break;

        spi_last_miso = b_1;
        spi_miso_q.push_back(b_1);
        -> ev_spi_miso_byte;
        -> ev_spi_any_byte;

        $fwrite(tf_spi,
          "{\"type\":\"spi_miso_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\"}",
          cycle, b_1
        );

        $display("[%0t] SPI MISO byte: 0x%02x", $time, b_1);
      end
    end
  endtask

  // Wait helpers (UART-style)
  task automatic wait_spi_mosi_byte(input byte expected);
    forever begin
      @ev_spi_mosi_byte;
      if (spi_last_mosi == expected) return;
    end
  endtask

  task automatic wait_spi_miso_byte(input byte expected);
    forever begin
      @ev_spi_miso_byte;
      if (spi_last_miso == expected) return;
    end
  endtask

  // Default response pattern for MISO
  task automatic spi_fill_default_resp_q();
    spi_resp_q.delete();
    // repeating pattern: AA 55 A5 5A ...
    spi_resp_q.push_back(8'hAA);
    spi_resp_q.push_back(8'h55);
    spi_resp_q.push_back(8'hA5);
    spi_resp_q.push_back(8'h5A);
    spi_resp_q.push_back(8'hDE);
    spi_resp_q.push_back(8'hAD);
    spi_resp_q.push_back(8'hBE);
    spi_resp_q.push_back(8'hEF);
  endtask

  // Simple SPI slave that shifts out bytes on MISO while CS is low.
  // - Drives on the OPPOSITE edge of the controller's sampling edge (so master samples stable data).
  // - Consumes bytes from spi_resp_q; if empty, refills with a default pattern.
  spi_edge_e drive_edge;
  byte      cur;
  task automatic spi_slave_drive_miso_stream(
    input spi_edge_e samp_edge,
    input logic cs_n,
    input logic sclk
  );

    drive_edge = (samp_edge == EDGE_POSEDGE) ? EDGE_NEGEDGE : EDGE_POSEDGE;

    forever begin
      wait(cs_n == 1'b0);

      // if (!tb_spi_drive_miso) begin
      //   // Just hold low while CS asserted
      //   while (!cs_n) begin
      //     spi_miso <= 1'b0;
      //     @(posedge sclk or negedge sclk or posedge cs_n);
      //   end
      //   spi_miso <= 1'b0;
      //   continue;
      // end

      if (spi_resp_q.size() == 0) spi_fill_default_resp_q();

      // -------- First byte of the burst --------
      cur = (spi_resp_q.size() != 0) ? spi_resp_q.pop_front() : 8'h00;
      spi_miso <= cur[7];

      spi_last_slave_tx = cur;
      -> ev_spi_slave_tx_byte;
      $fwrite(tf_spi,
        "{\"type\":\"spi_slave_tx_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\"}\n",
        cycle, cur
      );

      // Shift bits [7:0]
      for (int i = 7; i > 0; i--) begin
        spi_wait_edge(samp_edge, sclk);  if (cs_n) break;
        spi_wait_edge(drive_edge, sclk); if (cs_n) break;
        spi_miso <= cur[i-1];
      end
      spi_wait_edge(samp_edge, sclk); if (cs_n) begin
        spi_miso <= 1'b0;
        continue;
      end

      // -------- Remaining bytes while CS stays low --------
      while (!cs_n) begin
        // Prepare next byte on the drive edge
        spi_wait_edge(drive_edge, sclk); if (cs_n) break;

        if (spi_resp_q.size() == 0) spi_fill_default_resp_q();
        cur = (spi_resp_q.size() != 0) ? spi_resp_q.pop_front() : 8'h00;

        spi_miso <= cur[7];

        spi_last_slave_tx = cur;
        -> ev_spi_slave_tx_byte;
        $fwrite(tf_spi,
          "{\"type\":\"spi_slave_tx_byte\",\"cycle\":%0d,\"byte\":\"0x%02x\"}\n",
          cycle, cur
        );

        for (int i = 7; i > 0; i--) begin
          spi_wait_edge(samp_edge, sclk);  if (cs_n) break;
          spi_wait_edge(drive_edge, sclk); if (cs_n) break;
          spi_miso <= cur[i-1];
        end
        spi_wait_edge(samp_edge, sclk); if (cs_n) break;
      end

      spi_miso <= 1'b0;
    end
  endtask

  // -----------------------------
  // Start monitors automatically once SPI_CTRL has been programmed
  // -----------------------------
  initial begin : start_spi_monitors_and_slave
    spi_edge_e samp;

    // Wait until software sets SPI_CTRL at least once
    wait (tb_spi_ctrl_seen);

    samp = spi_sample_edge_from_ctrl(tb_spi_ctrl_shadow);

    $display("[%0t] SPI armed: SPI_CTRL=0x%08x pos_edge=%0d -> sampling on %s",
             $time, tb_spi_ctrl_shadow, tb_spi_ctrl_shadow[0],
             (samp == EDGE_POSEDGE) ? "posedge" : "negedge");

    // Start monitors + optional MISO slave
    fork
      spi_monitor_mosi(samp, spi_cs_n, spi_sclk, spi_mosi);
      spi_monitor_miso(samp, spi_cs_n, spi_sclk, spi_miso);
      spi_slave_drive_miso_stream(samp, spi_cs_n, spi_sclk);
    join_none
  end
endmodule
