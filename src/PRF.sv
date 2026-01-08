`include "defines.svh"
module PRF #(
  parameter int PHYS_REGS = 64,
  parameter int DW        = 32,
  parameter int PHYS_W    = $clog2(PHYS_REGS)
)(
  input  logic              clk,
  input  logic              rst_n,

  // Read ports
  input  logic [PHYS_W-1:0] raddr1 [FU_NUM-1:0],
  output logic [DW-1:0]     rdata1 [FU_NUM-1:0],
  output logic              rready1 [FU_NUM-1:0],

  input  logic [PHYS_W-1:0] raddr2 [FU_NUM-1:0],
  output logic [DW-1:0]     rdata2 [FU_NUM-1:0],
  output logic              rready2 [FU_NUM-1:0],

  // Rename alloc & recovery: mark destination not-ready
  input  logic              recovery_alloc_valid,
  input  logic [PHYS_W-1:0] recovery_alloc_pd_new,
  input  logic [1:0]        recovery_alloc_epoch,

  // Writeback: write data and mark ready
  input  logic              wb_valid,
  input  logic [PHYS_W-1:0] wb_pd,
  input  logic [DW-1:0]     wb_data,
  input  logic [1:0]        wb_epoch,

  // Optional: expose all ready bits for debug
  output logic [PHYS_REGS-1:0] ready_vec
);

  logic [DW-1:0] mem   [PHYS_REGS];
  logic          ready [PHYS_REGS];
  logic [1:0]    epoch [PHYS_REGS];

  // Combinational reads
  always_comb begin
    for (int i = 0; i < FU_NUM; i++) begin
      rdata1[i] = mem[raddr1[i]];
      rready1[i] = ready[raddr1[i]];

      rdata2[i] = mem[raddr2[i]];
      rready2[i] = ready[raddr2[i]];
    end
  end

  genvar i;
  generate
    for (i = 0; i < PHYS_REGS; i++) begin : GEN_READY_VEC
      always_comb ready_vec[i] = ready[i];
    end
  endgenerate

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < PHYS_REGS; k++) begin
        mem[k]   <= '0;
        ready[k] <= 1'b1; // initial: everything ready
        epoch[k] <= 2'b0;
      end
    end else begin
      // Default ordering: alloc marks not-ready, WB marks ready (WB wins if same reg)
      if (recovery_alloc_valid ) begin
        ready[recovery_alloc_pd_new] <= 1'b0;
        epoch[recovery_alloc_pd_new] <= recovery_alloc_epoch; // this should be a new epoch after mispredict
      end
      if (wb_valid && (epoch[wb_pd] == wb_epoch)) begin
        mem[wb_pd]   <= wb_data;
        ready[wb_pd] <= 1'b1;
      end
    end
  end

endmodule
