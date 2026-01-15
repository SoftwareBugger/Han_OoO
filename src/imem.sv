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

    // -----------------------------
    // Memory array
    // -----------------------------
    logic [31:0] mem [0:MEM_WORDS-1];

    initial begin
        if (HEXFILE != "")
            $readmemh(HEXFILE, mem);
    end

    // ============================================================
    // Fixed-latency in-order request pipeline
    // ============================================================
    localparam int PIPE_STAGES = (LATENCY < 0) ? 0 : LATENCY;

    logic [31:0] addr_pipe [0:PIPE_STAGES];
    logic        vld_pipe  [0:PIPE_STAGES];

    // ============================================================
    // Response FIFO
    // ============================================================
    localparam int RF_W = (RESP_FIFO_DEPTH <= 1) ? 1 : $clog2(RESP_FIFO_DEPTH);
    localparam int RC_W = $clog2(RESP_FIFO_DEPTH + 1);

    logic [31:0] rf_mem [0:RESP_FIFO_DEPTH-1];
    logic [RF_W-1:0] rf_head_q, rf_tail_q;
    logic [RC_W-1:0] rf_count_q;

    wire rf_empty = (rf_count_q == 0);
    wire rf_full  = (rf_count_q == RESP_FIFO_DEPTH);

    assign resp_valid = !rf_empty;
    assign resp_inst  = rf_mem[rf_head_q];

    wire rf_pop = resp_valid && resp_ready;

    function automatic [RF_W-1:0] rf_inc(input [RF_W-1:0] v);
        rf_inc = (v == RESP_FIFO_DEPTH-1) ? '0 : (v + 1'b1);
    endfunction

    // ============================================================
    // Pipeline stall when output wants to produce but FIFO is full
    // ============================================================
    wire pipe_out_valid = vld_pipe[PIPE_STAGES];
    wire pipe_stall     = pipe_out_valid && rf_full;

    // Can accept a new request when not stalling
    assign req_ready = !pipe_stall;
    wire req_fire = req_valid && req_ready;

    // ============================================================
    // FIFO push from pipeline output
    // ============================================================
    wire rf_push = pipe_out_valid && !rf_full;

    // ============================================================
    // FIFO count next-state
    // ============================================================
    logic [RC_W-1:0] rf_count_n;
    always_comb begin
        rf_count_n = rf_count_q;
        unique case ({rf_push, rf_pop})
            2'b10: rf_count_n = rf_count_q + 1'b1; // push only
            2'b01: rf_count_n = rf_count_q - 1'b1; // pop only
            2'b11: rf_count_n = rf_count_q;        // push + pop
            default: ;
        endcase
    end

    // ============================================================
    // Sequential logic
    // ============================================================
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // clear pipeline
            for (i = 0; i <= PIPE_STAGES; i++) begin
                addr_pipe[i] <= 32'b0;
                vld_pipe[i]  <= 1'b0;
            end

            // clear FIFO
            rf_head_q  <= '0;
            rf_tail_q  <= '0;
            rf_count_q <= '0;

        end else begin
            // -----------------------------
            // Response FIFO pop
            // -----------------------------
            if (rf_pop) begin
                rf_head_q <= rf_inc(rf_head_q);
            end

            // -----------------------------
            // Enqueue response from pipeline
            // -----------------------------
            if (rf_push) begin
                rf_mem[rf_tail_q] <= mem[addr_pipe[PIPE_STAGES][31:2]];
                rf_tail_q <= rf_inc(rf_tail_q);
            end

            rf_count_q <= rf_count_n;

            // -----------------------------
            // Advance pipeline if not stalled
            // -----------------------------
            if (!pipe_stall) begin
                for (i = PIPE_STAGES; i >= 1; i--) begin
                    addr_pipe[i] <= addr_pipe[i-1];
                    vld_pipe[i]  <= vld_pipe[i-1];
                end

                addr_pipe[0] <= req_addr;
                vld_pipe[0]  <= req_fire;
            end
            // else: hold all stages (oldest request remains parked at output)
        end
    end

endmodule
