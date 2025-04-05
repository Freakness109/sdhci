// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

module user_sdhci #(
  parameter obi_pkg::obi_cfg_t ObiCfg      = obi_pkg::ObiDefaultConfig,
  parameter type               obi_req_t   = logic,
  parameter type               obi_rsp_t   = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o, 

  output logic interrupt_o
);
  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw;
  sdhci_reg_pkg::sdhci_hw2reg_t hw2reg;
  sdhci_reg_obi #(
    .ObiCfg    (ObiCfg),
    .obi_req_t (obi_req_t),
    .obi_rsp_t (obi_rsp_t)
  ) i_regs (
    .clk_i,
    .rst_ni,
    .obi_req_i,
    .obi_rsp_o,
    .reg2hw,
    .hw2reg
  );

  sdhci_reg_logic i_sdhci_reg_logic (
    .clk_i,
    .rst_ni,
    .reg2hw_i (reg2hw),
    .hw2reg_i (hw2reg),
    
    .error_interrupt_o  (hw2reg.normal_interrupt_status.error_interrupt),
    .auto_cmd12_error_o (hw2reg.error_interrupt_status.auto_cmd12_error),

    .buffer_read_ready_o  (hw2reg.normal_interrupt_status.buffer_read_ready),
    .buffer_write_ready_o (hw2reg.normal_interrupt_status.buffer_write_ready),
    
    .interrupt_o
  );

  logic sd_clk;
  logic div_ready_q, div_ready_d;
  `FF(div_ready_q, div_ready_d, '0, clk_i, rst_ni);

  logic div_valid_q, div_valid_d;
  `FF(div_valid_q, div_valid_d, '0, clk_i, rst_ni);
  assign div_valid_d = reg2hw.clock_control.sdclk_frequency_select.qe ? '1 : div_ready_q ? '0 : div_valid_q;

  clk_int_div # (
    // MAX 256
    .DIV_VALUE_WIDTH (9)
  ) i_sd_clk_div (
    .clk_i,
    .rst_ni,
    .en_i           ('1),
    .test_mode_en_i ('0),

    .div_i        (reg2hw.clock_control.sdclk_frequency_select.q << 1),
    .div_valid_i  (div_valid_d),
    .div_ready_o  (div_ready_d),

    .clk_o        (sd_clk),    
    .cycl_count_o ()
  );
  
  logic read_reg_full, read_reg_empty;
  always_comb begin
    hw2reg.present_state.buffer_read_enable.d = '0;
    hw2reg.present_state.buffer_read_enable.de = '0;
    
    if (reg2hw.present_state.buffer_read_enable.q) begin
      if (read_reg_empty) begin
        hw2reg.present_state.buffer_read_enable.d = '0;
        hw2reg.present_state.buffer_read_enable.de = '1;
      end
    end else begin
      if (read_reg_full) begin
        hw2reg.present_state.buffer_read_enable.d = '1;
        hw2reg.present_state.buffer_read_enable.de = '1;
      end
    end
  end
  
  logic push_read_reg;
  logic [31:0] push_read_reg_data;

  sram_shift_reg #(
    .NumWords (4)
  ) i_shift_read (
    .clk_i,
    .rst_ni,

    .pop_front_i  (reg2hw.buffer_data_port.re),
    .front_data_o (hw2reg.buffer_data_port.d),

    .push_back_i  (push_read_reg),
    .back_data_i  (push_read_reg_data),
    
    .full_o  (read_reg_full),
    .empty_o (read_reg_empty)
  );

  // initial begin
  //   #3ms;
  //   @(posedge clk_i)
  //   push_read_reg = '1;
  //   push_read_reg_data = 32'hDEADBEEF;
  //   @(posedge clk_i)
  //   push_read_reg_data = 32'hC007100;
  //   @(posedge clk_i)
  //   push_read_reg_data = 32'hC007101;
  //   @(posedge clk_i)
  //   push_read_reg_data = 32'hC007102;
  //   @(posedge clk_i)
  //   push_read_reg = '0;
  //   $display("Pusing last");
  // end

  logic write_reg_full, write_reg_empty;
  always_comb begin
    hw2reg.present_state.buffer_write_enable.d = '0;
    hw2reg.present_state.buffer_write_enable.de = '0;
    
    if (reg2hw.present_state.buffer_write_enable.q) begin
      if (write_reg_full) begin
        hw2reg.present_state.buffer_write_enable.d = '0;
        hw2reg.present_state.buffer_write_enable.de = '1;
      end
    end else begin
      if (write_reg_empty) begin
        hw2reg.present_state.buffer_write_enable.d = '1;
        hw2reg.present_state.buffer_write_enable.de = '1;
      end
    end
  end
  
  sram_shift_reg i_shift_write (
    .clk_i,
    .rst_ni,

    .pop_front_i  (),
    .front_data_o (),

    .push_back_i  (reg2hw.buffer_data_port.qe),
    .back_data_i  (reg2hw.buffer_data_port.q),
    
    .full_o  (),
    .empty_o ()
  );

endmodule
