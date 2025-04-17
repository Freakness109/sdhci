// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`define CMD_RESET_ON_TIMEOUT  //reset command when response times out. Not to spec, but helps with driver.

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
  logic sd_rst_n;
  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw;
  sdhci_reg_pkg::sdhci_hw2reg_t hw2reg;
  
  assign hw2reg.present_state.card_inserted.d = '1;
  assign hw2reg.present_state.card_inserted.de = '1;
  assign hw2reg.present_state.card_state_stable.d = '1;
  assign hw2reg.present_state.card_state_stable.de = '1;
  assign hw2reg.present_state.card_detect_pin_level.d = '1;
  assign hw2reg.present_state.card_detect_pin_level.de = '1;
  assign hw2reg.clock_control.internal_clock_stable.d = '1;
  assign hw2reg.clock_control.internal_clock_stable.de = '1;

  //Soft Reset Logic/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  logic software_reset_all_q, software_reset_all_d, software_reset_cmd_q, software_reset_cmd_d, software_reset_dat_q, software_reset_dat_d;
  
  assign software_reset_all_d = reg2hw.software_reset.software_reset_for_all.q;
  `FF(software_reset_all_q, software_reset_all_d, '0, clk_i, rst_ni);
  
  assign software_reset_cmd_d = rst_ni && !reg2hw.software_reset.software_reset_for_cmd_line.q;  //comand circuit soft reset
  `FF(software_reset_cmd_q, software_reset_cmd_d, '1, clk_i, rst_ni);

  assign software_reset_dat_d = rst_ni && !reg2hw.software_reset.software_reset_for_dat_line.q;  //dat circuit soft reset
  `FF(software_reset_dat_q, software_reset_dat_d, '1, clk_i, rst_ni);

  assign sd_rst_n = rst_ni && !software_reset_all_q;
  
  always_comb begin : reset_reset_bits
    hw2reg.software_reset.software_reset_for_all.d  = 1'b0;
    hw2reg.software_reset.software_reset_for_all.de = 1'b0;
    hw2reg.software_reset.software_reset_for_dat_line.d   = 1'b0;
    hw2reg.software_reset.software_reset_for_dat_line.de  = 1'b0;
    hw2reg.software_reset.software_reset_for_cmd_line.d   = 1'b0;
    hw2reg.software_reset.software_reset_for_cmd_line.de  = 1'b0;

    if(software_reset_all_q) hw2reg.software_reset.software_reset_for_all.de = 1'b1;
    if(!software_reset_dat_q) hw2reg.software_reset.software_reset_for_dat_line.de = 1'b1;
    if(!software_reset_cmd_q) hw2reg.software_reset.software_reset_for_cmd_line.de = 1'b1;

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
    .reg2hw,
    .hw2reg
  );

  sdhci_reg_logic i_sdhci_reg_logic (
    .clk_i,
    .rst_ni (sd_rst_n),
    .reg2hw_i (reg2hw),
    .hw2reg_i (hw2reg),
    
    .error_interrupt_o  (hw2reg.normal_interrupt_status.error_interrupt),
    .auto_cmd12_error_o (hw2reg.error_interrupt_status.auto_cmd12_error),

    .buffer_read_ready_o  (hw2reg.normal_interrupt_status.buffer_read_ready),
    .buffer_write_ready_o (hw2reg.normal_interrupt_status.buffer_write_ready),

    .transfer_complete_o (hw2reg.normal_interrupt_status.transfer_complete),
    .command_complete_o  (hw2reg.normal_interrupt_status.command_complete),
    
    .interrupt_o
  );
  
  logic sd_clk;
  sd_clk_generator i_sd_clk_generator (
    .clk_i,
    .rst_ni (sd_rst_n),
    .reg2hw_i (reg2hw),
  `ifdef VERILATOR
    .hw2reg_o (hw2reg),
  `endif
    
    .sd_clk_o (sd_clk)
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
    .NumWords (128)
  ) i_shift_read (
    .clk_i,
    .rst_ni (sd_rst_n),

    .pop_front_i  (reg2hw.buffer_data_port.re),
    .front_data_o (hw2reg.buffer_data_port.d),

    .push_back_i  (push_read_reg),
    .back_data_i  (push_read_reg_data),
    
    .full_o  (read_reg_full),
    .empty_o (read_reg_empty)
  );

// `ifdef VERILATOR
//   initial begin
//     #3ms;
//     @(negedge clk_i)
//     push_read_reg = '1;
//     push_read_reg_data = 32'hDEADBEEF;
//     @(negedge clk_i)
//     push_read_reg_data = 32'hC007100;
//     @(negedge clk_i)
//     push_read_reg_data = 32'hC007101;
//     @(negedge clk_i)
//     push_read_reg_data = 32'hC007102;
//     $display("Pushing last");
//     @(negedge clk_i)
//     push_read_reg = '0;
//   end
// `endif
// 

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
  
  sram_shift_reg #(
    .NumWords (128)
  ) i_shift_write (
    .clk_i,
    .rst_ni (sd_rst_n),

    .pop_front_i  (),
    .front_data_o (),

    .push_back_i  (reg2hw.buffer_data_port.qe),
    .back_data_i  (reg2hw.buffer_data_port.q),
    
    .full_o  (write_reg_full),
    .empty_o (write_reg_empty)
  );
  

  logic cmd_write;
  logic cmd_write_en, cmd_read;

  logic dat_write_en;
  logic [3:0] dat_write, dat_read;
  assign dat_write_en = '0;

  sd_card i_sd_card(
    .sd_clk_i (sd_clk),
    .cmd_en_i (cmd_write_en),
    .cmd_i    (cmd_write),
    .cmd_o    (cmd_read),
    .dat_en_i (dat_write_en),
    .dat_i    (dat_write),
    .dat_o    (dat_read)
  );
  
  logic cmd_start_q, cmd_start_d;
  `FF(cmd_start_q, cmd_start_d, '0, sd_clk);


  cmd_wrap  i_cmd_wrap (
    .clk_i (clk_i),
    .sd_clk_i (sd_clk),
    .rst_ni (software_reset_cmd_q),
    .sd_bus_cmd_i (cmd_read),
    .sd_bus_cmd_o (cmd_write),
    .sd_bus_cmd_en_o (cmd_write_en),
    .reg2hw (reg2hw),
    .busy_dat0_i ('0), //hook up to busy signal from dat_wrap
    .hw2reg_response0_d (hw2reg.response0.d),
    .hw2reg_response1_d (hw2reg.response1.d),
    .hw2reg_response2_d (hw2reg.response2.d),
    .hw2reg_response3_d (hw2reg.response3.d),
    .hw2reg_response0_de (hw2reg.response0.de),
    .hw2reg_response1_de (hw2reg.response1.de),
    .hw2reg_response2_de (hw2reg.response2.de),
    .hw2reg_response3_de (hw2reg.response3.de),
    .hw2reg_present_state_command_inhibit_cmd_d (hw2reg.present_state.command_inhibit_cmd.d),
    .hw2reg_present_state_command_inhibit_cmd_de (hw2reg.present_state.command_inhibit_cmd.de),
    .hw2reg_present_state_command_inhibit_dat_d (hw2reg.present_state.command_inhibit_dat.d),
    .hw2reg_present_state_command_inhibit_dat_de (hw2reg.present_state.command_inhibit_dat.de),
    .hw2reg_error_interrupt_status_command_end_bit_error_d (hw2reg.error_interrupt_status.command_end_bit_error.d),
    .hw2reg_error_interrupt_status_command_end_bit_error_de (hw2reg.error_interrupt_status.command_end_bit_error.de),
    .hw2reg_error_interrupt_status_command_crc_error_d (hw2reg.error_interrupt_status.command_crc_error.d),
    .hw2reg_error_interrupt_status_command_crc_error_de (hw2reg.error_interrupt_status.command_crc_error.de),
    .hw2reg_error_interrupt_status_command_index_error_d (hw2reg.error_interrupt_status.command_index_error.d),
    .hw2reg_error_interrupt_status_command_index_error_de (hw2reg.error_interrupt_status.command_index_error.de),
    .hw2reg_error_interrupt_status_command_timeout_error_d (hw2reg.error_interrupt_status.command_timeout_error.d),
    .hw2reg_error_interrupt_status_command_timeout_error_de (hw2reg.error_interrupt_status.command_timeout_error.de)
  );
  
endmodule
