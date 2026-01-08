`include "defines.svh"

module PC (
    input  logic              clk,
    input  logic              rst_n,

    /* =========================
     * Downstream: decode accepts a fetched instruction
     * ========================= */
    input  logic              fetch_ready,
    output logic              fetch_valid,
    output logic [31:0]       fetch_pc,
    output logic [31:0]       fetch_inst,
    output logic              fetch_epoch,

    /* =========================
     * Redirect / predictor update
     * ========================= */
    input  logic              redirect_valid,
    input  logic [31:0]       redirect_pc,

    input  logic              update_valid,
    input  logic [31:0]       update_pc,
    input  logic              update_taken,
    input  logic [31:0]       update_target,
    input  logic              update_mispredict,

    /* =========================
     * IMEM request
     * ========================= */
    output logic              imem_req_valid,
    input  logic              imem_req_ready,
    output logic [31:0]       imem_req_addr,

    /* =========================
     * IMEM response
     * ========================= */
    input  logic              imem_resp_valid,
    output logic              imem_resp_ready,
    input  logic [31:0]       imem_resp_inst,

    /* =========================
     * Predictor outputs
     * ========================= */
    output logic              pred_taken,
    output logic [31:0]       pred_target
);

    // ============================================================
    // Request PC
    // ============================================================
    localparam int PC_QUEUE_SIZE = 8;
    logic [31:0] pc_req_q, pc_req_next;
    logic [31:0] pc_issued_q [PC_QUEUE_SIZE-1:0];
    logic pc_epoch_q [PC_QUEUE_SIZE-1:0];
    logic [$clog2(PC_QUEUE_SIZE)-1:0] pc_issued_head, pc_issued_tail;

    logic pred_valid;

    branch_predictor bp (
        .clk(clk),
        .rst_n(rst_n),
        .pred_pc(pc_req_q),
        .pred_valid(pred_valid),
        .pred_taken(pred_taken),
        .pred_target(pred_target),
        .update_valid(update_valid),
        .update_pc(update_pc),
        .update_taken(update_taken),
        .update_target(update_target),
        .update_mispredict(update_mispredict)
    );
    // ============================================================
    // Fetch global epoch
    // ============================================================
    logic fetch_global_epoch;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fetch_global_epoch <= 1'b0;
        else if (redirect_valid)
            fetch_global_epoch <= ~fetch_global_epoch;
    end

    // ============================================================
    // IMEM handshake
    // ============================================================
    assign imem_req_valid = !redirect_valid;
    assign imem_req_addr  = pc_req_q;

    logic imem_req_fire; 
    assign imem_req_fire = imem_req_valid && imem_req_ready;

    assign imem_resp_ready = fetch_ready;
    logic imem_resp_fire;
    assign imem_resp_fire = imem_resp_valid && imem_resp_ready;

    logic fetch_fire;
    assign fetch_fire = fetch_valid && fetch_ready;


    // ============================================================
    // PC update
    // ============================================================
    always_comb begin
        pc_req_next = pc_req_q;
        if (redirect_valid)
            pc_req_next = redirect_pc;
        else if (~fetch_fire) begin
            // hold PC
            pc_req_next = pc_req_q;
        end else if (imem_req_fire) begin
            if (pred_valid && pred_taken)
                pc_req_next = pred_target;
            else
                pc_req_next = pc_req_q + 32'd4;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_req_q <= 32'h0000_0000;
            pc_issued_head <= '0;
            pc_issued_tail <= '0;
            for (int i = 0; i < PC_QUEUE_SIZE; i++) begin
                pc_issued_q[i] <= 32'h0000_0000;
                pc_epoch_q[i] <= 1'b0;
            end
        end else begin
            pc_req_q <= pc_req_next;
            if (imem_resp_fire) begin
                pc_issued_head <= pc_issued_head + 1;
            end 
            if (imem_req_fire) begin
                pc_issued_q[pc_issued_tail] <= pc_req_q;
                pc_epoch_q[pc_issued_tail] <= fetch_global_epoch;
                pc_issued_tail <= pc_issued_tail + 1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_pc <= 32'h0000_0000;
            fetch_valid <= 1'b0;
            fetch_inst <= 32'b0;
        end else if (imem_resp_fire) begin
            fetch_pc <= pc_issued_q[pc_issued_head];
            fetch_valid <= 1'b1;
            fetch_inst <= imem_resp_inst;
        end else if (fetch_fire) begin
            fetch_valid <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_epoch <= 32'b0;
        end else if (fetch_fire) begin
            fetch_epoch <= (fetch_global_epoch == pc_epoch_q[pc_issued_head]) ? fetch_global_epoch : ~fetch_global_epoch;
        end
    end

endmodule
