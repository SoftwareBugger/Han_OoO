`include "defines.svh"

module execute (
    input  logic              clk,
    input  logic              rst_n,

    // -------------------------
    // Dispatch from rename
    // -------------------------
    input  logic              disp_valid,
    output logic              disp_ready,
    input  rs_uop_t           disp_uop,

    // -------------------------
    // Read data from PRF
    // -------------------------
    input  logic [31:0] rdata1 [FU_NUM-1:0],
    input  logic [31:0] rdata2 [FU_NUM-1:0],
    input  logic        rready1 [FU_NUM-1:0],
    input  logic        rready2 [FU_NUM-1:0],
    output logic [PHYS_W-1:0] raddr1 [FU_NUM-1:0],
    output logic [PHYS_W-1:0] raddr2 [FU_NUM-1:0],

    // -------------------------
    // Store queue entry allocate
    // -------------------------
    input  decoded_bundle_t decoded_bundle_fields,
    input  logic              stq_alloc_valid,
    output logic              stq_alloc_ready,
    input  logic [ROB_W-1:0]  stq_alloc_rob_idx,
    input  logic [1:0]        global_epoch,

    // -------------------------
    // Flush
    // -------------------------
    input  logic              flush_valid,

    // -------------------------
    // Recovery
    // -------------------------
    input  logic              recover_valid,
    input  logic [ROB_W-1:0]  recover_rob_idx,
    input  logic [1:0]        recover_epoch,

    // -------------------------
    // Commit interface
    // -------------------------
    input  logic              commit_valid,
    input  logic              commit_ready,
    input  rob_entry_t        commit_entry,
    input  logic [ROB_W-1:0]  commit_rob_idx,

    // -----------------------------
    // Data memory interface instance
    // -----------------------------
    dmem_if.master dmem,

    // -------------------------
    // Writeback
    // -------------------------
    output logic              wb_valid,
    input  logic              wb_ready,
    output fu_wb_t            wb_pkt,

    // -------------------------
    // Status
    // -------------------------
    output logic              rs_busy
);

    // -------------------------
    // Issue to execution / issue_select
    // -------------------------
    logic [FU_NUM-1:0] issue_valid;
    logic [FU_NUM-1:0] issue_ready;
    rs_uop_t           issue_uop [FU_NUM-1:0];

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

        // Wakeup from CDB - use actual writeback signals
        .wb_valid(wb_valid && wb_pkt.uses_rd && wb_pkt.data_valid),
        .wb_pd(wb_pkt.prd_new),

        .issue_valid(issue_valid),
        .issue_ready(issue_ready),
        .issue_uop(issue_uop),

        .flush_valid(flush_valid),
        .recover_valid(recover_valid),
        .recover_rob_idx(recover_rob_idx),
        .recover_epoch(recover_epoch),

        .busy(rs_busy)
    );

    // =======================================================
    // RS → FU Issue Pipeline (1-entry elastic buffer per FU)
    // =======================================================

    logic fu_req_valid [FU_NUM-1:0] ;
    logic fu_req_ready [FU_NUM-1:0];
    rs_uop_t           fu_req_uop [FU_NUM-1:0];

    logic pipe_v [FU_NUM-1:0];
    rs_uop_t           pipe_uop [FU_NUM-1:0];

    logic  pop [FU_NUM-1:0];
    logic  push [FU_NUM-1:0];
    genvar i;
    generate
        for (i = 0; i < FU_NUM; i++) begin
            // FU sees what is in the pipe
            assign fu_req_valid[i] = pipe_v[i];
            assign fu_req_uop[i]   = pipe_uop[i];
            // RS sees ready if pipeline empty or popping this cycle
            // Pipeline push/pop logic
            assign pop[i]  = (fu_req_ready[i] & pipe_v[i]);
            assign issue_ready[i] = (~pipe_v[i] | pop[i]);
            assign push[i] = (issue_valid[i] & issue_ready[i]);
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < FU_NUM; i++) begin
                pipe_v[i] <= 1'b0;
                pipe_uop[i] <= '0;
            end
        end else begin
            // Kill all issued-but-not-executed ops on flush or recovery
            if (flush_valid) begin
                for (int i = 0; i < FU_NUM; i++) begin
                    pipe_v[i] <= 1'b0;
                    pipe_uop[i] <= '0;
                end
            end else begin
                for (int i = 0; i < FU_NUM; i++) begin
                    unique case ({push[i], pop[i]})
                        2'b10: begin // push
                            pipe_v[i]   <= 1'b1;
                            pipe_uop[i] <= issue_uop[i];
                        end
                        2'b01: begin // pop
                            pipe_v[i] <= 1'b0;
                        end
                        2'b11: begin // replace
                            pipe_v[i]   <= 1'b1;
                            pipe_uop[i] <= issue_uop[i];
                        end
                        default: begin 
                            // hold
                            pipe_v[i]   <= pipe_v[i];
                            pipe_uop[i] <= pipe_uop[i];
                        end
                    endcase
                end
            end
        end
    end
    // -------------------------------------------------------
    // PRF read address drive (read operands as ops are issued)
    // -------------------------------------------------------
    for (genvar i = 0; i < FU_NUM; i++) begin : gen_prf_raddr
        // Drive 0 when idle to reduce spurious toggling
        assign raddr1[i] = fu_req_valid[i] ? fu_req_uop[i].prs1 : '0;
        assign raddr2[i] = fu_req_valid[i] ? fu_req_uop[i].prs2 : '0;
    end




    // -------------------------
    // ALU instance
    // -------------------------
    logic              alu_wb_valid;
    logic              alu_wb_ready;
    logic [ROB_W-1:0]  alu_wb_rob_idx;
    logic [1:0]        alu_wb_epoch;
    logic [PHYS_W-1:0] alu_wb_prd_new;
    logic [31:0]       alu_wb_pc;
    logic              alu_wb_uses_rd;
    logic [31:0]       alu_wb_data;
    logic [31:0]       alu_wb_pc;

    ALU alu (
        .clk(clk),
        .rst_n(rst_n),

        .req_valid(fu_req_valid[0]),
        .req_ready(fu_req_ready[0]),
        .req_uop  (fu_req_uop[0]),


        .rs1_val(rdata1[0]),
        .rs2_val(rdata2[0]),

        .wb_valid(alu_wb_valid),
        .wb_ready(alu_wb_ready),
        .wb_pc(alu_wb_pc),
        .wb_uses_rd(alu_wb_uses_rd),
        .wb_rob_idx(alu_wb_rob_idx),
        .wb_prd_new(alu_wb_prd_new),
        .wb_epoch(alu_wb_epoch),
        .wb_data(alu_wb_data)
    );

    // -------------------------
    // BRU instance
    // -------------------------
    logic              bru_wb_valid;
    logic              bru_wb_ready;
    logic [ROB_W-1:0]  bru_wb_rob_idx;
    logic [PHYS_W-1:0] bru_wb_prd_new;
    logic [31:0]       bru_wb_pc;
    logic              bru_wb_uses_rd;
    logic [1:0]        bru_wb_epoch;
    logic [31:0]       bru_wb_data;
    logic              act_taken;
    logic [31:0]       target_pc;
    logic              mispredict;
    logic              redirect_valid;
    logic [31:0]       redirect_pc;

    BRU bru (
        .clk(clk),
        .rst_n(rst_n),

        .req_valid(fu_req_valid[1]),
        .req_ready(fu_req_ready[1]),
        .req_uop  (fu_req_uop[1]),


        .rs1_val(rdata1[1]),
        .rs2_val(rdata2[1]),

        .wb_valid(bru_wb_valid),
        .wb_ready(bru_wb_ready),
        .wb_pc(bru_wb_pc),
        .wb_uses_rd(bru_wb_uses_rd),
        .wb_rob_idx(bru_wb_rob_idx),
        .wb_prd_new(bru_wb_prd_new),
        .wb_epoch(bru_wb_epoch),
        .wb_data(bru_wb_data),

        .act_taken(act_taken),
        .target_pc(target_pc),

        .mispredict(mispredict),
        .redirect_valid(redirect_valid),
        .redirect_pc(redirect_pc)
    );

    // -------------------------
    // LSU instance
    // -------------------------

    // -----------------------------
    // RS -> LSU request channel
    // -----------------------------
    logic    lsu_req_valid_st;
    logic    lsu_req_valid_ld;
    logic    lsu_req_ready_st;
    logic    lsu_req_ready_ld;
    rs_uop_t lsu_req_uop [1:0];

    assign lsu_req_valid_st = fu_req_valid[2];
    assign lsu_req_valid_ld = fu_req_valid[3];

    assign fu_req_ready[2]  = lsu_req_ready_st;
    assign fu_req_ready[3]  = lsu_req_ready_ld;

    assign lsu_req_uop[0]   = fu_req_uop[2]; // store
    assign lsu_req_uop[1]   = fu_req_uop[3]; // load


    // -----------------------------
    // Store Queue allocate/commit sideband
    // -----------------------------
    sq_entry_t lsu_sq_entry_in;
    logic      lsu_sq_entry_in_valid;
    logic      lsu_sq_entry_in_ready;

    assign lsu_sq_entry_in.rob_idx   = stq_alloc_rob_idx;
    assign lsu_sq_entry_in.epoch     = global_epoch;
    assign lsu_sq_entry_in.mem_size  = decoded_bundle_fields.mem_size;
    assign lsu_sq_entry_in.addr      = '0;       // will be filled by LSU
    assign lsu_sq_entry_in.addr_rdy  = 1'b0;     // not ready at dispatch
    assign lsu_sq_entry_in.data      = '0;       // will be filled by LSU
    assign lsu_sq_entry_in.data_rdy  = 1'b0;     // not ready at dispatch
    assign lsu_sq_entry_in.committed = 1'b0;     // not committed at dispatch
    assign lsu_sq_entry_in.sent      = 1'b0;     // not sent at dispatch
    
    assign lsu_sq_entry_in_valid = stq_alloc_valid;
    assign stq_alloc_ready = lsu_sq_entry_in_ready;

    sq_entry_t lsu_sq_entry_out;   // optional: for debug/monitor

    // -----------------------------
    // Operand values (from PRF)
    // -----------------------------
    logic [31:0] lsu_rs1_val [1:0];
    logic [31:0] lsu_rs2_val [1:0];

    assign lsu_rs1_val[0] = rdata1[2]; // store
    assign lsu_rs1_val[1] = rdata1[3]; // load
    assign lsu_rs2_val[0] = rdata2[2]; // store
    assign lsu_rs2_val[1] = rdata2[3]; // load

    // -----------------------------
    // ROB -> LSU commit interface
    // -----------------------------
    logic              rob_commit_valid;
    logic              rob_commit_ready;
    logic              rob_commit_is_store;
    logic [ROB_W-1:0]  rob_commit_rob_idx;
    logic [1:0]        rob_commit_epoch;
    
    assign rob_commit_valid    = commit_valid;
    assign rob_commit_ready    = commit_ready;
    assign rob_commit_is_store = commit_entry.is_store;
    assign rob_commit_rob_idx  = commit_rob_idx;
    assign rob_commit_epoch    = commit_entry.epoch;

    // -----------------------------
    // LSU -> CDB / writeback
    // -----------------------------
    logic              lsu_wb_valid;
    logic              lsu_wb_ready;
    logic              lsu_wb_uses_rd;
    logic [1:0]        lsu_wb_epoch;
    logic [ROB_W-1:0]  lsu_wb_rob_idx;
    logic [PHYS_W-1:0] lsu_wb_prd_new;
    logic [31:0]       lsu_wb_data;
    logic [31:0]       lsu_wb_pc;

    LSU lsu_u (
        .clk               (clk),
        .rst_n             (rst_n),

        // RS interface
        .req_valid_st      (lsu_req_valid_st),
        .req_valid_ld      (lsu_req_valid_ld),
        .req_ready_st      (lsu_req_ready_st),
        .req_ready_ld      (lsu_req_ready_ld),
        .req_uop           (lsu_req_uop),

        // Operand values (from PRF)
        .rs1_val           (lsu_rs1_val),
        .rs2_val           (lsu_rs2_val),

        // SQ allocate/commit interface
        .sq_entry_in       (lsu_sq_entry_in),
        .sq_entry_in_valid (lsu_sq_entry_in_valid),
        .sq_entry_in_ready (lsu_sq_entry_in_ready),
        .sq_entry_out      (lsu_sq_entry_out),

        // Commit interface (from ROB)
        .commit_valid      (rob_commit_valid),
        .commit_ready      (rob_commit_ready),
        .commit_is_store   (rob_commit_is_store),
        .commit_rob_idx    (rob_commit_rob_idx),
        .commit_epoch      (rob_commit_epoch),

        // Flush control (from ROB / trap)
        .flush_valid       (flush_valid),

        // Recovery interface (from ROB branch mispredict)
        .recover_valid     (recover_valid),
        .recover_rob_idx   (recover_rob_idx),
        .recover_epoch     (recover_epoch),

        // Memory interface
        .dmem              (dmem),

        // Writeback interface
        .wb_valid          (lsu_wb_valid),
        .wb_ready          (lsu_wb_ready),
        .wb_uses_rd        (lsu_wb_uses_rd),
        .wb_epoch          (lsu_wb_epoch),
        .wb_rob_idx        (lsu_wb_rob_idx),
        .wb_prd_new        (lsu_wb_prd_new),
        .wb_pc             (lsu_wb_pc),
        .wb_data           (lsu_wb_data)
    );

    // -------------------------
    // CDB instance
    // -------------------------
    CDB cdb_u (
        .clk(clk),
        .rst_n(rst_n),

        // ALU writeback
        .alu_wb_valid      (alu_wb_valid),
        .alu_wb_ready      (alu_wb_ready),
        .alu_wb_rob_idx    (alu_wb_rob_idx),
        .alu_wb_prd_new    (alu_wb_prd_new),
        .alu_wb_data       (alu_wb_data),
        .alu_wb_epoch      (alu_wb_epoch),
        .alu_wb_uses_rd    (alu_wb_uses_rd),
        .alu_wb_pc         (alu_wb_pc),

        // BRU writeback
        .bru_wb_valid      (bru_wb_valid),
        .bru_wb_ready      (bru_wb_ready),
        .bru_wb_rob_idx    (bru_wb_rob_idx),
        .bru_wb_prd_new    (bru_wb_prd_new),
        .bru_wb_data       (bru_wb_data),
        .bru_wb_epoch      (bru_wb_epoch),
        .bru_wb_uses_rd    (bru_wb_uses_rd),
        .bru_wb_pc         (bru_wb_pc),

        .bru_act_taken     (act_taken),
        .bru_mispredict    (mispredict),
        .bru_redirect_valid(redirect_valid),
        .bru_redirect_pc   (redirect_pc),   


        // LSU writeback
        .lsu_wb_valid      (lsu_wb_valid),
        .lsu_wb_ready      (lsu_wb_ready),
        .lsu_wb_rob_idx    (lsu_wb_rob_idx),
        .lsu_wb_prd_new    (lsu_wb_prd_new),
        .lsu_wb_data       (lsu_wb_data),
        .lsu_wb_epoch      (lsu_wb_epoch),
        .lsu_wb_uses_rd    (lsu_wb_uses_rd),
        .lsu_wb_pc         (lsu_wb_pc),

        // To ROB + PRF
        .wb_valid          (wb_valid),
        .wb_ready          (wb_ready),
        .wb_pkt            (wb_pkt)
    );

endmodule