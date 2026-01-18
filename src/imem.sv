module imem #(
    parameter int MEM_WORDS = 16384,
    parameter string HEXFILE = "C:\\RTL\\Han_OoO\\sw\\prog.hex",
    parameter int LATENCY = 1,          // cycles from req_fire to resp available
    parameter int RESP_FIFO_DEPTH = 4   // absorbs resp_ready stalls
)(
    input  logic        clk,
    input  logic        rst_n,

    // Request
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] req_addr,

    // Response
    output logic        resp_valid,
    input  logic        resp_ready,
    output logic [31:0] resp_inst
);

    // BRAM port A signals
    logic [0:0]  bram_wea;
    logic [13:0] bram_addra;
    logic [31:0] bram_dina;
    logic [31:0] bram_douta;

    blk_mem_gen_1 u_imem_bram (
        .clka  (clk),
        .wea   (bram_wea),
        .addra (bram_addra),
        .dina  (bram_dina),
        .douta (bram_douta)
    );

    // ================================================================
    // Request queue
    localparam int REQ_QUEUE_SIZE = LATENCY + RESP_FIFO_DEPTH;
    logic [31:0] req_addr_q [0:REQ_QUEUE_SIZE-1];
    logic [31:0] resp_inst_q [0:REQ_QUEUE_SIZE-1];
    logic [REQ_QUEUE_SIZE-1:0] done;
    logic [$clog2(REQ_QUEUE_SIZE)-1:0] req_head, req_tail, req_last_tail, req_count;
    logic last_req_fire;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_head      <= '0;
            req_tail      <= '0;
            req_last_tail <= '0;
            req_count     <= '0;
            done          <= '0;
            last_req_fire <= 1'b0;
            for (int i = 0; i < REQ_QUEUE_SIZE; i++) begin
                resp_inst_q[i] <= '0;
                req_addr_q[i] <= '0;
            end
        end else begin
            // Enqueue
            if (req_valid && req_ready) begin
                req_addr_q[req_tail] <= req_addr;
                req_tail <= (req_tail == REQ_QUEUE_SIZE-1) ? 0 : req_tail + 1;
            end

            // Dequeue on response accepted
            if (resp_valid && resp_ready) begin
                req_head <= (req_head == REQ_QUEUE_SIZE-1) ? 0 : req_head + 1;
                done[req_head] <= 1'b0;
            end
            last_req_fire <= (req_valid && req_ready);
            if (last_req_fire) begin
                req_last_tail <= req_tail;
                resp_inst_q[req_last_tail] <= bram_douta;
                done[req_last_tail] <= last_req_fire;
            end

            unique case ({(req_valid && req_ready), (resp_valid && resp_ready)})
                2'b10: req_count <= req_count + 1; // enqueue only
                2'b01: req_count <= req_count - 1; // dequeue only
                default: ; // no change or both
            endcase
        end
    end
    assign req_ready  = (req_count != REQ_QUEUE_SIZE);
    assign resp_valid = done[req_head];
    assign resp_inst  = resp_inst_q[req_head];

    assign bram_wea   = 1'b0; // read-only
    assign bram_addra = req_addr[15:2]; // word address
    assign bram_dina  = 32'd0; // unused


endmodule
