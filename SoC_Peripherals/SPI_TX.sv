module SPI_TX (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        wrt,        // start when done==1
  input  logic [15:0] tx_data,
  input  logic        pos_edge,
  input  logic        clk_phase,
  input  logic        width8,

  input  logic [15:0] clkdiv,     // NEW: programmable divider

  output logic        SS_n,
  output logic        SCLK,
  output logic        MOSI,
  input  logic        MISO,       // unused for TX-only
  output logic [15:0]  MISO_data,  // unused for TX-only
  output logic        done         // READY/IDLE level
);

  typedef enum logic [1:0] {IDLE, BITS, TRAIL} state_t;
  state_t state, nstate;

  logic [15:0] shft_reg;
  logic [15:0] miso_reg;
  logic [4:0]  bit_cntr;

  logic [15:0] div_cnt;
  logic        sclk_int;
  logic        sclk_int_ff;
  logic        tick;

  logic rst_cnt, en_bit, shft;

  // ------------------------
  // Clock divider → tick
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= 16'd0;
      tick    <= 1'b0;
    end else begin
      tick <= 1'b0;
      if (state != IDLE) begin
        if (div_cnt == clkdiv) begin
          div_cnt <= 16'd0;
          tick    <= 1'b1;
        end else
          div_cnt <= div_cnt + 1'b1;
      end else
        div_cnt <= 16'd0;
    end
  end

  // else if (state == TRAIL) begin
  //       if (div_cnt == (clkdiv >> 1)) begin
  //         div_cnt <= 16'd0;
  //         tick    <= 1'b1;
  //       end else
  //         div_cnt <= div_cnt + 1'b1;
  //     end 

  // ------------------------
  // SCLK generation
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_int <= 1'b1;
      sclk_int_ff <= 1'b1;
    end else if (state == IDLE) begin
      sclk_int <= clk_phase ? 1'b1 : 1'b0;
      sclk_int_ff <= sclk_int;
    end else if (tick && nstate != IDLE) begin
      sclk_int <= ~sclk_int;
      sclk_int_ff <= sclk_int;
    end else begin
      sclk_int_ff <= sclk_int;
    end
  end

  assign SCLK = sclk_int;

  logic pos_edge_sclk;
  logic neg_edge_sclk;
  assign pos_edge_sclk = (sclk_int == 1'b0) && (tick && nstate != IDLE);
  assign neg_edge_sclk = (sclk_int == 1'b1) && (tick && nstate != IDLE);

  logic seen_rise;
  logic seen_fall;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      seen_rise <= 1'b0;
      seen_fall <= 1'b0;
    end else begin
      if (pos_edge_sclk)
        seen_rise <= 1'b1;
      if (neg_edge_sclk)
        seen_fall <= 1'b1;
      if (state == IDLE) begin
        seen_rise <= 1'b0;
        seen_fall <= 1'b0;
      end
    end
  end

  // ------------------------
  // Shift register
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      shft_reg <= 16'h0000;
    else if (wrt && done)
      shft_reg <= tx_data;
    else if (shft)
      shft_reg <= {shft_reg[14:0], 1'b0};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      MOSI <= 1'b0;
    else if (shft && state != IDLE)
      MOSI <= shft_reg[15];
  end


  // ------------------------
  // Bit counter
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bit_cntr <= 5'd0;
      miso_reg <= 16'h0000;
    end else if (rst_cnt) begin
      bit_cntr <= 5'd0;
    end else if (en_bit) begin
      bit_cntr <= bit_cntr + 1'b1;
      miso_reg <= {miso_reg[14:0], MISO};
    end
  end

  assign MISO_data = miso_reg;

  // ------------------------
  // State register
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      state <= IDLE;
    else
      state <= nstate;
  end

  // ------------------------
  // Control FSM
  // ------------------------
  always_comb begin
    // defaults
    SS_n    = 1'b1;
    done    = 1'b0;
    rst_cnt = 1'b0;
    en_bit  = 1'b0;
    shft    = 1'b0;
    nstate  = state;

    case (state)
      IDLE: begin
        done    = 1'b1;      // READY
        rst_cnt = 1'b1;
        if (wrt)
          nstate = BITS;
      end

      BITS: begin
        SS_n   = 1'b0;
        en_bit = (pos_edge ? pos_edge_sclk && seen_fall : neg_edge_sclk && seen_rise);
        shft   = (pos_edge ? neg_edge_sclk : pos_edge_sclk);

        if ((!width8 && bit_cntr == 5'd16) ||
            ( width8 && bit_cntr == 5'd8))
          nstate = TRAIL;
      end

      TRAIL: begin
        SS_n = 1'b0;
        if (tick)
          nstate = IDLE;
      end
    endcase
  end

endmodule
