`include "common_cells/registers.svh"
`include "defines.svh"

module sd_clk_generator (
  input  logic clk_i,
  input  logic rst_ni,

  input  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,

  input  logic pause_sd_clk_i,
  output logic sd_clk_o,

  output `writable_reg_t() sd_clk_stable_o
);
  localparam int DivWidth = 9;

  logic div_ready_q, div_ready_d;
  `FF(div_ready_q, div_ready_d, '0, clk_i, rst_ni);

  logic div_valid_q, div_valid_d;
  `FF(div_valid_q, div_valid_d, '0, clk_i, rst_ni);

  logic [DivWidth-1:0] div_q, div_d;
  `FF(div_q, div_d, '0, clk_i, rst_ni);

  logic [DivWidth-1:0] div_reg;
  assign div_reg = reg2hw_i.clock_control.sdclk_frequency_select.q << 1;

  always_comb begin
    div_valid_d = div_valid_q;
    div_d = div_q;

    sd_clk_stable_o = '{ de: '0, d: 'X };

    if (div_valid_q) begin
      if (div_ready_q) begin
        div_valid_d = '0;
        sd_clk_stable_o = '{ de: '1, d: '1 };
      end
    end else if (div_q != div_reg) begin
      div_d = div_reg;
      div_valid_d = '1;
      sd_clk_stable_o = '{ de: '1, d: '0 };
    end
  end

  clk_int_div # (
    // MAX 256
    .DIV_VALUE_WIDTH (DivWidth)
  ) i_sd_clk_div (
    .clk_i,
    .rst_ni,
    .en_i           (reg2hw_i.clock_control.sd_clock_enable.q && !pause_sd_clk_i),
    .test_mode_en_i ('0),

    .div_i        (div_d),
    .div_valid_i  (div_valid_q),
    .div_ready_o  (div_ready_d),

    .clk_o        (sd_clk_o),
    .cycl_count_o ()
  );
endmodule
