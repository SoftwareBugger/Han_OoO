`include "defines.svh"

// Complete top-level showing how fetch, commit_rename, and execute connect
module cpu_core (
    input  logic clk,
    input  logic rst_n,
    
    // Data memory interface
    dmem_if.master dmem,

    // imem interface
    imem_if.master imem
);

    /* =========================
     * Fetch to Rename signals
     * ========================= */
    logic decode_valid;
    logic decode_ready;
    decoded_bundle_t decoded_bundle;
    
    logic decode_ready_rob; // from ROB to throttle decode when ROB is full
    logic decode_ready_stq; // from Store Queue to throttle decode when STQ is full
    logic decode_ready_rs;  // from RS to throttle decode when RS is full
    assign decode_ready = decode_ready_rob && (((decoded_bundle.uop_class != UOP_STORE) && decode_valid) || decode_ready_stq) && decode_ready_rs;
    assign decode_ready_stq = stq_alloc_ready;
    assign decode_ready_rs = disp_ready;

    /* =========================
     * Redirect/Recovery signals
     * ========================= */
    logic redirect_valid;
    logic [31:0] redirect_pc;
    
    logic update_valid;
    logic [31:0] update_pc;
    logic update_taken;
    logic [31:0] update_target;
    logic update_mispredict;


    /* =========================
     * Rename to Execute (Dispatch)
     * ========================= */
    logic disp_valid;
    logic disp_ready;
    rs_uop_t disp_uop;

    /* =========================
     * Commit signals
     * ========================= */
    logic commit_valid;
    logic commit_ready;
    rob_entry_t commit_entry;
    logic [ROB_W-1:0] commit_rob_idx;

    /* =========================
     * Recovery signals
     * ========================= */
    logic recover_valid;
    logic [ROB_W-1:0] recover_rob_idx;
    rob_entry_t recover_entry;

    /* =========================
     * Flush signals
     * ========================= */
    logic flush_valid;
    logic [ROB_W-1:0] flush_rob_idx;
    logic [1:0] flush_epoch;

    /* =========================
     * Epoch tracking
     * ========================= */
    logic [1:0] global_epoch;

    /* =========================
     * Writeback signals (from execute/CDB)
     * ========================= */
    logic wb_valid;
    logic wb_ready;
    fu_wb_t wb_pkt;

    /* =========================
     * ROB index for allocation
     * ========================= */
    logic [ROB_W-1:0] alloc_rob_idx;

    /* =========================
     * RAT lookup signals (for dispatch)
     * ========================= */
    logic [4:0] rs1_arch, rs2_arch;
    logic [PHYS_W-1:0] rs1_phys, rs2_phys, rd_phys, rd_new_phys;

    /* =========================
     * Physical Register File (PRF)
     * ========================= */
    logic [31:0] prf_rdata1 [FU_NUM-1:0];
    logic [31:0] prf_rdata2 [FU_NUM-1:0];
    logic        prf_rready1 [FU_NUM-1:0];
    logic        prf_rready2 [FU_NUM-1:0];
    logic [PHYS_W-1:0] prf_raddr1 [FU_NUM-1:0];
    logic [PHYS_W-1:0] prf_raddr2 [FU_NUM-1:0];
    
    logic prf_wb_valid;
    logic [PHYS_W-1:0] prf_wb_pd;
    logic [31:0] prf_wb_data;
    logic [1:0] prf_wb_epoch;
    
    logic prf_recovery_alloc_valid;
    logic [PHYS_W-1:0] prf_recovery_alloc_pd_new;
    logic [1:0] prf_recovery_alloc_epoch;
    
    logic [PHYS_REGS-1:0] prf_ready_vec;

    /* =========================
     * Store Queue allocation signals
     * ========================= */
    logic stq_alloc_valid;
    logic stq_alloc_ready;
    logic [ROB_W-1:0] stq_alloc_rob_idx;

    /* =========================
     * Execution status
     * ========================= */
    logic rs_busy;

    // =========================================================================
    // Fetch Stage
    // =========================================================================
    fetch fetch_inst (
        .clk(clk),
        .rst_n(rst_n),

        // Redirect from branch mispredict or flush
        .redirect_valid(redirect_valid),
        .redirect_pc(redirect_pc),

        // Predictor update from writeback
        .update_valid(update_valid),
        .update_pc(update_pc),
        .update_taken(update_taken),
        .update_target(update_target),
        .update_mispredict(update_mispredict),

        // Output to rename stage
        .decode_ready(decode_ready),
        .decode_valid(decode_valid),
        .decoded_bundle_fields(decoded_bundle),

        // imem interface
        .imem_m(imem)
    );

    // =========================================================================
    // Rename/Commit Stage (RAT + ROB + FreeList)
    // =========================================================================
    
    // RAT lookups for dispatch - use the decoded bundle's register indices
    assign rs1_arch = decoded_bundle.rs1_arch;
    assign rs2_arch = decoded_bundle.rs2_arch;

    commit_rename #(
        .ARCH_REGS(ARCH_REGS),
        .PHYS_REGS(PHYS_REGS),
        .ROB_SIZE(ROB_SIZE),
        .ROB_W(ROB_W),
        .PHYS_W(PHYS_W)
    ) commit_rename_inst (
        .clk(clk),
        .rst_n(rst_n),

        // Allocation from fetch/decode (filtered by fetch_epoch)
        .alloc_valid(decode_valid),
        .alloc_ready(decode_ready_rob),
        .alloc_bundle(decoded_bundle),
        .alloc_rob_idx(alloc_rob_idx),

        // Writeback from execution units
        .wb_valid(wb_valid),
        .wb_ready(wb_ready),
        .wb_pkt(wb_pkt),

        // Commit interface
        .commit_valid(commit_valid),
        .commit_ready(commit_ready),
        .commit_entry(commit_entry),
        .commit_rob_idx(commit_rob_idx),

        // Flush control
        .flush_valid(flush_valid),
        .flush_rob_idx(flush_rob_idx),
        .flush_epoch(flush_epoch),

        // RAT lookup for dispatch
        .rs1_arch(rs1_arch),
        .rs2_arch(rs2_arch),
        .rs1_phys(rs1_phys),
        .rs2_phys(rs2_phys),
        .rd_phys(rd_phys),
        .rd_new_phys(rd_new_phys),

        // Recovery from branch mispredict
        .recover_valid(recover_valid),
        .recover_rob_idx(recover_rob_idx),
        .recover_entry(recover_entry),

        // Epoch management
        .global_epoch(global_epoch)
    );

    // =========================================================================
    // Dispatch Logic: Build rs_uop_t from decoded_bundle + rename info
    // =========================================================================
    always_comb begin
        disp_uop.bundle = decoded_bundle;
        disp_uop.rob_idx = alloc_rob_idx;
        disp_uop.epoch = global_epoch;
        disp_uop.prs1 = rs1_phys;
        disp_uop.prs2 = rs2_phys;
        disp_uop.prd_new = rd_new_phys;
        
        // Ready bits: check PRF ready status
        // Physical register 0 is always ready (hardwired zero in RISC-V)
        disp_uop.rdy1 = !decoded_bundle.uses_rs1 || 
                        (rs1_phys == '0) || 
                        prf_ready_vec[rs1_phys];
        
        disp_uop.rdy2 = !decoded_bundle.uses_rs2 || 
                        (rs2_phys == '0) || 
                        prf_ready_vec[rs2_phys];
    end

    // Dispatch valid only when rename accepts and execute is ready
    assign disp_valid = decode_valid && decode_ready;

    // =========================================================================
    // Physical Register File (PRF)
    // =========================================================================
    
    // PRF writeback signals from CDB
    assign prf_wb_valid = wb_valid && wb_pkt.uses_rd && wb_pkt.data_valid;
    assign prf_wb_pd = wb_pkt.prd_new;
    assign prf_wb_data = wb_pkt.data;
    assign prf_wb_epoch = wb_pkt.epoch;
    
    // PRF allocation signals: mark newly allocated register as not-ready
    // This happens during recovery when we're walking back the ROB
    assign prf_recovery_alloc_valid = recover_valid && recover_entry.uses_rd;
    assign prf_recovery_alloc_pd_new = recover_entry.pd_new;
    assign prf_recovery_alloc_epoch = global_epoch;
    
    PRF #(
        .PHYS_REGS(PHYS_REGS),
        .DW(32),
        .PHYS_W(PHYS_W)
    ) prf_inst (
        .clk(clk),
        .rst_n(rst_n),

        // Read ports (from RS issue stage)
        .raddr1(prf_raddr1),
        .raddr2(prf_raddr2),
        .rdata1(prf_rdata1),
        .rdata2(prf_rdata2),
        .rready1(prf_rready1),
        .rready2(prf_rready2),

        // Recovery allocation: mark destination not-ready
        .recovery_alloc_valid(prf_recovery_alloc_valid),
        .recovery_alloc_pd_new(prf_recovery_alloc_pd_new),
        .recovery_alloc_epoch(prf_recovery_alloc_epoch),

        // Writeback: write data and mark ready
        .wb_valid(prf_wb_valid),
        .wb_pd(prf_wb_pd),
        .wb_data(prf_wb_data),
        .wb_epoch(prf_wb_epoch),

        // Ready vector for dispatch ready bit checking
        .ready_vec(prf_ready_vec)
    );

    // Note: PRF read addresses (prf_raddr1, prf_raddr2) are driven by the 
    // execute module's issue stage, not directly connected here

    // =========================================================================
    // Execute Stage (RS + FUs + LSU + CDB)
    // =========================================================================
    
    // Store queue allocation happens at dispatch for stores
    assign stq_alloc_valid = disp_valid && (decoded_bundle.uop_class == UOP_STORE);
    assign stq_alloc_rob_idx = alloc_rob_idx;

    execute execute_inst (
        .clk(clk),
        .rst_n(rst_n),

        // Dispatch from rename
        .disp_valid(disp_valid),
        .disp_ready(disp_ready),
        .disp_uop(disp_uop),

        // PRF interface
        .rdata1(prf_rdata1),
        .rdata2(prf_rdata2),
        .rready1(prf_rready1),
        .rready2(prf_rready2),
        .raddr1(prf_raddr1),
        .raddr2(prf_raddr2),

        // Store queue allocation
        .decoded_bundle_fields(decoded_bundle),
        .stq_alloc_valid(stq_alloc_valid),
        .stq_alloc_ready(stq_alloc_ready),
        .stq_alloc_rob_idx(stq_alloc_rob_idx),
        .global_epoch(global_epoch),

        // Flush
        .flush_valid(flush_valid),

        // Recovery
        .recover_valid(recover_valid),
        .recover_rob_idx(recover_rob_idx),
        .recover_epoch(global_epoch),

        // Commit interface (for LSU)
        .commit_valid(commit_valid),
        .commit_ready(commit_ready),
        .commit_entry(commit_entry),
        .commit_rob_idx(commit_rob_idx),

        // Data memory interface
        .dmem(dmem),

        // Writeback to ROB/PRF
        .wb_valid(wb_valid),
        .wb_ready(wb_ready),
        .wb_pkt(wb_pkt),

        // Status
        .rs_busy(rs_busy)
    );

    // =========================================================================
    // Control Logic: Redirect and Flush Generation
    // =========================================================================
    
    // Extract branch info from writeback packet
    logic bru_mispredict;
    assign bru_mispredict = wb_valid && wb_pkt.is_branch && wb_pkt.mispredict;

    // Redirect on branch mispredict from writeback
    // Note: Recovery signal comes from ROB, but redirect happens immediately on WB
    assign redirect_valid = bru_mispredict;
    assign redirect_pc = wb_pkt.redirect_pc;

    // Flush on recovery (triggered by mispredict writeback)
    assign flush_valid = recover_valid;
    assign flush_rob_idx = recover_rob_idx;
    assign flush_epoch = global_epoch;

    // Update predictor on branch writeback
    assign update_valid = wb_valid && wb_pkt.is_branch;
    assign update_pc = wb_pkt.pc;  // Get PC from ROB entry
    assign update_taken = wb_pkt.act_taken;
    assign update_target = wb_pkt.redirect_pc;
    assign update_mispredict = wb_pkt.mispredict;

    // =========================================================================
    // Commit Ready Logic
    // =========================================================================
    
    // Commit ready when not stalling for any reason
    // For stores, LSU needs to be ready to accept the commit
    assign commit_ready = 1'b1;  // Simplified - LSU handles store commits internally

endmodule