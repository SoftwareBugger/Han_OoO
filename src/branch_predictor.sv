module branch_predictor (
    input  logic              clk,
    input  logic              rst_n,

    /* =========================
     * Prediction Interface
     * ========================= */
    input  logic [31:0]       pred_pc,
    output logic              pred_valid,
    output logic              pred_taken,
    output logic [31:0]       pred_target,

    /* =========================
     * Update Interface
     * ========================= */
    input  logic              update_valid,
    input  logic [31:0]       update_pc,
    input  logic              update_taken,
    input  logic [31:0]       update_target,
    input  logic              update_mispredict
);

    // -------------------------
    // BTB: direct-mapped
    // index = PC[BTB_W+1:2] (word-aligned)
    // tag   = PC[31:BTB_W+2]
    // -------------------------
    typedef struct packed {
        logic              valid;
        logic [TAG_W-1:0]  tag;
        logic [31:0]       target;
        logic [1:0]        ctr;    // 2-bit saturating counter (optional but useful)
    } btb_entry_t;

    btb_entry_t btb [BTB_ENTRIES];

    // Index/tag helpers
    logic [BTB_W-1:0]  pred_idx, upd_idx;
    logic [TAG_W-1:0]  pred_tag, upd_tag;

    assign pred_idx = pred_pc[BTB_W+1:2];
    assign pred_tag = pred_pc[31:BTB_W+2];

    assign upd_idx  = update_pc[BTB_W+1:2];
    assign upd_tag  = update_pc[31:BTB_W+2];

    // -------------------------
    // Prediction (combinational)
    // pred_valid = BTB hit
    // pred_taken = (ctr says taken) AND (BTB hit)
    // pred_target = target on hit, else 0
    // -------------------------
    always_comb begin
        pred_valid  = 1'b0;
        pred_taken  = 1'b0;
        pred_target = 32'b0;

        if (btb[pred_idx].valid && (btb[pred_idx].tag == pred_tag)) begin
            pred_valid  = 1'b1;
            // 2-bit counter: 2/3 => taken, 0/1 => not taken
            pred_taken  = btb[pred_idx].ctr[1];
            pred_target = btb[pred_idx].target;
        end
    end

    // -------------------------
    // Update (sequential)
    // Policy:
    // - On update_valid:
    //   - allocate/overwrite BTB entry at upd_idx
    //   - set tag/target
    //   - update counter toward taken/not-taken based on update_taken
    // - You can optionally only allocate on taken branches
    //   (some designs do that to reduce pollution).
    // -------------------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BTB_ENTRIES; i++) begin
                btb[i].valid  <= 1'b0;
                btb[i].tag    <= '0;
                btb[i].target <= '0;
                btb[i].ctr    <= 2'b01; // weakly not-taken
            end
        end else begin
            if (update_valid) begin
                // Option A (simple): always allocate/update entry on any branch update
                // Option B (common): allocate only if taken OR mispredicted taken
                // Keep it simple:
                btb[upd_idx].valid <= 1'b1;
                btb[upd_idx].tag   <= upd_tag;

                // Target update: usually only meaningful for taken branches/jumps.
                // But writing always is harmless and simpler.
                btb[upd_idx].target <= update_target;

                // Counter update toward truth
                if (update_taken)
                    btb[upd_idx].ctr <= (&btb[upd_idx].ctr) ? 2'b11 : btb[upd_idx].ctr + 2'b01;
                else
                    btb[upd_idx].ctr <= (|btb[upd_idx].ctr) ? btb[upd_idx].ctr - 2'b01 : 2'b00;

                // update_mispredict is not required for correctness here.
                // If you want, you can make mispredict cause a stronger update:
                // e.g., set ctr to strong taken/not-taken immediately.
                // Uncomment if you want "aggressive" training:
                /*
                if (update_mispredict) begin
                    btb[upd_idx].ctr <= update_taken ? 2'b11 : 2'b00;
                end
                */
            end 
        end
    end

endmodule
