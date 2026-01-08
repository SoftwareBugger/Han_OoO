/*==============================================
 * Commit Dispatch System - instruction manager
 *=============================================*/
`include "defines.svh"
module commit_dispatch_sys #(
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

    //input  logic [PHYS_W-1:0] alloc_pd_new,
    //input  logic [PHYS_W-1:0] alloc_pd_old,
    input  logic [1:0]       alloc_epoch,

    output logic [ROB_W-1:0] alloc_rob_idx,

    /* =========================
     * Issue Interface
     * ========================= */
    input decoded_bundle_t    decoded_bundle_fields,
    input logic [FU_NUM-1:0]  issue_ready,
    output logic [FU_NUM-1:0] issue_valid,
    output rs_uop_t    issue_uop [FU_NUM-1:0],

    /* =========================
     * Writeback (from CDB)
     * ========================= */
    input  logic        wb_valid,
    output logic        wb_ready,
    input  logic [ROB_W-1:0] wb_rob_idx,
    input  logic [1:0]       wb_epoch,
    input  logic       wb_mispredict,
    input  logic [PHYS_W-1:0] wb_pd,
    input  logic [31:0] wb_data,

    /* =========================
     * Commit Interface
     * ========================= */
    output logic        commit_valid,
    input  logic        commit_ready,

    output logic        commit_uses_rd,
    output logic [4:0]  commit_rd_arch,
    output logic [PHYS_W-1:0] commit_pd_new,
    output logic [PHYS_W-1:0] commit_pd_old,

    output logic        commit_is_branch,
    output logic        commit_is_load,
    output logic        commit_is_store,

    /* =========================
     * Flush Control
     * ========================= */
    input  logic        flush_valid,
    input  logic [ROB_W-1:0] flush_rob_idx,
    input  logic [1:0]       flush_epoch,

    /* =========================
     * architectural registers
     * ========================= */
    input logic [4:0]  rs1_arch,
    input logic [4:0]  rs2_arch,
    input  logic [4:0]  alloc_rd_arch,

    /* =========================
     * debug targets
     * ========================= */
    output [PHYS_W-1:0] rs1_phys,
    output [DW-1:0]     rs1_data,
    output              rs1_ready,
    output [PHYS_W-1:0] rs2_phys,
    output [DW-1:0]     rs2_data,
    output              rs2_ready,
    output [PHYS_W-1:0] rd_phys,
    output [PHYS_W-1:0] rd_new_phys,
    output [PHYS_REGS-1:0] ready_vec,


    /* =========================
     * Recovery (from branch mispredict)
     * ========================= */
    output logic        recover_valid,
    output logic [ROB_W-1:0] recover_cur_rob_idx,
    output rob_entry_t recover_entry
);

    /* =========================
     * epoch management
     * ========================= */
    logic [1:0]       global_epoch;


    // Freelist instance

    /* =========================
     * Allocate (rename): comes from bundle fields
     * ========================= */
    logic        alloc_uses_rd;
    logic        alloc_is_branch;
    logic        alloc_is_load;
    logic        alloc_is_store;
    logic        rob_alloc_ready;
    logic [31:0] alloc_pc;
    assign alloc_uses_rd = decoded_bundle_fields.uses_rd;
    assign alloc_is_branch = (decoded_bundle_fields.uop_class == UOP_BRANCH);
    assign alloc_is_load   = (decoded_bundle_fields.uop_class == UOP_LOAD);
    assign alloc_is_store  = (decoded_bundle_fields.uop_class == UOP_STORE);
    assign alloc_pc = decoded_bundle_fields.pc;

    /* =========================
     * Free (commit & allocate)
     * ========================= */
    logic        o_free_list_alloc_ready;
    logic [PHYS_W-1:0] o_free_list_alloc_pd;
    logic        i_free_list_alloc_valid;
    logic        i_free_list_free_valid;
    logic [PHYS_W-1:0] i_free_list_free_pd;

    assign i_free_list_free_pd = recover_valid ? recover_entry.pd_new : commit_pd_old;
    assign i_free_list_free_valid = (commit_valid && commit_uses_rd && commit_ready) | recover_valid;
    assign i_free_list_alloc_valid = alloc_valid && alloc_uses_rd && rob_alloc_ready && (~recover_valid);

    FreeList free_list (
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
     * RAT instance
     * ========================= */

    /* =========================
     * Rename (read)
     * ========================= */
    logic [PHYS_W-1:0] o_rat_rs1_phys;
    logic [PHYS_W-1:0] o_rat_rs2_phys;
    logic [PHYS_W-1:0] o_rat_rd_phys; // for debug

    /* =========================
     * Rename (write / dispatch)
     * ========================= */
    logic        i_rat_rename_valid;
    logic        i_rat_rename_uses_rd;
    logic [PHYS_W-1:0] i_rat_rename_pd_new;

    /* =========================
     * Recovery (from ROB)
     * ========================= */
    logic [PHYS_W-1:0] i_rat_recover_pd;

    assign i_rat_rename_valid      = alloc_valid && rob_alloc_ready && o_free_list_alloc_ready;
    assign i_rat_rename_uses_rd    = alloc_uses_rd;
    assign i_rat_rename_rd_arch    = alloc_rd_arch;
    assign i_rat_rename_pd_new     = o_free_list_alloc_pd;
    assign i_rat_recover_pd        = recover_entry.pd_old;

    RAT rat (
        .clk                (clk),
        .rst_n              (rst_n),

        /* =========================
         * Rename (read)
         * ========================= */
        .rs1_arch           (rs1_arch),
        .rs2_arch           (rs2_arch),
        .rd_arch            (alloc_rd_arch), 
        .rs1_phys           (o_rat_rs1_phys),
        .rs2_phys           (o_rat_rs2_phys),
        .rd_phys            (o_rat_rd_phys), 

        /* =========================
         * Rename (write / dispatch)
         * ========================= */
        .rename_valid       (i_rat_rename_valid),
        .rename_uses_rd     (i_rat_rename_uses_rd),
        .rename_rd_arch     (alloc_rd_arch),
        .rename_pd_new      (i_rat_rename_pd_new),

        /* =========================
         * Flush
         * ========================= */
        .flush_valid        (flush_valid),

        /* =========================
        * Recovery (from ROB)
        * ========================= */
        .recover_valid      (recover_valid),
        .recover_pd         (i_rat_recover_pd),
        .recover_rd_arch    (recover_entry.rd_arch)
    );

    /* =========================
     * ROB instance
     * ========================= */
    ROB rob (
        .clk                (clk),
        .rst_n              (rst_n),

        /* =========================
         * Allocation / Dispatch
         * ========================= */
        .alloc_valid        (alloc_valid),
        .alloc_ready        (rob_alloc_ready),

        .alloc_uses_rd     (alloc_uses_rd),
        .alloc_rd_arch     (alloc_rd_arch),
        .alloc_pd_new      (o_free_list_alloc_pd),
        .alloc_pd_old      (o_rat_rd_phys), // old mapping of rd

        .alloc_is_branch   (alloc_is_branch),
        .alloc_is_load     (alloc_is_load),
        .alloc_is_store    (alloc_is_store),

        .alloc_pc          (alloc_pc),
        .alloc_epoch       (alloc_epoch),

        .alloc_rob_idx     (alloc_rob_idx),

        /* =========================
         * Writeback (from CDB)
         * ========================= */
        .wb_valid          (wb_valid),
        .wb_ready          (wb_ready),
        .wb_rob_idx        (wb_rob_idx),
        .wb_epoch          (wb_epoch),
        .wb_mispredict     (wb_mispredict),

        /* =========================
         * Commit Interface
         * ========================= */
        .commit_valid      (commit_valid),
        .commit_ready      (commit_ready),

        .commit_uses_rd    (commit_uses_rd),
        .commit_rd_arch    (commit_rd_arch),
        .commit_pd_new     (commit_pd_new),
        .commit_pd_old     (commit_pd_old),

        .commit_is_branch  (commit_is_branch),
        .commit_is_load    (commit_is_load),
        .commit_is_store   (commit_is_store),

        /* =========================
         * Flush Control
         * ========================= */
        .flush_valid       (flush_valid),
        .flush_rob_idx     (flush_rob_idx),
        .flush_epoch       (flush_epoch),

        /* =========================
         * Recovery (from branch mispredict)
         * ========================= */
        .recover_valid     (recover_valid),
        .recover_cur_rob_idx   (recover_cur_rob_idx),
        .recover_entry     (recover_entry),

        /* =========================
         * epoch management
         * ========================= */
        .global_epoch      (global_epoch)
    );

    // -------------------------
    // PRF port signals (declare here for easy wiring)
    // -------------------------
    logic [PHYS_W-1:0] raddr1;
    logic [DW-1:0]     rdata1;
    logic              rready1;

    logic [PHYS_W-1:0] raddr2;
    logic [DW-1:0]     rdata2;
    logic              rready2;

    logic              recovery_alloc_valid;
    logic [PHYS_W-1:0] recovery_alloc_pd_new;

    logic [PHYS_W-1:0] i_PRF_wb_pd;
    logic [DW-1:0]     i_PRF_wb_data;

    logic [PHYS_REGS-1:0] ready_vec;

    // -------------------------
    // PRF port assignments
    // -------------------------
    assign raddr1 = o_rat_rs1_phys;
    assign raddr2 = o_rat_rs2_phys;
    assign recovery_alloc_valid    = alloc_valid | recover_valid;
    assign recovery_alloc_pd_new   = recover_valid ? recover_entry.pd_new : o_free_list_alloc_pd;
    assign i_PRF_wb_pd   = wb_pd;
    assign i_PRF_wb_data = wb_data;



    // -------------------------
    // PRF instance
    // -------------------------
    PRF #(
        .PHYS_REGS(PHYS_REGS),
        .DW(DW),
        .PHYS_W(PHYS_W)
    ) u_prf (
        .clk(clk),
        .rst_n(rst_n),

        .raddr1(raddr1),
        .rdata1(rdata1),
        .rready1(rready1),

        .raddr2(raddr2),
        .rdata2(rdata2),
        .rready2(rready2),

        .recovery_alloc_valid(recovery_alloc_valid),
        .recovery_alloc_pd_new(recovery_alloc_pd_new),

        .wb_valid(wb_valid),
        .wb_pd(i_PRF_wb_pd),
        .wb_data(i_PRF_wb_data),

        .ready_vec(ready_vec)
    );

    // -------------------------
    // RS interface signals
    // -------------------------
    logic        disp_valid;
    logic        disp_ready;
    rs_uop_t     disp_uop;

    logic        busy;

    // RS interface assignments
    assign disp_valid = alloc_valid && rob_alloc_ready && o_free_list_alloc_ready && (~recover_valid);
    // rename fields
    assign disp_uop.prs1       = o_rat_rs1_phys;
    assign disp_uop.rdy1       = rready1;
    assign disp_uop.prs2       = o_rat_rs2_phys;
    assign disp_uop.rdy2       = rready2;
    assign disp_uop.prd_new    = o_free_list_alloc_pd;
    assign disp_uop.pc         = alloc_pc;
    // identity fields
    assign disp_uop.rob_idx    = alloc_rob_idx;
    assign disp_uop.epoch      = alloc_epoch;
    // bundle fields
    assign disp_uop.bundle    = decoded_bundle_fields;



    // -------------------------
    // RS instance
    // -------------------------
    RS #(
        .RS_SIZE(RS_SIZE)
    ) u_rs (
        .clk(clk),
        .rst_n(rst_n),

        .disp_valid(disp_valid),
        .disp_ready(disp_ready),
        .disp_uop(disp_uop),

        .wb_valid(wb_valid),
        .wb_pd(wb_pd),

        .issue_valid(issue_valid),
        .issue_ready(issue_ready),
        .issue_uop(issue_uop),

        .flush_valid(flush_valid),
        .recover_valid(recover_valid),
        .recover_rob_idx(recover_cur_rob_idx),
        .recover_epoch(recover_entry.epoch),

        .busy(busy)
    );

    // debug outputs
    assign rs1_phys = o_rat_rs1_phys;
    assign rs2_phys = o_rat_rs2_phys;
    assign rd_phys  = o_rat_rd_phys;
    assign rd_new_phys = i_rat_rename_pd_new;
    assign rs1_data = rdata1;
    assign rs1_ready = rready1;
    assign rs2_data = rdata2;
    assign rs2_ready = rready2;
    assign alloc_ready = rob_alloc_ready && o_free_list_alloc_ready && (~recover_valid) && (~flush_valid) && disp_ready;
endmodule