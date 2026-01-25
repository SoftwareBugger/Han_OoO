module SoC_top #(
    parameter bit USE_CACHE = 0
)(
    input  logic        clk,   // 125 MHz from Zybo Z7 PL clock pin (K17)
    input  logic [3:0]  sw,
    input  logic [3:0]  btn,
    output logic [3:0]  led
);

    // ================================================================
    // 1) Raw reset request from button (active-low)
    // ================================================================
    logic rst_req_n;
    assign rst_req_n = ~btn[0];  // pressed => 0 (assert reset request)

    // ================================================================
    // 3) PLL / MMCM (Clocking Wizard)
    //    - Input:  125 MHz (clk)
    //    - Output: 25 MHz  (clk_25Mhz)
    // ================================================================
    logic clk_25Mhz;
    logic pll_locked;

    // Clocking wizard reset is typically active-high.
    // Hold it in reset while the pushbutton reset request is asserted.
    clk_wiz_0 u_pll (
        .clk_25Mhz (clk_25Mhz),
        .reset     (~rst_req_n),
        .locked    (pll_locked),
        .clk_125Mhz(clk)
    );

    // ================================================================
    // 4) Create a clean reset for the *25 MHz* domain
    //    - async assert when either:
    //        a) user reset request is asserted (debounced clean reset in 125 domain deasserted)
    //        b) PLL is not locked
    //    - sync deassert to clk_25Mhz
    // ================================================================
    logic rst_n_25_async;
    assign rst_n_25_async = rst_req_n & pll_locked; // active-high "reset_n" pre-sync

    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_sync_25;
    always_ff @(posedge clk_25Mhz or negedge rst_n_25_async) begin
        if (!rst_n_25_async)
            rst_sync_25 <= 2'b00;
        else
            rst_sync_25 <= {rst_sync_25[0], 1'b1};
    end

    logic rst_n_clean;
    assign rst_n_clean = rst_sync_25[1];

    // ================================================================
    // Internal interfaces (run on 25 MHz)
    // ================================================================
    dmem_if #(.LDTAG_W(4)) dmem_cpu();
    imem_if imem();

    // Debug wires from CPU
    logic        dbg_commit_valid, dbg_wb_valid, dbg_redirect_valid, dbg_mispredict;
    logic [31:0] dbg_commit_pc;

    cpu_core cpu_inst (
        .clk(clk_25Mhz),
        .rst_n(rst_n_clean),
        .dmem(dmem_cpu),
        .imem(imem),

        .dbg_commit_valid   (dbg_commit_valid),
        .dbg_wb_valid       (dbg_wb_valid),
        .dbg_redirect_valid (dbg_redirect_valid),
        .dbg_mispredict_fire(dbg_mispredict),
        .dbg_commit_pc      (dbg_commit_pc)
    );

    // ================================================================
    // Memories (run on 25 MHz)
    // ================================================================
    imem #(
        .MEM_WORDS(8192),
        .LATENCY(1),
        .RESP_FIFO_DEPTH(4)
    ) imem_inst (
        .clk(clk_25Mhz),
        .rst_n(rst_n_clean),
        .req_valid(imem.imem_req_valid),
        .req_ready(imem.imem_req_ready),
        .req_addr(imem.imem_req_addr),
        .resp_valid(imem.imem_resp_valid),
        .resp_ready(imem.imem_resp_ready),
        .resp_inst(imem.imem_resp_inst)
    );

    dmem_model #(
        .MEM_SIZE_KB(64),
        .LD_LATENCY(2),
        .ST_LATENCY(2),
        .LDTAG_W   (4)
    ) dmem_direct_inst (
        .clk(clk_25Mhz),
        .rst_n(rst_n_clean),
        .dmem(dmem_cpu)
    );

    // ================================================================
    // Debug state (human-visible) — all in 25 MHz domain
    // ================================================================
    // Heartbeat
    logic [25:0] hb;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) hb <= '0;
        else hb <= hb + 1'b1;
    end

    // Sticky latches
    logic commit_seen, wb_seen, redirect_seen, mispred_seen;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            commit_seen   <= 1'b0;
            wb_seen       <= 1'b0;
            redirect_seen <= 1'b0;
            mispred_seen  <= 1'b0;
        end else begin
            if (dbg_commit_valid)   commit_seen   <= 1'b1;
            if (dbg_wb_valid)       wb_seen       <= 1'b1;
            if (dbg_redirect_valid) redirect_seen <= 1'b1;
            if (dbg_mispredict)     mispred_seen  <= 1'b1;
        end
    end

    // Counters (use lower bits for easy visibility)
    logic [31:0] commit_cnt, wb_cnt;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            commit_cnt <= '0;
            wb_cnt     <= '0;
        end else begin
            if (dbg_commit_valid) commit_cnt <= commit_cnt + 1'b1;
            if (dbg_wb_valid)     wb_cnt     <= wb_cnt + 1'b1;
        end
    end

    // IMEM traffic counters (independent of commit)
    logic [31:0] imem_req_cnt, imem_resp_cnt;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            imem_req_cnt  <= '0;
            imem_resp_cnt <= '0;
        end else begin
            if (imem.imem_req_valid  && imem.imem_req_ready)  imem_req_cnt  <= imem_req_cnt + 1'b1;
            if (imem.imem_resp_valid && imem.imem_resp_ready) imem_resp_cnt <= imem_resp_cnt + 1'b1;
        end
    end

    // PC snapshotting
    logic [31:0] pc_last_commit;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) pc_last_commit <= 32'd0;
        else if (dbg_commit_valid) pc_last_commit <= dbg_commit_pc;
    end

    // Page 5: slow sample/hold PC low nibble
    logic [3:0]  pc_hold_nib;
    logic [23:0] hold;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            pc_hold_nib <= 4'h0;
            hold <= 24'd0;
        end else begin
            if ((hold == 0) && dbg_commit_valid) begin
                pc_hold_nib <= pc_last_commit[5:2];
                hold <= 24'hFFFFFF;
            end else if (hold != 0) begin
                hold <= hold - 1'b1;
            end
        end
    end

    // Page 6: freeze-on-button snapshot (stable readout)
    logic [2:0] btn_sel_q;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) btn_sel_q <= 3'd0;
        else btn_sel_q <= btn[3:1];
    end
    logic btn_changed;
    assign btn_changed = (btn_sel_q != btn[3:1]);

    logic [31:0] pc_snap;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) pc_snap <= 32'd0;
        else if (btn_changed) pc_snap <= pc_last_commit;
    end

    logic [3:0] pc_sel_nib;
    always_comb begin
        unique case (btn[3:1])
            3'd0: pc_sel_nib = pc_snap[3:0];
            3'd1: pc_sel_nib = pc_snap[7:4];
            3'd2: pc_sel_nib = pc_snap[11:8];
            3'd3: pc_sel_nib = pc_snap[15:12];
            3'd4: pc_sel_nib = pc_snap[19:16];
            3'd5: pc_sel_nib = pc_snap[23:20];
            3'd6: pc_sel_nib = pc_snap[27:24];
            3'd7: pc_sel_nib = pc_snap[31:28];
            default: pc_sel_nib = 4'h0;
        endcase
    end

    // DONE latch: tolerate off-by-4 (PC vs PC+4)
    localparam logic [31:0] LAST_PC = 32'h000006a4;
    logic done;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) done <= 1'b0;
        else if (dbg_commit_valid && (dbg_commit_pc == LAST_PC || dbg_commit_pc == (LAST_PC + 32'd4)))
            done <= 1'b1;
    end

    // Pick an aligned MMIO address for DONE (recommended)
    localparam logic [31:0] DONE_ADDR = 32'h00001000; // 8-byte aligned is safest

    logic [31:0] st_data_full;

    // Helper: extract the 32-bit word being written given 64-bit data + 8-bit strb
    function automatic logic [31:0] extract_sw_data64(
        input logic [63:0] data64,
        input logic [7:0]  strb8
    );
        // We expect an SW => exactly 4 contiguous byte lanes set.
        // Common patterns in a 64-bit beat: 0x0F (low word) or 0xF0 (high word).
        unique case (strb8)
            8'b0000_1111: extract_sw_data64 = data64[31:0];
            8'b1111_0000: extract_sw_data64 = data64[63:32];
            default:      extract_sw_data64 = 32'hDEAD_BAD0; // debug marker for "unexpected pattern"
        endcase
    endfunction

    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            st_data_full <= 32'd0;
        end else if (dmem_cpu.st_valid && dmem_cpu.st_ready) begin
            if ({dmem_cpu.st_addr[31:3], 3'b000} == DONE_ADDR) begin
                // Only latch when this transaction is really an SW-like pattern
                if (dmem_cpu.st_wstrb == 8'b0000_1111 || dmem_cpu.st_wstrb == 8'b1111_0000) begin
                    st_data_full <= extract_sw_data64(dmem_cpu.st_wdata, dmem_cpu.st_wstrb);
                end
            end
        end
    end


    logic [3:0] st_data;
    always_comb begin
        unique case (btn[3:1])
            3'd0: st_data = st_data_full[3:0];
            3'd1: st_data = st_data_full[7:4];
            3'd2: st_data = st_data_full[11:8];
            3'd3: st_data = st_data_full[15:12];
            3'd4: st_data = st_data_full[19:16];
            3'd5: st_data = st_data_full[23:20];
            3'd6: st_data = st_data_full[27:24];
            3'd7: st_data = st_data_full[31:28];
            default: st_data = 4'h0;
        endcase
    end

    // ================================================================
    // Debug pages on LEDs (select via sw[3:0])
    // ================================================================
    always_comb begin
        unique case (sw[3:0])
            4'h0: led = {pll_locked, 2'b00, rst_n_clean}; // [3]=PLL locked, [0]=rst released
            4'h1: led = hb[25:22];
            4'h2: led = {commit_seen, wb_seen, redirect_seen, mispred_seen};
            4'h3: led = commit_cnt[17:14];
            4'h4: led = wb_cnt[17:14];
            4'h5: led = pc_hold_nib;
            4'h6: led = pc_sel_nib;
            4'h7: led = {dbg_mispredict, dbg_redirect_valid, dbg_wb_valid, dbg_commit_valid};
            4'h8: led = {done, commit_seen, 2'b00};
            4'h9: led = imem_req_cnt[17:14];
            4'hA: led = imem_resp_cnt[17:14];
            4'hB: led = {imem.imem_req_valid, imem.imem_req_ready, imem.imem_resp_valid, imem.imem_resp_ready};
            4'hC: led = st_data;
            default: led = 4'b0000;
        endcase
    end




endmodule
