`include "common_cells/registers.svh"

module crc16_read (
  input   logic   clk_i,
  input   logic   sd_clk_en_i,
  input   logic   rst_ni,

  input   logic   start_i,

  input   logic   dat_ser_i,
  output  logic   [15:0]  crc16_o
);
  //data path//////////////////////////////////////////////////////////////////////////////
  logic [4:0] lower_5_d,  lower_5_q;
  logic [6:0] middle_7_d, middle_7_q;
  logic [3:0] upper_4_d,  upper_4_q;
  logic int_rst_n, dat_i_xor_out;

  always_comb begin : crc_data_path
    lower_5_d   = lower_5_q;
    middle_7_d  = middle_7_q;
    upper_4_d   = upper_4_q;

    crc16_o [15:12] = upper_4_q;
    crc16_o [11:5]  = middle_7_q;
    crc16_o [4:0]   = lower_5_q;

    dat_i_xor_out     = (dat_ser_i ^ upper_4_q[3]);

    if (sd_clk_en_i) begin
      lower_5_d [4:1]   = lower_5_q [3:0];
      lower_5_d [0]     = dat_i_xor_out;
      middle_7_d  [6:1] = middle_7_q  [5:0];
      middle_7_d  [0]   = (lower_5_q[4] ^ dat_i_xor_out);
      upper_4_d [3:1]   = upper_4_q [2:0];
      upper_4_d [0]     = (middle_7_q[6] ^ dat_i_xor_out);
    end
  end

  logic rst_n;
  assign  rst_n = (rst_ni & ~start_i);

  `FF (lower_5_q, lower_5_d, 5'b0, clk_i, rst_n);
  `FF (middle_7_q, middle_7_d, 7'b0, clk_i, rst_n);
  `FF (upper_4_q, upper_4_d, 4'b0, clk_i, rst_n);
endmodule
