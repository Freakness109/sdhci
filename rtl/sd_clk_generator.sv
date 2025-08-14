// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Anton Buchner <abuchner@student.ethz.ch>
// - Micha Wehrli <miwehrli@student.ethz.ch>

`include "common_cells/registers.svh"
`include "defines.svh"

module sd_clk_generator #(
  parameter int unsigned ClkPreDivLog = 0
)(
  input  logic clk_i,
  input  logic rst_ni,

  input  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,

  input  logic pause_sd_clk_i,
  output logic sd_clk_o,

  output logic clk_en_p_o, //high when next rising clk edge coincides with rising sd_clk edge
  output logic clk_en_n_o, //high when next rising clk edge coincides with falling sd_clk edge, always high for div by 1

  output logic div_1_o,   //high if source clock isn't divided, needed for negative edge triggering

  output `writable_reg_t() sd_clk_stable_o
);
  localparam int unsigned MsbConsidered = (ClkPreDivLog != 0) ? (ClkPreDivLog - 1) : 0;
  //check if all bits from [ClkPreDivLog-1:0] are one
  function logic lsbones(input logic[ClkPreDivLog+7:0] div);
    if(ClkPreDivLog == 0) return '1;
    else return (div[MsbConsidered:0] == '1);
  endfunction

  logic[7:0] div_d, div_q;
  assign div_d = (!reg2hw_i.clock_control.sd_clock_enable.q) ? reg2hw_i.clock_control.sdclk_frequency_select.q : div_q;
  `FF(div_q, div_d, 8'b0, clk_i, rst_ni);

  //counter
  logic[ClkPreDivLog+7 :0]  cnt_d, cnt_q;
  assign cnt_d = cnt_q + 1;
  `FF(cnt_q, cnt_d, '0, clk_i, rst_ni);

  logic clk_en_p_d, clk_en_p_q;
  `FF(clk_en_p_q, clk_en_p_d, '0, clk_i, rst_ni);

  logic clk_en_n_d, clk_en_n_q;
  `FF(clk_en_n_q, clk_en_n_d, '0, clk_i, rst_ni);

  logic [ClkPreDivLog+7:0] bitmask;
  assign bitmask = (1 << ClkPreDivLog) >> 1;

  //clk source multiplexer
  logic clk_div_d, clk_div_q, clk_o_ungated;
  always_comb begin : clk_div_mux
    clk_div_d   = 1'b1;
    clk_en_p_d  = clk_en_p_q;
    clk_en_n_d  = clk_en_n_q;

    unique case (div_q)
      8'h00:  begin
        if (ClkPreDivLog != 0) begin 
          clk_div_d  = cnt_q[MsbConsidered];
          clk_en_p_d = lsbones(cnt_q ^ bitmask);
          clk_en_n_d = lsbones(cnt_q);
        end
      end
      8'h01:  begin 
        clk_div_d = cnt_q[ClkPreDivLog];
        clk_en_p_d  = (!cnt_q[ClkPreDivLog]) && lsbones(cnt_q);
        clk_en_n_d  = cnt_q[ClkPreDivLog]    && lsbones(cnt_q);
      end
      8'h02:  begin
        clk_div_d = cnt_q[ClkPreDivLog+1];
        clk_en_p_d  = (cnt_q[ClkPreDivLog+1:ClkPreDivLog] == 2'b01) && lsbones(cnt_q);
        clk_en_n_d  = (cnt_q[ClkPreDivLog+1:ClkPreDivLog] == 2'b11) && lsbones(cnt_q);
      end
      8'h04:  begin
        clk_div_d = cnt_q[ClkPreDivLog+2];
        clk_en_p_d  = (cnt_q[ClkPreDivLog+2:ClkPreDivLog] == 3'b011) && lsbones(cnt_q);   
        clk_en_n_d  = (cnt_q[ClkPreDivLog+2:ClkPreDivLog] == 3'b111)  && lsbones(cnt_q);   
      end
      8'h08:  begin
        clk_div_d = cnt_q[ClkPreDivLog+3];    
        clk_en_p_d  = (cnt_q[ClkPreDivLog+3:ClkPreDivLog] == 4'b0111) && lsbones(cnt_q);
        clk_en_n_d  = (cnt_q[ClkPreDivLog+3:ClkPreDivLog] == 4'b1111)  && lsbones(cnt_q);
      end
      8'h10:  begin
        clk_div_d = cnt_q[ClkPreDivLog+4];
        clk_en_p_d  = (cnt_q[ClkPreDivLog+4:ClkPreDivLog] == 5'b01111) && lsbones(cnt_q);
        clk_en_n_d  = (cnt_q[ClkPreDivLog+4:ClkPreDivLog] == 5'b11111)  && lsbones(cnt_q);
      end
      8'h20:  begin
        clk_div_d = cnt_q[ClkPreDivLog+5];
        clk_en_p_d  = (cnt_q[ClkPreDivLog+5:ClkPreDivLog] == 6'b011111) && lsbones(cnt_q);
        clk_en_n_d  = (cnt_q[ClkPreDivLog+5:ClkPreDivLog] == 6'b111111)  && lsbones(cnt_q);
      end
      8'h40:  begin
        clk_div_d = cnt_q[ClkPreDivLog+6];
        clk_en_p_d  = (cnt_q[ClkPreDivLog+6:ClkPreDivLog] == 7'b0111111) && lsbones(cnt_q);
        clk_en_n_d  = (cnt_q[ClkPreDivLog+6:ClkPreDivLog] == 7'b1111111)  && lsbones(cnt_q);
      end
      8'h80:  begin
        clk_div_d = cnt_q[ClkPreDivLog+7];
        clk_en_p_d  = (cnt_q[ClkPreDivLog+7:ClkPreDivLog] == 8'b01111111) && lsbones(cnt_q);
        clk_en_n_d  = (cnt_q[ClkPreDivLog+7:ClkPreDivLog] == 8'b11111111)  && lsbones(cnt_q);
      end
      
      default: ;
    endcase
  end
  `FF(clk_div_q, clk_div_d, 1'b1, clk_i, rst_ni);
  
  assign clk_o_ungated = ((div_q == 8'h00) && (ClkPreDivLog == 0)) ?  clk_i : clk_div_q;
  assign clk_en_p_o    = ((div_q == 8'h00) && (ClkPreDivLog == 0)) ?  '1 : clk_en_p_q;
  assign clk_en_n_o    = ((div_q == 8'h00) && (ClkPreDivLog == 0)) ?  '1 : clk_en_n_q;

  assign sd_clk_o =  (reg2hw_i.clock_control.sd_clock_enable.q && !pause_sd_clk_i) ? clk_o_ungated : 1'b1;

  assign div_1_o = ((div_q == 8'h00) && (ClkPreDivLog == 0));
  assign sd_clk_stable_o = '{ de: '1, d: reg2hw_i.clock_control.internal_clock_enable.q};


endmodule
