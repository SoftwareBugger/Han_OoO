`include "defines.svh"

module commit_rename #(
    parameter int ARCH_REGS = 32,
    parameter int PHYS_REGS = 64,
    parameter int ROB_SIZE   = 16,
    parameter int ROB_W      = $clog2(ROB_SIZE),
    parameter int PHYS_W    = $clog2(PHYS_REGS)
)(
    input  logic clk,
    input  logic rst_n,

    /* =========================
     * Allocation / Dispatch
     * ========================= */
    input  logic        alloc_valid,
    output logic        alloc_ready,

    input  decoded_bundle_t alloc_bundle,

    output logic [ROB_W-1:0] alloc_rob_idx,

    /* =========================
     * Writeback (from CDB)
     * ========================= */
    input  logic        wb_valid,
    output logic        wb_ready,
    input  fu_wb_t      wb_pkt,

    /* =========================
     * Commit Interface
     * ========================= */
    output logic        commit_valid,
    input  logic        commit_ready,

    output rob_entry_t  commit_entry,
    output logic [ROB_W-1:0] commit_rob_idx,

    /* =========================
     * Flush Control
     * ========================= */
    input  logic        flush_valid,
    input  logic [ROB_W-1:0] flush_rob_idx,
    input  logic [1:0]  flush_epoch,

    /* =========================
     * architectural registers (for RAT read)
     * ========================= */
    input logic [4:0]  rs1_arch,
    input logic [4:0]  rs2_arch,

    /* =========================
     * debug targets
     * ========================= */
    output [PHYS_W-1:0] rs1_phys,
    output [PHYS_W-1:0] rs2_phys,
    output [PHYS_W-1:0] rd_phys,
    output [PHYS_W-1:0] rd_new_phys,

    /* =========================
     * Recovery (from branch mispredict)
     * ========================= */
    output logic        recover_valid,
    output logic [ROB_W-1:0] recover_rob_idx,
    output rob_entry_t  recover_entry,

    /* =========================
     * Epoch management
     * ========================= */
    output logic [1:0]  global_epoch
);

    /* =========================
     * Freelist signals
     * ========================= */
    logic        o_free_list_alloc_ready;
    logic [PHYS_W-1:0] o_free_list_alloc_pd;
    logic        i_free_list_alloc_valid;

    logic        i_free_list_free_valid;
    logic [PHYS_W-1:0] i_free_list_free_pd;

    // Free logic: recovery frees pd_new (wrong allocation), commit frees pd_old (replaced mapping)
    assign i_free_list_free_pd = recover_valid ? recover_entry.pd_new : commit_entry.pd_old;
    assign i_free_list_free_valid = (commit_valid && commit_entry.uses_rd && commit_ready) || recover_valid;
    
    // Allocation logic: only allocate when not in recovery and instruction uses rd
    // Also check that freelist is ready to avoid allocating when no physical registers available
    assign i_free_list_alloc_valid = alloc_valid && alloc_bundle.uses_rd && o_free_list_alloc_ready && rob_alloc_ready && (~recover_valid);

    // Overall allocation ready: both freelist and ROB must be ready, and not in recovery
    logic rob_alloc_ready;
    assign alloc_ready = o_free_list_alloc_ready && rob_alloc_ready && (~recover_valid);

    FreeList #(
        .PHYS_REGS(PHYS_REGS),
        .ARCH_REGS(ARCH_REGS),
        .PHYS_W(PHYS_W)
    ) free_list (
        .clk            (clk),
        .rst_n          (rst_n),

        /* =========================
         * Allocate (rename)
         * ========================= */
        .alloc_valid   (i_free_list_alloc_valid),
        .alloc_ready   (o_free_list_alloc_ready),
        .alloc_pd      (o_free_list_alloc_pd),

        /* =========================
         * Free (commit)
         * ========================= */
        .free_valid    (i_free_list_free_valid),
        .free_pd       (i_free_list_free_pd),

        /* =========================
         * Flush
         * ========================= */
        .flush_valid   (flush_valid)
    );

    /* =========================
     * RAT signals
     * ========================= */
    logic [PHYS_W-1:0] o_rat_rs1_phys;
    logic [PHYS_W-1:0] o_rat_rs2_phys;
    logic [PHYS_W-1:0] o_rat_rd_phys;

    logic        i_rat_rename_valid;

    // RAT rename only fires when allocation actually succeeds (full handshake)
    // Recovery takes priority in the RAT module itself
    assign i_rat_rename_valid = alloc_valid && alloc_ready && (~recover_valid);

    RAT #(
        .ARCH_REGS(ARCH_REGS),
        .PHYS_W(PHYS_W)
    ) rat (
        .clk                (clk),
        .rst_n              (rst_n),

        /* =========================
         * Rename (read)
         * ========================= */
        .rs1_arch           (rs1_arch),
        .rs2_arch           (rs2_arch),
        .rd_arch            (alloc_bundle.rd_arch), 
        .rs1_phys           (o_rat_rs1_phys),
        .rs2_phys           (o_rat_rs2_phys),
        .rd_phys            (o_rat_rd_phys), 

        /* =========================
         * Rename (write / dispatch)
         * ========================= */
        .rename_valid       (i_rat_rename_valid),
        .rename_uses_rd     (alloc_bundle.uses_rd),
        .rename_rd_arch     (alloc_bundle.rd_arch),
        .rename_pd_new      (o_free_list_alloc_pd),

        /* =========================
         * Flush
         * ========================= */
        .flush_valid        (flush_valid),

        /* =========================
        * Recovery (from ROB)
        * ========================= */
        .recover_valid      (recover_valid),
        .recover_pd         (recover_entry.pd_old),
        .recover_rd_arch    (recover_entry.rd_arch)
    );

    /* =========================
     * ROB instance
     * ========================= */
    ROB #(
        .ROB_SIZE_P(ROB_SIZE),
        .ROB_W_P(ROB_W),
        .PHYS_W_P(PHYS_W)
    ) rob (
        .clk                (clk),
        .rst_n              (rst_n),

        /* =========================
         * Allocation / Dispatch
         * ========================= */
        .alloc_valid        (alloc_valid),
        .alloc_ready        (rob_alloc_ready),
        .alloc_bundle       (alloc_bundle),
        .alloc_pd_new       (o_free_list_alloc_pd),
        .alloc_pd_old       (o_rat_rd_phys),
        .alloc_rob_idx      (alloc_rob_idx),

        /* =========================
         * Writeback (from CDB)
         * ========================= */
        .wb_valid           (wb_valid),
        .wb_ready           (wb_ready),
        .wb_pkt             (wb_pkt),

        /* =========================
         * Commit Interface
         * ========================= */
        .commit_valid       (commit_valid),
        .commit_ready       (commit_ready),
        .commit_entry       (commit_entry),
        .commit_rob_idx     (commit_rob_idx),

        /* =========================
         * Flush Control
         * ========================= */
        .flush_valid        (flush_valid),
        .flush_rob_idx      (flush_rob_idx),
        .flush_epoch        (flush_epoch),

        /* =========================
         * Recovery (from branch mispredict)
         * ========================= */
        .recover_valid      (recover_valid),
        .recover_rob_idx    (recover_rob_idx),
        .recover_entry      (recover_entry),

        /* =========================
         * Epoch management
         * ========================= */
        .global_epoch       (global_epoch)
    );

    /* =========================
     * Debug outputs
     * ========================= */
    assign rs1_phys = o_rat_rs1_phys;
    assign rs2_phys = o_rat_rs2_phys;
    assign rd_phys  = o_rat_rd_phys;
    assign rd_new_phys = o_free_list_alloc_pd;

endmodule