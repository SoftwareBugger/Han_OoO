module FreeList #(
    parameter int PHYS_REGS = 64,
    parameter int ARCH_REGS = 32,
    parameter int PHYS_W    = $clog2(PHYS_REGS)
)(
    input  logic clk,
    input  logic rst_n,

    /* =========================
     * Allocate (rename)
     * ========================= */
    input  logic        alloc_valid,
    output logic        alloc_ready,
    output logic [PHYS_W-1:0] alloc_pd,

    /* =========================
     * Free (commit & recovery)
     * ========================= */
    input  logic        free_valid,
    input  logic [PHYS_W-1:0] free_pd,

    /* =========================
     * Flush
     * ========================= */
    input  logic        flush_valid
);

    localparam int FL_SIZE = PHYS_REGS;

    logic [PHYS_W-1:0] freelist [FL_SIZE];
    logic [$clog2(FL_SIZE)-1:0] head, tail;
    logic [$clog2(FL_SIZE+1)-1:0] count;

    assign alloc_ready = (count != 0);
    assign alloc_pd    = freelist[head];

    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head  <= 0;
            tail  <= 0;
            count <= 0;

            // initialize free regs: skip x0..x31
            for (i = 0; i < ARCH_REGS; i++) begin
                freelist[i] <= PHYS_REGS - ARCH_REGS + i;
            end
            tail  <= PHYS_REGS - ARCH_REGS;
            count <= PHYS_REGS - ARCH_REGS;
        end else if (flush_valid) begin
            // v0: reset freelist
            head  <= 0;
            tail  <= 0;
            count <= 0;
            for (i = 0; i < ARCH_REGS; i++) begin
                freelist[i] <= PHYS_REGS - ARCH_REGS + i;
            end
            tail  <= PHYS_REGS - ARCH_REGS;
            count <= PHYS_REGS - ARCH_REGS;
        end else begin
            if (free_valid) begin
                freelist[tail] <= free_pd;
                tail  <= tail + 1'b1;
                count <= (alloc_valid && alloc_ready) ? count : count + 1'b1;
            end
            if (alloc_valid && alloc_ready) begin
                head  <= head + 1'b1;
                count <= (free_valid) ? count : count - 1'b1;
            end
        end
    end

endmodule
