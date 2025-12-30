// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Micha Wehrli <miwehrli@student.ethz.ch>

`include "common_cells/registers.svh"

module dat_timeout #(
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic       running_i, // High as long as we are waiting. Pulling low resets the counter
  input  logic [3:0] timeout_bits_i,

  output logic       timeout_o
);
  // maximum timeout is 2**27
  logic [27:0] timeout_counter_q, timeout_counter_d;
  `FF (timeout_counter_q, timeout_counter_d, 0, clk_i, rst_ni);
  
  always_comb begin
    timeout_counter_d = timeout_counter_q;
    // reset on low running_i
    if (!running_i) begin
      timeout_counter_d = '0;
    end
    if (!timeout_o) begin
      timeout_counter_d = timeout_counter_q + 1;
    end
  end
  assign timeout_o = (timeout_counter_q >= (1 << (timeout_bits_i + 13)));
endmodule
