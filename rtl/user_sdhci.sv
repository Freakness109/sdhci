// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "register_interface/typedef.svh"

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
  `REG_BUS_TYPEDEF_ALL(
    reg,
    logic [ObiCfg.AddrWidth-1:0],
    logic [ObiCfg.DataWidth-1:0],
    logic [ObiCfg.AddrWidth/8-1:0]
  )
  reg_req_t reg_req;
  reg_rsp_t reg_rsp;

  obi_to_reg #(
    .DATA_WIDTH (ObiCfg.DataWidth),
    .ID_WIDTH   (ObiCfg.IdWidth),

    .obi_req_t (obi_req_t),
    .obi_rsp_t (obi_rsp_t),
    .reg_req_t (reg_req_t),
    .reg_rsp_t (reg_rsp_t)
  ) i_obi_to_reg (
    .clk_i,
    .rst_ni,

    .obi_req_i (obi_req_i),
    .obi_rsp_o (obi_rsp_o),
    .reg_req_o (reg_req),
    .reg_rsp_i (reg_rsp)
  );


// Actuall SDHCI logic
  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw;
  sdhci_reg_pkg::sdhci_hw2reg_t hw2reg;
  
  sram_shift_reg i_shift (
    .clk_i,
    .rst_ni,

    .req_i (reg2hw.buffer_data_port.re | reg2hw.buffer_data_port.qe),
    .we_i  (reg2hw.buffer_data_port.qe),

    .read_data_o  (hw2reg.buffer_data_port.d),
    .write_data_i (reg2hw.buffer_data_port.q),
    
    .full_o  (),
    .empty_o ()
  );

  
  sdhci_reg_top #(
    .AW        (ObiCfg.AddrWidth),

    .reg_req_t (reg_req_t),
    .reg_rsp_t (reg_rsp_t)
  ) i_regs (
    .clk_i,
    .rst_ni,
    .reg_req_i (reg_req),
    .reg_rsp_o (reg_rsp),
    .reg2hw,
    .hw2reg,
    .devmode_i ('b1)
  );

  always_comb begin
    hw2reg.present_state.command_inhibit_cmd.d = '0;
    hw2reg.present_state.command_inhibit_cmd.de = '0;

    if (reg2hw.command.command_index.qe == '1) begin
      hw2reg.present_state.command_inhibit_cmd.d = '1;
      hw2reg.present_state.command_inhibit_cmd.de = '1;
    end
  end
endmodule
