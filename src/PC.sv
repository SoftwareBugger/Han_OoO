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
    output logic [2:0]        fetch_epoch,

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
    logic [31:0] pc_issued_q [0:PC_QUEUE_SIZE-1];
    logic [31:0] pc_issued_resp_q [0:PC_QUEUE_SIZE-1];
    logic pred_taken_q [0:PC_QUEUE_SIZE-1];
    logic [31:0] pred_target_q [0:PC_QUEUE_SIZE-1];
    logic [2:0] pc_epoch_q [0:PC_QUEUE_SIZE-1];
    logic [$clog2(PC_QUEUE_SIZE)-1:0] pc_issued_head, pc_issued_tail, pc_issued_decoded;
    logic [$clog2(PC_QUEUE_SIZE)-1:0] pc_issued_head_to_decode, pc_issued_tail_to_head;
    logic pc_issued_response_valid [0:PC_QUEUE_SIZE-1];

    logic pred_valid;

    logic              pred_taken_bp;
    logic [31:0]       pred_target_bp;

    branch_predictor bp (
        .clk(clk),
        .rst_n(rst_n),
        .pred_pc(pc_req_q),
        .pred_valid(pred_valid),
        .pred_taken(pred_taken_bp),
        .pred_target(pred_target_bp),
        .update_valid(update_valid),
        .update_pc(update_pc),
        .update_taken(update_taken),
        .update_target(update_target),
        .update_mispredict(update_mispredict)
    );
    // ============================================================
    // Fetch global epoch
    // ============================================================
    logic [2:0] fetch_global_epoch;
    always_ff @(posedge clk) begin
        if (!rst_n)
            fetch_global_epoch <= 3'b0;
        else if (redirect_valid)
            fetch_global_epoch <= fetch_global_epoch + 3'b1;
    end

    // ============================================================
    // IMEM handshake
    // ============================================================
    assign imem_req_valid = !redirect_valid && (~(pc_issued_head_to_decode < 0) && ~(pc_issued_tail_to_head < 0) && (pc_issued_head_to_decode + pc_issued_tail_to_head != PC_QUEUE_SIZE - 1));
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
        else if (imem_req_fire) begin
            if (pred_valid && pred_taken_bp)
                pc_req_next = pred_target_bp;
            else
                pc_req_next = pc_req_q + 32'd4;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_req_q <= 32'h0000_0000;
            pc_issued_head <= '0;
            pc_issued_tail <= '0;
            pc_issued_decoded <= '0;
            pc_issued_head_to_decode <= '0;
            pc_issued_tail_to_head <= '0;
            for (int i = 0; i < PC_QUEUE_SIZE; i++) begin
                pc_issued_q[i] <= 32'h0000_0000;
                pc_epoch_q[i] <= 3'b0;
                pred_taken_q[i] <= 1'b0;
                pred_target_q[i] <= 32'h0000_0000;
                pc_issued_resp_q[i] <= 32'h0000_0000;
                pc_issued_response_valid[i] <= 1'b0;
            end
        end else begin
            pc_req_q <= pc_req_next;
            if (imem_resp_fire) begin
                pc_issued_head <= pc_issued_head + 1;
                pc_issued_resp_q[pc_issued_head] <= imem_resp_inst;
                pc_issued_response_valid[pc_issued_head] <= 1'b1;
            end 
            if (imem_req_fire) begin
                pc_issued_q[pc_issued_tail] <= pc_req_q;
                pc_epoch_q[pc_issued_tail] <= fetch_global_epoch;
                pred_taken_q[pc_issued_tail] <= pred_taken_bp;
                pred_target_q[pc_issued_tail] <= pred_target_bp;
                pc_issued_tail <= pc_issued_tail + 1;
                pc_issued_response_valid[pc_issued_tail] <= 1'b0;
            end
            if (fetch_fire) begin
                pc_issued_decoded <= pc_issued_decoded + 1;
            end
            unique case ({imem_resp_fire, imem_req_fire, fetch_fire})
                3'b100: begin
                    // only resp
                    pc_issued_head_to_decode <= pc_issued_head_to_decode + 1;
                    pc_issued_tail_to_head <= pc_issued_tail_to_head - 1;
                end
                3'b010: begin
                    // only req
                    pc_issued_tail_to_head <= pc_issued_tail_to_head + 1;
                end
                3'b001: begin
                    // only fetch
                    pc_issued_head_to_decode <= pc_issued_head_to_decode - 1;
                end
                3'b110: begin
                    // resp + req
                    pc_issued_head_to_decode <= pc_issued_head_to_decode + 1;
                end
                3'b101: begin
                    // resp + fetch
                    pc_issued_tail_to_head <= pc_issued_tail_to_head - 1;
                end
                3'b011: begin
                    // req + fetch
                    pc_issued_tail_to_head <= pc_issued_tail_to_head + 1;
                    pc_issued_head_to_decode <= pc_issued_head_to_decode - 1;
                end
                default: begin
                    // no ops
                end
            endcase
        end
    end

    // always_ff @(posedge clk) begin
    //     if (!rst_n) begin
    //         fetch_pc <= 32'h0000_0000;
    //         fetch_valid <= 1'b0;
    //         fetch_inst <= 32'b0;
    //         fetch_epoch <= 1'b0;
    //         pred_taken <= 1'b0;
    //         pred_target <= 32'h0000_0000;
    //     end else if (~(pc_issued_head_to_decode < 0)) begin
            
    //     end else if (fetch_fire) begin
    //         fetch_valid <= 1'b0;
    //     end
    // end
    always_comb begin
        if (~(pc_issued_head_to_decode < 0) && pc_issued_response_valid[pc_issued_decoded]) begin
            fetch_pc = pc_issued_q[pc_issued_decoded];
            fetch_inst = pc_issued_resp_q[pc_issued_decoded];
            fetch_epoch = pc_epoch_q[pc_issued_decoded];
            pred_taken = pred_taken_q[pc_issued_decoded];
            pred_target = pred_target_q[pc_issued_decoded];
            fetch_valid = 1'b1;
        end else begin
            fetch_pc = 32'h0000_0000;
            fetch_inst = 32'b0;
            fetch_epoch = 1'b0;
            pred_taken = 1'b0;
            pred_target = 32'h0000_0000;
            fetch_valid = 1'b0;
        end
    end
endmodule
