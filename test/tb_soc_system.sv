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

  task automatic do_reset();
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
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
  initial begin
    uart_rx_i = 1'b1;
    wait (rst_n);
    forever begin
      @(posedge clk);
      uart_rx_i <= uart_tx_o;
    end
  end

  // -------------------------
  // Trace output (same files as proc_tb + one peripheral file)
  // -------------------------
  integer tf_wb;
  integer tf_commit;
  integer tf_misc;
  integer tf_dispatch;
  integer tf_periph;

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
    tf_wb       = $fopen("C:\\RTL\\Han_OoO\\test\\wb.jsonl",       "w");
    tf_commit   = $fopen("C:\\RTL\\Han_OoO\\test\\commit.jsonl",   "w");
    tf_misc     = $fopen("C:\\RTL\\Han_OoO\\test\\misc.jsonl",     "w");
    tf_dispatch = $fopen("C:\\RTL\\Han_OoO\\test\\dispatch.jsonl", "w");
    tf_periph = $fopen("C:\\RTL\\Han_OoO\\test\\periph.jsonl", "a");

    if (tf_wb       == 0) $fatal(1, "Cannot open wb.jsonl");
    if (tf_commit   == 0) $fatal(1, "Cannot open commit.jsonl");
    if (tf_misc     == 0) $fatal(1, "Cannot open misc.jsonl");
    if (tf_dispatch == 0) $fatal(1, "Cannot open dispatch.jsonl");
    if (tf_periph   == 0) $fatal(1, "Cannot open periph.jsonl");
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

      if (uart_tx_o !== uart_tx_q) begin
        $fwrite(tf_periph,
          "{\"type\":\"uart_tx_edge\",\"cycle\":%0d,\"tx\":%0d}\n",
          cycle, uart_tx_o
        );
        uart_tx_q <= uart_tx_o;
      end
    end
  end

  // SPI byte sniffer:
  //   - waits for CS asserted low
  //   - samples MOSI on rising edge of SCLK (SPI mode 0 typical)
  //   - logs each byte with current DC value (command/data)
  byte cur_byte;
  int  kb;
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

  // UART TX sniffer:
  //   - decodes uart_tx_o using baud_div_mon (in clk cycles / bit)
  //   - logs bytes to periph.jsonl
  int b;
  byte val;
  initial begin : uart_sniffer
    wait (rst_n);
    forever begin
      // wait start bit (line goes low)
      wait (uart_tx_o == 1'b0);

      // move to middle of bit0
      repeat (baud_div_mon/2) @(posedge clk);

      val = 8'h00;
      for (b = 0; b < 8; b++) begin
        repeat (baud_div_mon) @(posedge clk);
        val[b] = uart_tx_o;
      end

      // stop bit
      repeat (baud_div_mon) @(posedge clk);

      $fwrite(tf_periph,
        "{\"type\":\"uart_byte\",\"cycle\":%0d,\"baud_div\":%0d,\"byte\":\"0x%02x\"}\n",
        cycle, baud_div_mon, val
      );

      // idle between bytes (avoid double-trigger if line stays low spuriously)
      repeat (baud_div_mon) @(posedge clk);
    end
  end

endmodule