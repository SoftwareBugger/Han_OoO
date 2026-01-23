`timescale 1ns/1ps

// tb_cpu_core.sv
//
// Fast SV-only verification skeleton (no cocotb):
//   1) Optionally run your Python generator (insn_gen.py) to produce prog.hex
//   2) Instantiate cpu_core + imem + dmem_model (same pattern as SoC_top)
//   3) Log JSONL events into:
//        - wb.jsonl     (writeback stream)
//        - commit.jsonl (commit/retire stream)
//        - misc.jsonl   (redirect/recover/flush stream)
//   4) Python checker reads jsonl offline and compares against ISS
//
// Vivado VRFC compatibility:
//   - Use ONLY double-quoted strings for format (no stray single quotes)
//   - Prefer %0x over %0h
//   - Cast packed structs to bit-vectors before printing

module tb_cpu_core;

  // -------------------------
  // Clock / Reset
  // -------------------------
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk; // 100 MHz

  task automatic do_reset();
    rst_n = 1'b0;

    // hold reset for N full cycles
    repeat (20) @(posedge clk);

    // release reset *between* clock edges
    @(negedge clk);
    rst_n = 1'b1;

    // give some cycles post-reset
    repeat (5) @(posedge clk);
  endtask


  // -------------------------
  // IFs (must match your design)
  // -------------------------
  dmem_if #(.LDTAG_W(4)) dmem_cpu();
  imem_if imem();

  // -------------------------
  // DUT
  // -------------------------
  cpu_core dut (
    .clk  (clk),
    .rst_n(rst_n),
    .dmem (dmem_cpu),
    .imem (imem)
  );

  // -------------------------
  // Program / Memory models (same as SoC_top style)
  // -------------------------
  parameter bit asm = 0; // 0 = use compiled prog.hex, 1 = use asm-generated prog.hex
  localparam string IMEM_HEX = asm ? "C:\\RTL\\Han_OoO\\prog.hex" : "C:\\RTL\\Han_OoO\\sw\\build\\t03_st_queue_pressure.hex";

  imem #(
    .MEM_WORDS(8192),
    .HEXFILE(IMEM_HEX),
    .LATENCY(1),
    .RESP_FIFO_DEPTH(4)
  ) imem_inst (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (imem.imem_req_valid),
    .req_ready (imem.imem_req_ready),
    .req_addr  (imem.imem_req_addr),
    .resp_valid(imem.imem_resp_valid),
    .resp_ready(imem.imem_resp_ready),
    .resp_inst (imem.imem_resp_inst)
  );

  dmem_model #(
    .MEM_SIZE_KB         (64),
    .LD_LATENCY_MAX      (2),
    .ST_LATENCY          (0)
  ) dmem_inst (
    .clk  (clk),
    .rst_n(rst_n),
    .dmem (dmem_cpu)
  );

  // -------------------------
  // Trace output (SPLIT FILES)
  // -------------------------
  integer tf_wb;
  integer tf_commit;
  integer tf_misc;
  integer tf_dispatch;


  longint cycle;
  int unsigned commits;
  int unsigned cycles_since_commit;

  // Cast packed structs to bit-vectors before printing (VRFC friendliness)
  logic [$bits(dut.commit_entry)-1:0]  commit_entry_bits;
  logic [$bits(dut.recover_entry)-1:0] recover_entry_bits;
  logic [$bits(dut.wb_pkt)-1:0]        wb_pkt_bits;

  always_comb begin
    commit_entry_bits  = dut.commit_entry;
    recover_entry_bits = dut.recover_entry;
    wb_pkt_bits        = dut.wb_pkt;
  end

  function automatic string hex32(input logic [31:0] x);
    return $sformatf("0x%08x", x);
  endfunction

  initial begin
    tf_wb     = $fopen("C:\\RTL\\Han_OoO\\test\\wb.jsonl", "w");
    tf_commit = $fopen("C:\\RTL\\Han_OoO\\test\\commit.jsonl", "w");
    tf_misc   = $fopen("C:\\RTL\\Han_OoO\\test\\misc.jsonl", "w");
    tf_dispatch = $fopen("C:\\RTL\\Han_OoO\\test\\dispatch.jsonl", "w");

    if (tf_wb     == 0) $fatal(1, "Cannot open wb.jsonl");
    if (tf_commit == 0) $fatal(1, "Cannot open commit.jsonl");
    if (tf_misc   == 0) $fatal(1, "Cannot open misc.jsonl");
    if (tf_dispatch == 0) $fatal(1, "Cannot open dispatch.jsonl");
  end

  // -------------------------
  // Run control
  // -------------------------
  initial begin
    cycle = 0;
    commits = 0;
    cycles_since_commit = 0;

    // Optional: generate program before simulation begins
    // Uncomment if your simulator supports $system and python is on PATH.
    // int rc;
    // rc = $system("python3 insn_gen.py");
    // if (rc != 0) $fatal(1, "insn_gen.py failed");

    do_reset();

    // Run bounded time if no explicit done condition yet
    repeat (2000000000) @(posedge clk);

    $display("TIMEOUT: no finish condition hit");
    $fclose(tf_wb);
    $fclose(tf_commit);
    $fclose(tf_misc);
    $fclose(tf_dispatch);
    $finish;
  end

  always_ff @(posedge clk) begin
    cycle <= cycle + 1;
  end

  // -------------------------
  // Trace events
  // -------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      commits <= 0;
      cycles_since_commit <= 0;
    end else begin
      cycles_since_commit <= cycles_since_commit + 1;

      // Redirect event -> misc.jsonl
      if (dut.redirect_valid) begin
        $fwrite(tf_misc,
          "{\"type\":\"redirect\",\"cycle\":%0d,\"redirect_pc\":\"%s\"}\n",
          cycle, hex32(dut.redirect_pc)
        );
      end

      // Recovery / flush events -> misc.jsonl
      if (dut.recover_valid) begin
        $fwrite(tf_misc,
          "{\"type\":\"recover\",\"cycle\":%0d,\"recover_rob\":%0d,\"recover_entry_hex\":\"0x%0x\"}\n",
          cycle, dut.recover_rob_idx, recover_entry_bits
        );
      end

      if (dut.flush_valid) begin
        $fwrite(tf_misc,
          "{\"type\":\"flush\",\"cycle\":%0d,\"flush_rob\":%0d,\"flush_epoch\":%0d}\n",
          cycle, dut.flush_rob_idx, dut.flush_epoch
        );
      end

      // WB events -> wb.jsonl
      if (dut.wb_valid && dut.wb_ready) begin
        $fwrite(tf_wb,
          "{\"type\":\"wb\",\"cycle\":%0d,\"pc\":\"0x%08x\",\"rob\":%0d,\"epoch\":%0d,\"uses_rd\":%0d,\"prd_new\":%0d,\"data_valid\":%0d,\"data\":\"0x%08x\",\"done\":%0d,\"is_branch\":%0d,\"mispredict\":%0d,\"redirect\":%0d,\"redirect_pc\":\"0x%08x\",\"act_taken\":%0d,\"is_load\":%0d,\"is_store\":%0d,\"mem_exc\":%0d,\"mem_addr\":\"0x%08x\"}\n",
          cycle,
          dut.wb_pkt.pc,
          dut.wb_pkt.rob_idx, dut.wb_pkt.epoch,
          dut.wb_pkt.uses_rd, dut.wb_pkt.prd_new,
          dut.wb_pkt.data_valid, dut.wb_pkt.data, dut.wb_pkt.done,
          dut.wb_pkt.is_branch, dut.wb_pkt.mispredict, dut.wb_pkt.redirect, dut.wb_pkt.redirect_pc, dut.wb_pkt.act_taken,
          dut.wb_pkt.is_load, dut.wb_pkt.is_store, dut.wb_pkt.mem_exc, dut.wb_pkt.mem_addr
        );
      end

      // Commit event -> commit.jsonl (readable, same "single-line format string" style as WB)
      if (dut.commit_valid && dut.commit_ready && ~dut.recover_valid) begin
        commits <= commits + 1;
        cycles_since_commit <= 0;

        $fwrite(tf_commit,
          "{\"type\":\"commit\",\"cycle\":%0d,\"commit_rob\":%0d,\"global_epoch\":%0d,\"valid\":%0d,\"done\":%0d,\"epoch\":%0d,\"uses_rd\":%0d,\"rd_arch\":%0d,\"pd_new\":\"0x%0x\",\"pd_old\":\"0x%0x\",\"is_branch\":%0d,\"mispredict\":%0d,\"is_load\":%0d,\"is_store\":%0d,\"pc\":\"0x%08x\",\"data\":\"0x%08x\"}\n",
          cycle,
          dut.commit_rob_idx,
          dut.global_epoch,
          dut.commit_entry.valid,
          dut.commit_entry.done,
          dut.commit_entry.epoch,
          dut.commit_entry.uses_rd,
          dut.commit_entry.rd_arch,
          dut.commit_entry.pd_new,
          dut.commit_entry.pd_old,
          dut.commit_entry.is_branch,
          dut.commit_entry.mispredict,
          dut.commit_entry.is_load,
          dut.commit_entry.is_store,
          dut.commit_entry.pc,
          dut.commit_entry.uses_rd ? dut.prf_inst.mem[dut.commit_entry.pd_new] : 0
        );

        if (commits > 50000000) begin
          $display("Stopping: commit limit reached");
          $finish;
        end
      end

      // Dispatch events -> dispatch.jsonl
      // Dispatch (RS enqueue) event -> dispatch.jsonl
      if (dut.disp_valid && dut.disp_ready) begin
        $fwrite(tf_dispatch,
          "{\"type\":\"dispatch\",\"cycle\":%0d,\"pc\":\"0x%08x\",\"op\":%0d,\"uop_class\":%0d,\"branch_type\":%0d,\"mem_size\":%0d,\"uses_rs1\":%0d,\"uses_rs2\":%0d,\"uses_rd\":%0d,\"rs1_arch\":%0d,\"rs2_arch\":%0d,\"rd_arch\":%0d,\"imm\":\"0x%08x\",\"pred_taken\":%0d,\"pred_target\":\"0x%08x\",\"rob\":%0d,\"epoch\":%0d,\"prs1\":%0d,\"rdy1\":%0d,\"prs2\":%0d,\"rdy2\":%0d,\"prd_new\":%0d}\n",
          cycle,
          dut.disp_uop.bundle.pc,
          dut.disp_uop.bundle.op,
          dut.disp_uop.bundle.uop_class,
          dut.disp_uop.bundle.branch_type,
          dut.disp_uop.bundle.mem_size,
          dut.disp_uop.bundle.uses_rs1,
          dut.disp_uop.bundle.uses_rs2,
          dut.disp_uop.bundle.uses_rd,
          dut.disp_uop.bundle.rs1_arch,
          dut.disp_uop.bundle.rs2_arch,
          dut.disp_uop.bundle.rd_arch,
          dut.disp_uop.bundle.imm,
          dut.disp_uop.bundle.pred_taken,
          dut.disp_uop.bundle.pred_target,
          dut.disp_uop.rob_idx,
          dut.disp_uop.epoch,
          dut.disp_uop.prs1,
          dut.disp_uop.rdy1,
          dut.disp_uop.prs2,
          dut.disp_uop.rdy2,
          dut.disp_uop.prd_new
        );
      end




      // Watchdog (deadlock detector)
      // if (cycles_since_commit > 5000) begin
      //   $fwrite(tf_misc,
      //     "{\"type\":\"watchdog\",\"cycle\":%0d,\"reason\":\"no_commit_5000\"}\n",
      //     cycle
      //   );
      //   $display("Watchdog fired at cycle %0d", cycle);
      //   $fclose(tf_wb);
      //   $fclose(tf_commit);
      //   $fclose(tf_misc);
      //   $finish;
      // end
    end
  end

endmodule
