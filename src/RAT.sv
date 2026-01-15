module RAT #(
    parameter int ARCH_REGS = 32,
    parameter int PHYS_REGS = 64,
    parameter int PHYS_W    = $clog2(PHYS_REGS)
)(
    input  logic clk,
    input  logic rst_n,

    /* =========================
     * Rename (read)
     * ========================= */
    input  logic [4:0]  rs1_arch,
    input  logic [4:0]  rs2_arch,
    input  logic [4:0]  rd_arch, // for debug
    output logic [PHYS_W-1:0] rs1_phys,
    output logic [PHYS_W-1:0] rs2_phys,
    output logic [PHYS_W-1:0] rd_phys, // for debug

    /* =========================
     * Rename (write / dispatch)
     * ========================= */
    input  logic        rename_valid,
    input  logic        rename_uses_rd,
    input  logic [4:0]  rename_rd_arch,
    input  logic [PHYS_W-1:0] rename_pd_new,

    /* =========================
     * Flush
     * ========================= */
    input  logic        flush_valid,

    /* =========================
    * Recovery (from ROB)
    * ========================= */
    input logic              recover_valid,
    input logic [PHYS_W-1:0] recover_pd,
    input logic [4:0]        recover_rd_arch

);

    /* =========================
     * RAT storage
     * ========================= */
    logic [PHYS_W-1:0] rat [ARCH_REGS];

    /* =========================
     * Combinational read
     * ========================= */
    assign rs1_phys = rat[rs1_arch];
    assign rs2_phys = rat[rs2_arch];
    assign rd_phys  = rat[rd_arch];

    /* =========================
     * Sequential update
     * ========================= */
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // identity map on reset
            for (i = 0; i < ARCH_REGS; i++)
                rat[i] <= i[PHYS_W-1:0];
        end else if (flush_valid) begin
            // v0: restore architectural state
            for (i = 0; i < ARCH_REGS; i++)
                rat[i] <= i[PHYS_W-1:0];
        end else begin
            // rename update (speculative)
            if (recover_valid) begin
                rat[recover_rd_arch] <= recover_pd;
            end else if (rename_valid && rename_uses_rd) begin
                rat[rename_rd_arch] <= rename_pd_new;
            end
        end
    end

endmodule
