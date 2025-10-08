// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "defines.svh"
`define CMD_RESET_ON_TIMEOUT  //reset command when response times out. Not to spec, but helps with driver.

module user_sdhci #(
  parameter obi_pkg::obi_cfg_t ObiCfg      = obi_pkg::ObiDefaultConfig,
  parameter type               obi_req_t   = logic,
  parameter type               obi_rsp_t   = logic,
  
  //sw handles clock division. However, largest base freq. accepted is 63MHz!
  //-> internal clock predivider to get below 63MHz
  //only power of 2 dividers allowed :(
  //input log2 of divider i.e div by 4 ->  ClkPreDivLog = 2
  parameter int unsigned       ClkPreDivLog   = 0
  //also change base_clock_frequency_for_sd_clock resval in reg/sdhci_regs.hjson and regenerate registers
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o,

  output  logic sd_clk_o,

  input  logic sd_cmd_i,
  output logic sd_cmd_o,
  output logic sd_cmd_en_o,

  input  logic [3:0] sd_dat_i,
  output logic [3:0] sd_dat_o,
  output logic       sd_dat_en_o,

  output logic interrupt_o
  
);
  logic sd_rst_n, sd_rst_cmd_n, sd_rst_dat_n;
  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw, reg2hw_orig;
  sdhci_reg_pkg::sdhci_hw2reg_t hw2reg;

  //Soft Reset Logic/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  logic software_reset_all_q, software_reset_all_d, software_reset_cmd_q, software_reset_cmd_d, software_reset_dat_q, software_reset_dat_d;
  
  assign software_reset_all_d = reg2hw.software_reset.software_reset_for_all.q;
  `FF(software_reset_all_q, software_reset_all_d, '0, clk_i, rst_ni);
  
  assign software_reset_cmd_d = reg2hw.software_reset.software_reset_for_cmd_line.q;  //comand circuit soft reset
  `FF(software_reset_cmd_q, software_reset_cmd_d, '1, clk_i, rst_ni);

  assign software_reset_dat_d = reg2hw.software_reset.software_reset_for_dat_line.q;  //dat circuit soft reset
  `FF(software_reset_dat_q, software_reset_dat_d, '1, clk_i, rst_ni);

  assign sd_rst_n = rst_ni && !software_reset_all_q;
  assign sd_rst_cmd_n = sd_rst_n && !software_reset_cmd_q;
  assign sd_rst_dat_n = sd_rst_n && !software_reset_dat_q;
  
  always_comb begin : reset_reset_bits
    hw2reg.software_reset.software_reset_for_dat_line.d   = 1'b0;
    hw2reg.software_reset.software_reset_for_dat_line.de  = 1'b0;
    hw2reg.software_reset.software_reset_for_cmd_line.d   = 1'b0;
    hw2reg.software_reset.software_reset_for_cmd_line.de  = 1'b0;

    if(software_reset_dat_q) hw2reg.software_reset.software_reset_for_dat_line.de = 1'b1;
    if(software_reset_cmd_q) hw2reg.software_reset.software_reset_for_cmd_line.de = 1'b1;

    `ifdef CMD_RESET_ON_TIMEOUT
      if(reg2hw.error_interrupt_status.command_timeout_error.q) begin //evtl noch error status resetten?
        hw2reg.software_reset.software_reset_for_cmd_line.d = 1'b1;
        hw2reg.software_reset.software_reset_for_cmd_line.de = 1'b1;
      end
    `endif
  end

  ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  sdhci_reg_obi #(
    .ObiCfg    (ObiCfg),
    .obi_req_t (obi_req_t),
    .obi_rsp_t (obi_rsp_t)
  ) i_regs (
    .clk_i,
    .rst_ni (sd_rst_n),
    .obi_req_i,
    .obi_rsp_o,
    .reg2hw (reg2hw_orig),
    .hw2reg
  );

  logic  sd_cmd_dat_busy;

  `writable_reg_t([15:0]) block_count_hw;


  sdhci_reg_logic i_sdhci_reg_logic (
    .clk_i,
    .rst_ni     (sd_rst_n),
    .rst_cmd_ni (sd_rst_cmd_n),
    .rst_dat_ni (sd_rst_dat_n),

    .reg2hw_i          (reg2hw_orig),
    .hw2reg_i          (hw2reg),
    .reg2hw_modified_o (reg2hw),

    .sd_cmd_dat_busy_i (sd_cmd_dat_busy),

    .error_interrupt_o  (hw2reg.normal_interrupt_status.error_interrupt),
    .auto_cmd12_error_o (hw2reg.error_interrupt_status.auto_cmd12_error),

    .buffer_read_ready_o  (hw2reg.normal_interrupt_status.buffer_read_ready),
    .buffer_write_ready_o (hw2reg.normal_interrupt_status.buffer_write_ready),

    .dat_line_active_o     (hw2reg.present_state.dat_line_active),
    .command_inhibit_dat_o (hw2reg.present_state.command_inhibit_dat),

    .transfer_complete_o (hw2reg.normal_interrupt_status.transfer_complete),
    .command_complete_o  (hw2reg.normal_interrupt_status.command_complete),

    .card_removal_o    (hw2reg.normal_interrupt_status.card_removal),
    .card_insertion_o  (hw2reg.normal_interrupt_status.card_insertion),


    .block_count_o       (hw2reg.block_count),
    .block_count_hw_i    (block_count_hw),
    .block_size_reg_o    (hw2reg.block_size),
    .transfer_mode_reg_o (hw2reg.transfer_mode),

    .interrupt_signal_for_each_slot_o (hw2reg.slot_interrupt_status.interrupt_signal_for_each_slot.d),
    .interrupt_o
  );

  logic pause_sd_clk, sd_clk_en_p, sd_clk_en_n, div_1;
  sd_clk_generator #(
    .ClkPreDivLog (ClkPreDivLog)
  ) i_sd_clk_generator (
    .clk_i,
    .rst_ni (sd_rst_n),
    .reg2hw_i (reg2hw),

    .pause_sd_clk_i  (pause_sd_clk),
    .sd_clk_o        (sd_clk_o),
    .clk_en_p_o      (sd_clk_en_p),
    .clk_en_n_o      (sd_clk_en_n),
    .div_1_o         (div_1),
    .sd_clk_stable_o (hw2reg.clock_control.internal_clock_stable)
  );

  assign hw2reg.present_state.dat_line_signal_level = '{ de: '1, d: sd_dat_i };
  assign hw2reg.present_state.cmd_line_signal_level = '{ de: '1, d: sd_cmd_i };

  assign hw2reg.present_state.write_protect_switch_pin_level = '{ de: '1, d: '1 };
  assign hw2reg.present_state.card_inserted                  = '{ de: '1, d: '1 }; // TODO ?
  assign hw2reg.present_state.card_state_stable              = '{ de: '1, d: '1 };
  assign hw2reg.present_state.card_detect_pin_level          = '{ de: '1, d: '1 }; // TODO ?


  logic sd_cmd_done, sd_rsp_done, request_cmd12;

  cmd_wrap  i_cmd_wrap (
    .clk_i           (clk_i),
    .rst_ni          (sd_rst_cmd_n),
    .clk_en_p_i      (sd_clk_en_p),
    .clk_en_n_i      (sd_clk_en_n),
    .div_1_i         (div_1),
    .sd_bus_cmd_i    (sd_cmd_i),
    .sd_bus_cmd_o    (sd_cmd_o),
    .sd_bus_cmd_en_o (sd_cmd_en_o),
    .reg2hw          (reg2hw),

    .dat0_i          (sd_dat_i[0]),
    .request_cmd12_i (request_cmd12),

    .sd_cmd_done_o     (sd_cmd_done),
    .sd_rsp_done_o     (sd_rsp_done),
    .sd_cmd_dat_busy_o (sd_cmd_dat_busy),

    .response0_d_o  (hw2reg.response0.d),
    .response1_d_o  (hw2reg.response1.d),
    .response2_d_o  (hw2reg.response2.d),
    .response3_d_o  (hw2reg.response3.d),
    .response0_de_o (hw2reg.response0.de),
    .response1_de_o (hw2reg.response1.de),
    .response2_de_o (hw2reg.response2.de),
    .response3_de_o (hw2reg.response3.de),
    .command_inhibit_cmd_o    (hw2reg.present_state.command_inhibit_cmd),
    .command_end_bit_error_o  (hw2reg.error_interrupt_status.command_end_bit_error),
    .command_crc_error_o      (hw2reg.error_interrupt_status.command_crc_error),
    .command_index_error_o    (hw2reg.error_interrupt_status.command_index_error),
    .command_timeout_error_o  (hw2reg.error_interrupt_status.command_timeout_error),
    .auto_cmd12_errors_o      (hw2reg.auto_cmd12_error_status)
  );


  dat_wrap i_dat_wrap (
    .clk_i,
    .sd_clk_en_p_i  (sd_clk_en_p),
    .sd_clk_en_n_i  (sd_clk_en_n),
    .div_1_i        (div_1),
    .rst_ni      (sd_rst_dat_n),

    .dat_i    (sd_dat_i),
    .dat_en_o (sd_dat_en_o),
    .dat_o    (sd_dat_o),

    .sd_cmd_done_i   (sd_cmd_done),
    .sd_rsp_done_i   (sd_rsp_done),

    .request_cmd12_o (request_cmd12),
    .pause_sd_clk_o  (pause_sd_clk),

    .reg2hw_i (reg2hw),

    .data_crc_error_o        (hw2reg.error_interrupt_status.data_crc_error),
    .data_end_bit_error_o    (hw2reg.error_interrupt_status.data_end_bit_error),
    .data_timeout_error_o    (hw2reg.error_interrupt_status.data_timeout_error),

    .buffer_data_port_d_o    (hw2reg.buffer_data_port.d),
    .buffer_read_enable_o    (hw2reg.present_state.buffer_read_enable),
    .buffer_write_enable_o   (hw2reg.present_state.buffer_write_enable),

    .read_transfer_active_o  (hw2reg.present_state.read_transfer_active),
    .write_transfer_active_o (hw2reg.present_state.write_transfer_active),

    .block_count_o           (block_count_hw)
  );
  
endmodule
