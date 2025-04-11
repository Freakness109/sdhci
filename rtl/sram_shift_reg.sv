/**
 * Shift Register built using an SRAM
 * The first element is always readable at `read_data_o`
 * Asserting `pop_front_i` tries to put the next word into `read_data_o` within one clock cycle
 * If a push is happening at the same time the pop is delayed by a clock cycle
 * The first push (when empty_o = '1) takes 2 clock cycles to appear in the `front_data_o`
 */

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module sram_shift_reg #(
  parameter int unsigned NumWords     = 1024,
  parameter int unsigned DataWidth    = 32,
  parameter int unsigned AddrWidth    = cf_math_pkg::idx_width(NumWords),
  parameter int unsigned LengthWidth  = cf_math_pkg::idx_width(NumWords + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                 pop_front_i,
  output logic [DataWidth-1:0] front_data_o,
  input  logic                 push_back_i,
  input  logic [DataWidth-1:0] back_data_i,
  
  output logic empty_o,
  output logic full_o
);
  // Push a pop operation to the next clock cycle if the sram is busy
  logic pop_front_q, pop_front_d;
  `FF(pop_front_q, pop_front_d, '0, clk_i, rst_ni);
  assign pop_front_d = pop_front_i & (push_back_i | pop_front_q);

`ifdef VERILATOR
  assert property (@(posedge clk_i) !(pop_front_i & push_back_i & pop_front_q));
`endif

  logic [AddrWidth-1:0] back_addr_q, back_addr_d;
  `FF(back_addr_q, back_addr_d, '0, clk_i, rst_ni);
  assign back_addr_d = push_back_i ? AddrWidth'((back_addr_q + 1) % NumWords) : back_addr_q;

  logic [LengthWidth-1:0] length_q, length_d;
  `FF(length_q, length_d, '0, clk_i, rst_ni);
  assign length_d = push_back_i ? length_q + 1 : pop_front_i | pop_front_q ? length_q - 1 : length_q;

  assign empty_o = length_q == '0;
  assign full_o = length_q == NumWords;


`ifdef VERILATOR
  assert property (@(posedge clk_i) !(pop_front_i && empty_o));
  assert property (@(posedge clk_i) !(push_back_i && full_o));
`endif

  // // To make writes instantly appear in reads
  // logic first_push_q, first_push_d;
  // `FF(first_push_q, first_push_d, '0, clk_i, rst_ni);
  // assign first_push_d = empty_o && req_i && we_i;

  // logic [DataWidth-1:0] back_data_q, back_data_d;
  // `FF(back_data_q, back_data_d, '0, clk_i, rst_ni);
  // assign back_data_d = back_data_i;

  // logic [DataWidth-1:0] read_data;
  // assign front_data_o = first_push_q ? back_data_q : read_data;

  tc_sram #(
    .NumWords  ( NumWords ),
    .DataWidth ( DataWidth ),
    .NumPorts  ( 1 ),
    .Latency   ( 1 )
  ) i_sram (
    .clk_i,
    .rst_ni,

    .req_i   (push_back_i | pop_front_i | pop_front_q),
    .we_i    (push_back_i),
    .addr_i  (push_back_i ? back_addr_q : AddrWidth'((back_addr_q - length_q + 1) % NumWords)),

    .wdata_i (back_data_i),
    .be_i    ('1),
    .rdata_o (front_data_o)
    // .rdata_o (read_data)
  );
endmodule