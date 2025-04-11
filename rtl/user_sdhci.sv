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

  logic software_reset_all_q, software_reset_all_d;
  `FF(software_reset_all_q, software_reset_all_d, '0, clk_i, rst_ni);
  assign software_reset_all_d = reg2hw.software_reset.software_reset_for_all.q;
  assign sd_rst_n = rst_ni && !software_reset_all_q;

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
  `FF(cmd_start_q, cmd_start_d, '0, sd_clk)

  logic cmd_argument, cmd_number, cmd_done;
  cmd_write i_cmd_write (
    .sd_freq_clk_i (sd_clk),
    .rst_ni (sd_rst_n),
    .cmd_o    (cmd_write),
    .cmd_en_o (cmd_write_en),

    .start_tx_i     (cmd_start_q),
    .cmd_argument_i (reg2hw.argument.q),
    .cmd_nr_i       (reg2hw.command.command_index.q),

    .tx_done_o (cmd_done)
  );

  logic rsp_start_q, rsp_start_d;
  `FF(rsp_start_q, rsp_start_d, '0, sd_clk)

  logic rsp_valid, rsp_end_bit_err, rsp_crc_correct;
  logic [119:0] rsp;
  rsp_read i_rsp_read (
    .sd_clk_i (sd_clk),
    .rst_ni (sd_rst_n),
    .cmd_i (cmd_read),

    .long_rsp_i (reg2hw.command.response_type_select == 2'b01),
    .start_listening_i (rsp_start_q),
    
    .rsp_valid_o   (rsp_valid),
    .end_bit_err_o (rsp_end_bit_err),
    .rsp_o         (rsp),
    .crc_corr_o    (rsp_crc_correct)

  );

  typedef enum logic [2:0] {
    READY,
    CMD_STARTING,
    CMD_STARTED,
    RSP_STARTING,
    RSP_STARTED,
    DONE
  } sdhc_state_e;
  sdhc_state_e sdhc_state_q, sdhc_state_d;
  `FF(sdhc_state_q, sdhc_state_d, READY);

  always_comb begin
    sdhc_state_d = sdhc_state_q;

    unique case (sdhc_state_q)
      READY:        if (reg2hw.command.command_index.qe) sdhc_state_d = CMD_STARTING;
      CMD_STARTING: if (!cmd_done) sdhc_state_d = CMD_STARTED;
      CMD_STARTED:  if (cmd_done) sdhc_state_d = reg2hw.command.response_type_select == 2'b00 ? DONE : RSP_STARTING;
      RSP_STARTING: if (rsp_start_q) sdhc_state_d = RSP_STARTED;
      RSP_STARTED:  if (rsp_valid) sdhc_state_d = DONE;
      DONE:         sdhc_state_d = READY;
      default:      sdhc_state_d = READY;
    endcase
  end

  always_comb begin
    cmd_start_d = '0;
    rsp_start_d = '0;
    hw2reg.present_state.command_inhibit_cmd.de = '0;
    hw2reg.present_state.command_inhibit_cmd.d = '0;
    hw2reg.response0.de = '0;
    hw2reg.response0.d = '0;
    hw2reg.response1.de = '0;
    hw2reg.response1.d = '0;
    hw2reg.response2.de = '0;
    hw2reg.response2.d = '0;
    hw2reg.response3.de = '0;
    hw2reg.response3.d = '0;
    hw2reg.error_interrupt_status.command_end_bit_error.de = '0;
    hw2reg.error_interrupt_status.command_end_bit_error.d = '1;
    hw2reg.error_interrupt_status.command_crc_error.de = '0;
    hw2reg.error_interrupt_status.command_crc_error.d = '1;
    hw2reg.error_interrupt_status.command_index_error.de = '0;
    hw2reg.error_interrupt_status.command_index_error.d = '1;

    unique case (sdhc_state_d)
      CMD_STARTING: begin
        cmd_start_d = '1;
        hw2reg.present_state.command_inhibit_cmd.de = '1;
        hw2reg.present_state.command_inhibit_cmd.d = '1;
      end
      RSP_STARTING: rsp_start_d = '1;
      DONE: begin
        if (reg2hw.command.response_type_select != 2'b00) begin
          if (rsp_end_bit_err) begin
            hw2reg.error_interrupt_status.command_end_bit_error.de = '1;
          end
          if (reg2hw.command.command_crc_check_enable.q && !rsp_crc_correct) begin
            hw2reg.error_interrupt_status.command_crc_error.de = '1;
          end
          if (reg2hw.command.command_index_check_enable.q && rsp[45:40] != reg2hw.command.command_index.q) begin
            hw2reg.error_interrupt_status.command_index_error.de = '1;
          end

          if (reg2hw.command.response_type_select != 2'b01) begin
            hw2reg.response0.de = '1;
            hw2reg.response0.d = rsp[31:0];
          end else begin
            hw2reg.response0.de = '1;
            hw2reg.response0.d = rsp[31:0];
            hw2reg.response1.de = '1;
            hw2reg.response1.d = rsp[63:32];
            hw2reg.response2.de = '1;
            hw2reg.response2.d = rsp[95:64];
            hw2reg.response3.de = '1;
            hw2reg.response3.d = { reg2hw.response3.q[31:24], rsp[119:96] };
          end
        end

        hw2reg.present_state.command_inhibit_cmd.de = '1;
        hw2reg.present_state.command_inhibit_cmd.d = '0;
      end
      default: ;
    endcase
  end
endmodule
