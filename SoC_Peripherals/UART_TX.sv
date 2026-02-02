`include "periph_defines.svh"
module UART_tx(
    input clk, // clock signal
    input rst_n, // active low reset
    input trmt, // start a transmission
    input [7:0] tx_data, // data to transmit
    input [UART_BAUD_DIV_W-1:0] baud_div, // baud rate divider
    output TX, // output
    output reg tx_done, // indicator that transmission is done
    output reg tx_ready
);
// define states, idle and transmission states
typedef enum logic [1:0] {IDLE,  TX_ST} state_t;

logic [3:0] bit_cnt; // Counts how many bits shifted
logic [UART_BAUD_DIV_W-1:0] baud_cnt; // baud rate counter
logic [8:0] tx_shft_reg; // shift register
logic shift; // shift control signal
logic init; // initiate a transmission
logic set_done; // set tx_done
logic transmitting; // for baud count increment
state_t cur_state; // current state of SM
state_t nxt_state; // next state

// flip flop block for bit cnt register
// clear when init, increment when shift is asserted
always_ff @(posedge clk) begin
    if (init) begin
        bit_cnt <= '0;
    end
    else if (shift) begin
        bit_cnt <= bit_cnt + 1;
    end
end

// flip flop block
// clear when init or shift, count during bit transmitting
always_ff @(posedge clk) begin
    if (init | shift) begin
        baud_cnt <= '0;
    end
    else if (transmitting) baud_cnt <= baud_cnt + 1;
end

// flip flop for tx_shift_reg
// default all ones
// shift in bits as UART protocol
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        tx_shft_reg <= '1;
    end
    else if (init) begin
        tx_shft_reg <= {tx_data, 1'b0};
    end
    else if (shift) begin
        tx_shft_reg <= {1'b1, tx_shft_reg[8:1]};
    end
end
// dataflow of TX
assign TX = tx_shft_reg[0];

// dataflow of shift
assign shift = (baud_cnt == baud_div)?1'b1:1'b0;

// tx_done register, asserted by set_done
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) tx_done <= 1'b0;
    else if (init) tx_done <= 1'b0;
    else if (set_done) tx_done <= 1'b1;
end

// state flops
always @(posedge clk, negedge rst_n) begin
    if (~rst_n) cur_state <= IDLE;
    else cur_state <= nxt_state;
end

assign tx_ready = (cur_state == IDLE)?1'b1:1'b0;

// SM logic
always_comb begin
    // default values of control signals
    set_done = 1'b0;
    init = 1'b0;
    transmitting = 1'b0;
    nxt_state = IDLE;
    // combinational logic of state transitions
    case (cur_state)
        // in IDLE state, trmt moves to TX_ST and assert init
        IDLE: if (trmt) begin
            nxt_state = TX_ST;
            init = 1'b1;

        end
        // handles when bit count is up or not yet
        TX_ST: begin
            if (bit_cnt != 10) begin
                // keep transmitting when bit_cnt less than 10
                transmitting = 1'b1;
                nxt_state = TX_ST;
            end
            else begin
                // go back to IDLE when shifted 10 bits
                nxt_state = IDLE;
                set_done = 1'b1;
            end
        end
        default:
            // state machines out of order, go back to IDLE
            nxt_state = IDLE;
    endcase
end

endmodule