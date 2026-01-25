module fetch (
    input  logic clk,
    input  logic rst_n,

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
     * Decode Interface
     * ========================= */
    input  logic       decode_ready,
    output logic       decode_valid,
    output decoded_bundle_t decoded_bundle_fields,

    /* =========================
     * imem Interface
     * ========================= */
    imem_if.master imem_m
);
    /*=========================
     * PC instance
     * ========================= */

    /* =========================
     * Downstream: decode accepts a fetched instruction
     * ========================= */
    logic              fetch_ready;
    logic              fetch_valid;
    logic [31:0]       fetch_pc;
    logic [31:0]       fetch_inst;
    logic [2:0]        fetch_epoch;

    /* =========================
     * IMEM request
     * ========================= */
    logic              imem_req_valid;
    logic              imem_req_ready;
    logic [31:0]       imem_req_addr;

    /* =========================
     * IMEM response
     * ========================= */
    logic              imem_resp_valid;
    logic              imem_resp_ready;
    logic [31:0]       imem_resp_inst;

    assign imem_m.imem_req_valid = imem_req_valid;
    assign imem_req_ready   = imem_m.imem_req_ready;
    assign imem_m.imem_req_addr  = imem_req_addr;
    assign imem_resp_valid  = imem_m.imem_resp_valid;
    assign imem_m.imem_resp_ready= imem_resp_ready;
    assign imem_resp_inst   = imem_m.imem_resp_inst;

    /* =========================
     * Predictor outputs
     * ========================= */
    logic              pred_taken;
    logic [31:0]       pred_target;


    PC pc_inst (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_ready(fetch_ready),
        .fetch_valid(fetch_valid),
        .fetch_pc(fetch_pc),
        .fetch_inst(fetch_inst),
        .fetch_epoch(fetch_epoch),
        .redirect_valid(redirect_valid),
        .redirect_pc(redirect_pc),
        .update_valid(update_valid),
        .update_pc(update_pc),
        .update_taken(update_taken),
        .update_target(update_target),
        .update_mispredict(update_mispredict),
        .imem_req_valid(imem_req_valid),
        .imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr),
        .imem_resp_valid(imem_resp_valid),
        .imem_resp_ready(imem_resp_ready),
        .imem_resp_inst(imem_resp_inst),
        .pred_taken(pred_taken),
        .pred_target(pred_target)
    );

    /* =========================
     * decode instance
     * ========================= */
    decode decode_inst (
        .clk(clk),
        .rst_n(rst_n),
        .redirect_valid(redirect_valid),
        .fetch_inst(fetch_inst),
        .fetch_pc(fetch_pc),
        .fetch_valid(fetch_valid),
        .fetch_ready(fetch_ready),
        .fetch_epoch(fetch_epoch),
        .pred_taken(pred_taken),
        .pred_target(pred_target),
        .decode_ready(decode_ready),
        .decode_valid(decode_valid),
        .decoded_bundle_fields(decoded_bundle_fields)
    );
endmodule