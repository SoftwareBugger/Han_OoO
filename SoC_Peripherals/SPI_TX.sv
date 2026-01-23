module SPI_TX (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        wrt,        // start when done==1
  input  logic [15:0] tx_data,
  input  logic        pos_edge,
  input  logic        width8,

  input  logic [15:0] clkdiv,     // NEW: programmable divider

  output logic        SS_n,
  output logic        SCLK,
  output logic        MOSI,
  output logic        done         // READY/IDLE level
);

  typedef enum logic [1:0] {IDLE, BITS, TRAIL} state_t;
  state_t state, nstate;

  logic [15:0] shft_reg;
  logic [4:0]  bit_cntr;

  logic [15:0] div_cnt;
  logic        sclk_int;
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

  // ------------------------
  // SCLK generation
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      sclk_int <= 1'b0;
    else if (state == IDLE)
      sclk_int <= pos_edge ? 1'b0 : 1'b1;
    else if (tick)
      sclk_int <= ~sclk_int;
  end

  assign SCLK = sclk_int;

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

  assign MOSI = shft_reg[15];

  // ------------------------
  // Bit counter
  // ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      bit_cntr <= 5'd0;
    else if (rst_cnt)
      bit_cntr <= 5'd0;
    else if (en_bit)
      bit_cntr <= bit_cntr + 1'b1;
  end

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
        en_bit = tick & (pos_edge ? ~sclk_int : sclk_int);
        shft   = tick & (pos_edge ? sclk_int : ~sclk_int);

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
