`include "defines.svh"

// ROB interface notes:
// - Allocation takes the decoded bundle + phys bookkeeping (pd_new/pd_old) from rename.
// - Commit exposes the committed ROB entry as a single struct (commit_entry) plus its index.
// - Writeback takes a single fu_wb_t packet.
//
// This keeps the port list small and lets you extend fields through defines.svh.

module ROB #(
    parameter int ROB_SIZE_P = ROB_SIZE,
    parameter int ROB_W_P    = ROB_W,
    parameter int PHYS_W_P   = PHYS_W
)(

    input  logic clk,
    input  logic rst_n,

    /* =========================
     * Allocation / Dispatch (from Rename)
     * ========================= */
    input  logic           alloc_valid,
    output logic           alloc_ready,
    input  decoded_bundle_t alloc_bundle,         // decoded fields (pc, uses_rd, rd_arch, uop_class, ...)
    input  logic [PHYS_W_P-1:0] alloc_pd_new,       // new phys dest (if uses_rd)
    input  logic [PHYS_W_P-1:0] alloc_pd_old,       // old phys dest (for free-on-commit)
    output logic [ROB_W_P-1:0]  alloc_rob_idx,

    /* =========================
     * Writeback (from CDB / WB arb)
     * ========================= */
    input  logic    wb_valid,
    output logic    wb_ready,
    input  fu_wb_t  wb_pkt,

    /* =========================
     * Commit Interface
     * ========================= */
    output logic         commit_valid,
    input  logic         commit_ready,
    output rob_entry_t   commit_entry,            // committed entry (pd_old/new, rd_arch, class flags, epoch, ...)
    output logic [ROB_W_P-1:0] commit_rob_idx,

    /* =========================
     * Flush Control (external "nuke" / reset pipeline)
     * ========================= */
    input  logic           flush_valid,
    input  logic [ROB_W_P-1:0] flush_rob_idx,       // currently unused (kept for future selective flush)
    input  logic [1:0]        flush_epoch,        // currently unused (kept for future selective flush)

    /* =========================
     * Recovery (from branch mispredict handling inside ROB)
     * ========================= */
    output logic           recover_valid,
    output logic [ROB_W_P-1:0] recover_rob_idx,     // ROB idx that caused recovery
    output rob_entry_t     recover_entry,         // most-recent allocated entry while recovering (tail-1)

    /* =========================
     * Epoch management
     * ========================= */
    output logic [1:0]     global_epoch
);

    // -----------------------------
    // Helpers: classify uops from decoded bundle
    // -----------------------------
    logic alloc_is_branch, alloc_is_load, alloc_is_store;

    always_comb begin
        alloc_is_branch = (alloc_bundle.uop_class == UOP_BRANCH) ||
                          (alloc_bundle.uop_class == UOP_JUMP);
        alloc_is_load   = (alloc_bundle.uop_class == UOP_LOAD);
        alloc_is_store  = (alloc_bundle.uop_class == UOP_STORE);
    end

    /* =========================
     * Storage
     * ========================= */
    rob_entry_t rob_mem [ROB_SIZE_P];
    logic [ROB_SIZE_P-1:0] rob_br_finished;

    logic [ROB_W_P:0] head_ptr;
    logic [ROB_W_P:0] tail_ptr;
    logic [ROB_W_P:0] count;

    /* =========================
     * Status / handshakes
     * ========================= */
    assign alloc_ready = (count < ROB_SIZE_P) && (~recover_valid);
    logic commit_fire;
    logic alloc_fire;
    assign commit_fire = commit_valid && commit_ready;
    assign alloc_fire  = alloc_valid && alloc_ready;

    /* =========================
     * ROB Update Logic
     * ========================= */
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count    <= '0;
            for (int i = 0; i < ROB_SIZE_P; i++) begin
                rob_mem[i] <= '0;
            end
            wb_ready <= 1'b1;
            rob_br_finished <= '1;
        end else if (flush_valid) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count    <= '0;
            for (int i = 0; i < ROB_SIZE_P; i++) begin
                rob_mem[i].valid <= 1'b0;
                rob_mem[i].done  <= 1'b0;
            end
            rob_br_finished <= '1;
            wb_ready <= 1'b1;
        end else if (~recover_valid) begin
            // =====================
            // Writeback
            // =====================
            wb_ready <= 1'b1;
            if (wb_valid) begin
                if (rob_mem[wb_pkt.rob_idx].valid &&
                    rob_mem[wb_pkt.rob_idx].epoch == wb_pkt.epoch) begin
                    rob_mem[wb_pkt.rob_idx].done <= 1'b1;
                    // Only meaningful for branches; keep 0 otherwise.
                    rob_mem[wb_pkt.rob_idx].mispredict <= (wb_pkt.is_branch && wb_pkt.mispredict);
                    rob_br_finished[wb_pkt.rob_idx] <= rob_mem[wb_pkt.rob_idx].is_branch ? 1'b1
                                                                                           : rob_br_finished[wb_pkt.rob_idx];
                end
            end

            // =====================
            // Commit
            // =====================
            if (commit_fire) begin
                rob_mem[head_ptr].valid <= 1'b0;
                rob_mem[head_ptr].done  <= 1'b0;
                rob_br_finished[head_ptr] <= 1'b1;
            end

            // =====================
            // Allocation
            // =====================
            if (alloc_fire) begin
                rob_mem[tail_ptr].valid     <= 1'b1;
                rob_mem[tail_ptr].done      <= 1'b0;
                rob_mem[tail_ptr].epoch     <= global_epoch;

                rob_mem[tail_ptr].uses_rd   <= alloc_bundle.uses_rd;
                rob_mem[tail_ptr].rd_arch   <= alloc_bundle.rd_arch;
                rob_mem[tail_ptr].pd_new    <= alloc_pd_new;
                rob_mem[tail_ptr].pd_old    <= alloc_pd_old;

                rob_mem[tail_ptr].is_branch <= alloc_is_branch;
                rob_mem[tail_ptr].mispredict<= 1'b0;
                rob_mem[tail_ptr].is_load   <= alloc_is_load;
                rob_mem[tail_ptr].is_store  <= alloc_is_store;

                rob_mem[tail_ptr].pc        <= alloc_bundle.pc;

                // Only branches participate in the "all branches finished" barrier.
                rob_br_finished[tail_ptr]   <= alloc_is_branch ? 1'b0 : 1'b1;
            end

            // =====================
            // Pointers & Count
            // =====================
            unique case ({commit_fire, alloc_fire})
                2'b10: begin
                    head_ptr <= head_ptr + 1'b1;
                    count    <= count - 1'b1;
                end
                2'b01: begin
                    tail_ptr <= tail_ptr + 1'b1;
                    count    <= count + 1'b1;
                end
                2'b11: begin
                    head_ptr <= head_ptr + 1'b1;
                    tail_ptr <= tail_ptr + 1'b1;
                    // count unchanged
                end
                default: begin end
            endcase
        end
    end

    // Tail index is where the next allocation will land.
    assign alloc_rob_idx = tail_ptr[ROB_W_P-1:0];

    /* =========================
     * Commit Logic
     * ========================= */
    // NOTE: This keeps your original store barrier:
    // - allow committing a store only when all branch entries are resolved.
    assign commit_valid =
        (count != 0) &&
        rob_mem[head_ptr].valid &&
        rob_mem[head_ptr].done &&
        (!recover_valid) &&
        (rob_mem[head_ptr].is_store ? (&rob_br_finished) : 1'b1);

    // Compact commit payload
    always_comb begin
        commit_entry   = rob_mem[head_ptr];
        commit_rob_idx = head_ptr[ROB_W_P-1:0];
        if (count == 0) begin
            commit_entry = '0;
        end
    end

    /* =========================
     * Recovery Logic
     * ========================= */
    typedef enum logic [1:0] {
        NORMAL,
        RECOVERY
    } state_t;

    state_t current_state, next_state;

    // "wb mispredict" event (only when the wb matches the ROB entry's epoch)
    logic wb_mispredict_fire;
    assign wb_mispredict_fire =
        wb_valid &&
        wb_pkt.is_branch &&
        rob_mem[wb_pkt.rob_idx].valid &&
        (rob_mem[wb_pkt.rob_idx].epoch == wb_pkt.epoch) &&
        wb_pkt.mispredict;

    logic init_recover_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state  <= NORMAL;
            recover_rob_idx <= '0;
        end else if (flush_valid) begin
            current_state  <= NORMAL;
            recover_rob_idx <= '0;
        end else begin
            current_state <= next_state;
            if (init_recover_idx) begin
                recover_rob_idx <= wb_pkt.rob_idx;
            end
        end
    end

    // In recovery, expose the youngest entry (tail-1) so downstream can walk/squash.
    assign recover_entry = rob_mem[tail_ptr - 1'b1];

    always_comb begin
        next_state       = current_state;
        recover_valid    = 1'b0;
        init_recover_idx = 1'b0;

        unique case (current_state)
            NORMAL: begin
                if (wb_mispredict_fire) begin
                    next_state       = RECOVERY;
                    recover_valid    = 1'b1;
                    init_recover_idx = 1'b1;
                end
            end
            RECOVERY: begin
                // Stay in recovery until tail has rewound past the mispredicted branch.
                // External logic is expected to pop/squash younger entries by driving flush_valid
                // or by otherwise coordinating with your pipeline control.
                if (tail_ptr == (recover_rob_idx + 1'b1)) begin
                    next_state = NORMAL;
                end else begin
                    recover_valid = 1'b1;
                end
            end
            default: begin
                next_state = NORMAL;
            end
        endcase
    end

    /* =========================
     * Epoch management
     * ========================= */
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_epoch <= 2'b0;
        end else if (flush_valid) begin
            global_epoch <= 2'b0;
        end else if (wb_mispredict_fire) begin
            global_epoch <= global_epoch + 2'b01;
        end
    end

endmodule
