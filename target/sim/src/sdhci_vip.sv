// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@student.ethz.ch>
// - Micha Wehrli <miwehrli@student.ethz.ch>

module sdhci_vip #(
  parameter type obi_req_t = logic,
  parameter type obi_rsp_t = logic,

  parameter int unsigned RstCycles = 5,

  parameter time ClkPeriod = 20ns,
  parameter time TA = 5ns,
  parameter time TT = 15ns
)(
  output logic clk_o,
  output logic rst_no,

  output obi_req_t obi_req_o,
  input  obi_rsp_t obi_rsp_i,

  input  logic sd_clk_i,
  output logic sd_cd_no,

  output logic sd_cmd_o,
  input  logic sd_cmd_i,
  input  logic sd_cmd_en_i,

  output logic [3:0] sd_dat_o,
  input  logic [3:0] sd_dat_i,
  input  logic       sd_dat_en_i,

  input  logic interrupt_i
);
  clk_rst_gen #(
    .ClkPeriod    ( ClkPeriod ),
    .RstClkCycles ( RstCycles )
  ) i_clk_rst_sys (
    .clk_o  (clk_o ),
    .rst_no (rst_no)
  );

  sdhci_obi_driver #(
    .obi_req_t(obi_req_t),
    .obi_rsp_t(obi_rsp_t),
    .TA(TA),
    .TT(TT)
  ) obi (
    .clk_i    (clk_o),
    .rst_ni   (rst_no),
    .obi_req_o(obi_req_o),
    .obi_rsp_i(obi_rsp_i)
  );

  task automatic wait_for_reset();
    @(posedge rst_no);
    @(posedge clk_o);
  endtask

  task automatic wait_for_clk();
    @(posedge clk_o);
  endtask

  task automatic wait_for_sdclk();
    @(posedge sd_clk_i);
  endtask

  initial begin
    sd_cd_no  = 1'b1;
    sd_cmd_o  = 1'b1;
    sd_dat_o  = '1;
  end

  task automatic apply_logic (
    logic value,
    output logic to_write
  );
    @(posedge sd_clk_i);
    #(TA);
    to_write = value;
  endtask

  task automatic test_delay();
    #(TT);
  endtask

  task automatic is_cmd_held(output logic cmd_en);
    cmd_en = sd_cmd_en_i;
  endtask

  task automatic is_dat_held(output logic dat_en);
    dat_en = sd_dat_en_i;
  endtask

  task automatic send_response_48 (
    input logic [5:0] index,
    input logic [6:0] crc,
    input logic [31:0] card_status = '0,
    input int busy_cycles = -1,
    input logic end_bit = 1'b1
  );
    // start bit
    apply_logic(1'b0, sd_cmd_o);

    if (busy_cycles >= 0) begin
      // signal busy
      sd_dat_o[0] = 1'b0;
    end

    // transmission bit
    apply_logic(1'b0, sd_cmd_o);

    for (int i = 0; i < 6; i += 1) begin
      apply_logic(index[5-i], sd_cmd_o);
    end

    for (int i = 0; i < 32; i += 1) begin
      apply_logic(card_status[31-i], sd_cmd_o);
    end

    for (int i = 0; i < 7; i += 1) begin
      apply_logic(crc[6-i], sd_cmd_o);
    end

    apply_logic(end_bit, sd_cmd_o);
    
    if (busy_cycles == 0) begin
      sd_dat_o[0] = 1'b1;
    end else if (busy_cycles > 0) begin
      repeat(busy_cycles) @(posedge sd_clk_i);
      #(TA);
      sd_dat_o[0] = 1'b1;
    end
  endtask


endmodule
