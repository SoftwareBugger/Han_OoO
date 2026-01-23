`include "periph_defines.svh"
module UART_rx(
    input clk, // clock signals
    input rst_n, // active low reset
    input clr_rdy, // clear ready
    output [7:0] rx_data, // data received
    input RX, // data input
    input [UART_BAUD_DIV_W-1:0] baud_div, // baud rate divider
    output reg rdy // ready signal when byte received
);
// define states we need, IDLE and RX_ST
typedef enum logic [1:0] {IDLE,  RX_ST} state_t;

logic [3:0] bit_cnt; // bit count
logic [UART_BAUD_DIV_W-1:0] baud_cnt; // baud rate count
logic [8:0] rx_shft_reg; // shift in register
logic shift; // shift signal
logic start; // start shifting in next byte
logic receiving; // in the process of receiving
logic set_rdy; // set rdy
logic f_RX; // single flop RX
logic df_RX; // double flop RX to rule out metastability
state_t cur_state; // current state
state_t nxt_state; // next state

// RX flop, preset to be able to detect start bit
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        df_RX <= 1;
        f_RX <= 1;
    end
    else begin
        df_RX <= f_RX;
        f_RX <= RX;
    end
end

// bit count, clear when started, increment when shifting
always_ff @(posedge clk) begin
    if (start) begin
        bit_cnt <= '0;
    end
    else if (shift) begin
        bit_cnt <= bit_cnt + 1;
    end
end

// counting baud rate, decrement and reset while shifting each bit
always_ff @(posedge clk) begin
    if (start | shift) begin
        if (start) baud_cnt <= baud_div >> 1;
        else baud_cnt <= baud_div;
    end
    else if (receiving) baud_cnt <= baud_cnt - 1;
end

// shift in data to shift register when shift time
always_ff @(posedge clk) begin
    if (shift) begin
        rx_shft_reg <= {df_RX, rx_shft_reg[8:1]};
    end
end

// In order, set assert or clear rdy
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        rdy <= 0;
    end
    else if (clr_rdy) rdy <= 0;
    else if (set_rdy) rdy <= 1;
    else if (start) rdy <= 0;
end

// dataflow for simple combinational logic of shift and rx_data
assign rx_data = rx_shft_reg[7:0];
assign shift = (baud_cnt == 0)?1'b1:1'b0;

// state flops
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) cur_state <= IDLE;
    else cur_state <= nxt_state;
end

// state transition combinational logic
always_comb begin
    // default values
    receiving = 1'b0;
    start = 1'b0;
    set_rdy = 1'b0;
    nxt_state = IDLE;
    // discussing states
    case (cur_state)
        // in IDLE only move when there is a start bit
        IDLE: begin
            if (~df_RX) begin
                nxt_state = RX_ST;
                start = 1'b1; // start when start bit received
            end
        end
        // in RX_ST, assert receiving before bit count is 10
        RX_ST: begin
            receiving = 1'b1;
            if (bit_cnt == 10) begin
                nxt_state = IDLE;
                set_rdy = 1'b1; // 10 bits arrived, ready
            end
            else nxt_state = RX_ST;
        end
        default:
        // go to IDLE by default
        nxt_state = IDLE;
    endcase
end

endmodule
