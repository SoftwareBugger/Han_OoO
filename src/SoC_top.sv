module SoC_top #(
    parameter bit USE_CACHE = 0
)(
    input  logic        clk,   // 125 MHz from Zybo Z7 PL clock pin (K17)
    input  logic [3:0]  sw,
    input  logic [3:0]  btn,
    output logic [3:0]  led,

    // ================= External peripheral pins (remap in XDC freely) =================
    output logic        spi_sclk,
    output logic        spi_mosi,
    output logic        spi_cs_n,
    output logic        spi_dc,
    output logic        spi_res_n,
    output logic        spi_vccen,
    output logic        spi_pmoden,

     input  logic        uart_rx_i,
    output logic        uart_tx_o
);
    logic        spi_miso;
    assign spi_miso = 1'b0; // unused for OLED, tie to ground

    // ================================================================
    // 1) Raw reset request from button (active-low)
    // ================================================================
    logic rst_req_n;
    assign rst_req_n = ~btn[0];

    // ================================================================
    // 3) PLL / MMCM (Clocking Wizard) 125MHz -> 25MHz
    // ================================================================
    logic clk_25Mhz;
    logic pll_locked;

    clk_wiz_0 u_pll (
        .clk_25Mhz (clk_25Mhz),
        .reset     (~rst_req_n),
        .locked    (pll_locked),
        .clk_125Mhz(clk)
    );

    // ================================================================
    // 4) Clean reset in 25MHz domain
    // ================================================================
    logic rst_n_25_async;
    assign rst_n_25_async = rst_req_n & pll_locked;

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
    // Debug taps from SoC_system_top (to preserve LED pages)
    // ================================================================
    logic        dbg_commit_valid, dbg_wb_valid, dbg_redirect_valid, dbg_mispredict;
    logic [31:0] dbg_commit_pc;

    logic        imem_req_valid, imem_req_ready, imem_resp_valid, imem_resp_ready;

    logic        dmem_st_valid, dmem_st_ready;
    logic [31:0] dmem_st_addr;
    logic [63:0] dmem_st_wdata;
    logic [7:0]  dmem_st_wstrb;

    // -------------------------
    // DUT: full SoC system (exactly like TB style)
    // -------------------------
    SoC_system_top soc_dut (
        .clk        (clk_25Mhz),
        .rst_n      (rst_n_clean),

        .spi_sclk   (spi_sclk),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .spi_cs_n   (spi_cs_n),
        .spi_dc     (spi_dc),
        .spi_res_n  (spi_res_n),
        .spi_vccen  (spi_vccen),
        .spi_pmoden (spi_pmoden),

        .uart_rx_i  (uart_rx_i),
        .uart_tx_o  (uart_tx_o),

        // debug exports
        .dbg_commit_valid   (dbg_commit_valid),
        .dbg_wb_valid       (dbg_wb_valid),
        .dbg_redirect_valid (dbg_redirect_valid),
        .dbg_mispredict     (dbg_mispredict),
        .dbg_commit_pc      (dbg_commit_pc),

        .imem_req_valid     (imem_req_valid),
        .imem_req_ready     (imem_req_ready),
        .imem_resp_valid    (imem_resp_valid),
        .imem_resp_ready    (imem_resp_ready),

        .dmem_st_valid      (dmem_st_valid),
        .dmem_st_ready      (dmem_st_ready),
        .dmem_st_addr       (dmem_st_addr),
        .dmem_st_wdata      (dmem_st_wdata),
        .dmem_st_wstrb      (dmem_st_wstrb)
    );

    // ================================================================
    // Debug state — SAME LED behavior as before
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

    // Counters
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

    // IMEM traffic counters
    logic [31:0] imem_req_cnt, imem_resp_cnt;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            imem_req_cnt  <= '0;
            imem_resp_cnt <= '0;
        end else begin
            if (imem_req_valid  && imem_req_ready)  imem_req_cnt  <= imem_req_cnt + 1'b1;
            if (imem_resp_valid && imem_resp_ready) imem_resp_cnt <= imem_resp_cnt + 1'b1;
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

    // Page 6: freeze-on-button snapshot
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

    logic spi_cs_seen_low;
    logic spi_sclk_seen_toggle;
    logic spi_sclk_last;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            spi_cs_seen_low      <= 1'b0;
            spi_sclk_seen_toggle <= 1'b0;
            spi_sclk_last        <= 1'b1;
        end else begin
            spi_sclk_last <= spi_sclk;
            if (!spi_cs_n) spi_cs_seen_low <= 1'b1;
            if (spi_sclk != spi_sclk_last) spi_sclk_seen_toggle <= 1'b1;
        end
    end

    logic [3:0] spi_info_nib;
    always_comb begin
        unique case (btn[3:1])
            3'd0: spi_info_nib = {spi_cs_seen_low, spi_sclk_seen_toggle, spi_mosi, spi_res_n};
            3'd1: spi_info_nib = {spi_vccen, spi_pmoden, spi_dc, 1'b0};
            default: spi_info_nib = 4'h0;
        endcase
    end

    // DONE latch (same as before)
    localparam logic [31:0] LAST_PC = 32'h000006a4;
    logic done;
    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) done <= 1'b0;
        else if (dbg_commit_valid && (dbg_commit_pc == LAST_PC || dbg_commit_pc == (LAST_PC + 32'd4)))
            done <= 1'b1;
    end

    // MMIO store-data latch (same behavior, now from exported store channel)
    localparam logic [31:0] DONE_ADDR = 32'h10000000;

    logic [31:0] st_data_full;

    function automatic logic [31:0] extract_sw_data64(
        input logic [63:0] data64,
        input logic [7:0]  strb8
    );
        unique case (strb8)
            8'b0000_1111: extract_sw_data64 = data64[31:0];
            8'b1111_0000: extract_sw_data64 = data64[63:32];
            default:      extract_sw_data64 = 32'hDEAD_BAD0;
        endcase
    endfunction

    always_ff @(posedge clk_25Mhz) begin
        if (!rst_n_clean) begin
            st_data_full <= 32'd0;
        end else if (dmem_st_valid && dmem_st_ready) begin
            if ({dmem_st_addr[31:3], 3'b000} == DONE_ADDR) begin
                if (dmem_st_wstrb == 8'b0000_1111 || dmem_st_wstrb == 8'b1111_0000)
                    st_data_full <= extract_sw_data64(dmem_st_wdata, dmem_st_wstrb);
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

    // LED pages (unchanged)
    always_comb begin
        unique case (sw[3:0])
            4'h0: led = {pll_locked, 2'b00, rst_n_clean};
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
            4'hB: led = {imem_req_valid, imem_req_ready, imem_resp_valid, imem_resp_ready};
            4'hC: led = st_data;
            4'hD: led = spi_info_nib;
            default: led = 4'b0000;
        endcase
    end

endmodule
