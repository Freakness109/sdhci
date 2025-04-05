`include "register_interface/typedef.svh"

module sdhci_reg_obi #(
  parameter obi_pkg::obi_cfg_t ObiCfg      = obi_pkg::ObiDefaultConfig,
  parameter type               obi_req_t   = logic,
  parameter type               obi_rsp_t   = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o, 

  output sdhci_reg_pkg::sdhci_reg2hw_t reg2hw,
  input  sdhci_reg_pkg::sdhci_hw2reg_t hw2reg
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
endmodule