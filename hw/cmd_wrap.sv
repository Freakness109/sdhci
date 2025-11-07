// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Anton Buchner <abuchner@student.ethz.ch>
// - Micha Wehrli <miwehrli@student.ethz.ch>
// - Axel Vanoni <axvanoni@student.ethz.ch>

import sdhci_reg_pkg::*;
`include "common_cells/registers.svh"
`include "defines.svh"

module cmd_wrap (
  input   logic clk_i,
  input   logic rst_ni,
  input   logic clk_en_p_i, // high before next sd_clk posedge
  input   logic clk_en_n_i, // high before next sd_clk negedge
  input   logic div_1_i,

  input   logic sd_bus_cmd_i,
  output  logic sd_bus_cmd_o,
  output  logic sd_bus_cmd_en_o,

  input   sdhci_reg2hw_t reg2hw,

  input   logic dat0_i,     // busy signal is on dat0 line
  input   logic request_cmd12_i,

  output  logic sd_cmd_done_o,
  output  logic sd_rsp_done_o,
  output  logic sd_cmd_dat_busy_o,

  output  logic [31:0] response0_d_o,
  output  logic [31:0] response1_d_o,
  output  logic [31:0] response2_d_o,
  output  logic [31:0] response3_d_o,
  output  logic response0_de_o,
  output  logic response1_de_o,
  output  logic response2_de_o,
  output  logic response3_de_o,

  output  `writable_reg_t() command_inhibit_cmd_o,
  output  `writable_reg_t() command_end_bit_error_o,
  output  `writable_reg_t() command_crc_error_o,
  output  `writable_reg_t() command_index_error_o,
  output  `writable_reg_t() command_timeout_error_o,

  output  sdhci_reg_pkg::sdhci_hw2reg_auto_cmd12_error_status_reg_t auto_cmd12_errors_o
);
  //////////////////////
  // State Transition //
  //////////////////////

  typedef enum logic [2:0] {
    READY,         // waiting for commands
    WRITE_CMD,     // writing the command to the CMD line
    BUS_SWITCH,    // waiting 2 clock cycles before listening for Response
    READ_RSP,      // waiting on response
    READ_RSP_BUSY, // read response with busy signalling on dat0 line
    RSP_RECEIVED   // wait for N_RC=8 clock cycles before allowing next command
  } cmd_seq_state_e;

  logic [5:0] timing_counter;
  logic timing_counter_en, timing_counter_clr;

  // Electrical spec, 7.13.5; units are number of cycles
  logic [5:0] N_CR_MIN = 2;  // minimum time between command (SDHC) and response (card)
  logic [5:0] N_CR_MAX = 64; // maximum time between command and response
  logic [5:0] N_ID     = 5;  // time between identification command and response
  logic [5:0] N_RC     = 8;  // minimum time between response and next command
  logic [5:0] N_CC     = 8;  // minimum time between consecutive commands

  typedef enum logic [1:0] {
    NO_RESPONSE                  = 2'b00,
    REPONSE_LENGTH_136           = 2'b01,
    REPONSE_LENGTH_48            = 2'b10,
    REPONSE_LENGTH_48_CHECK_BUSY = 2'b01,
  } response_type_e;

  // high if transmission should start next sd_clk posedge
  logic start_tx_q, start_tx_d;
  `FF(start_tx_q, start_tx_d, 1'b0, clk_i, rst_ni);

  // high if we are running AUTO CMD12
  logic running_cmd12_q, running_cmd12_d;
  `FF(running_cmd12_q, running_cmd12_d, '0, clk_i, rst_ni);

  // high if we are in READ_RSP_BUSY and received rsp_valid
  logic wait_for_busy_q, wait_for_busy_d;
  `FFL(wait_for_busy_q, wait_for_busy_d, clk_en_p_i, '0, clk_i, rst_ni);

  logic rsp_valid, tx_done;

  cmd_seq_state_e cmd_seq_state_d, cmd_seq_state_q;


  always_comb begin : cmd_sequence_next_state
    cmd_seq_state_d = cmd_seq_state_q;

    unique case (cmd_seq_state_q)
      READY: begin
        if (start_tx_q) begin
          cmd_seq_state_d = WRITE_CMD
        end
      end

      WRITE_CMD: begin
        if (tx_done) begin
          cmd_seq_state_d = (reg2hw.command.response_type_select.q == NO_RESPONSE)
                            ? RSP_RECEIVED
                            : BUS_SWITCH;
        end
      end

      BUS_SWITCH: begin
        if ((reg2hw.command.response_type_select.q == RESPONSE_LENGTH_48_CHECK_BUSY) || running_cmd12_q) begin
          cmd_seq_state_d = READ_RSP_BUSY;
        end else begin
          cmd_seq_state_d = READ_RSP;
        end
      end

      READ_RSP: begin
        if (rsp_valid) begin
          cmd_seq_state_d = RSP_RECEIVED;
        end
      end

      READ_RSP_BUSY: begin
        if (wait_for_busy_q && dat0_i) begin
          cmd_seq_state_d = RSP_RECEIVED;
        end
      end

      RSP_RECEIVED: begin
        if (timing_counter == N_RC-1) begin
          cmd_seq_state_d = READY;
        end
      end

      default: begin
        cmd_seq_state_d = READY;
      end
    endcase
  end : cmd_sequence_next_state


  `FFL(cmd_seq_state_q, cmd_seq_state_d, clk_en_p_i, READY, clk_i, rst_ni);

  ///////////////
  // Data Path //
  ///////////////

  logic check_end_bit_err, check_crc_err, check_index_err, check_timeout_error;
  logic start_listening, receiving;

  logic end_bit_err, crc_corr, index_err;

  logic rx_started_q, rx_started_d;
  `FFL(rx_started_q, rx_started_d, clk_en_p_i, 0, clk_i, rst_ni);


  assign check_end_bit_err   = reg2hw.error_interrupt_status_enable.command_end_bit_error_status_enable.q;
  assign check_crc_err       = reg2hw.error_interrupt_status_enable.command_crc_error_status_enable.q & reg2hw.command.command_crc_check_enable.q;
  assign check_index_err     = reg2hw.error_interrupt_status_enable.command_index_error_status_enable.q & reg2hw.command.command_index_check_enable.q;
  assign check_timeout_error = reg2hw.error_interrupt_status_enable.command_timeout_error_status_enable.q;


  always_comb begin : cmd_seq_ctrl
    start_listening = 1'b0;
    timing_counter_en  = 1'b0;
    timing_counter_clr = 1'b1;
    command_end_bit_error_o.d  = 1'b1;
    command_end_bit_error_o.de = 1'b0;
    command_crc_error_o.d  = 1'b1;
    command_crc_error_o.de = 1'b0;
    command_index_error_o.d  = 1'b1;
    command_index_error_o.de = 1'b0;
    command_timeout_error_o.d  = 1'b1;
    command_timeout_error_o.de = 1'b0;

    auto_cmd12_errors_o.auto_cmd12_timeout_error = '{ de: '0, d: '1 };
    auto_cmd12_errors_o.auto_cmd12_end_bit_error = '{ de: '0, d: '1 };
    auto_cmd12_errors_o.auto_cmd12_crc_error     = '{ de: '0, d: '1 };
    auto_cmd12_errors_o.auto_cmd12_index_error   = '{ de: '0, d: '1 };

    sd_rsp_done_o = 1'b0;
    sd_cmd_done_o = 1'b0;

    wait_for_busy_d = 1'b0;
    rx_started_d    = 1'b0;

    unique case (cmd_seq_state_q)
      READY:;

      WRITE_CMD:;

      BUS_SWITCH: begin
        sd_cmd_done_o   = 1'b1;
        start_listening = 1'b1;
      end

      READ_RSP: begin
        timing_counter_en  = 1'b1;
        timing_counter_clr = receiving; // reset counter when we are receiving

        if (timing_counter >= 62) command_timeout_error_o.de = check_timeout_error & clk_en_p_i;

        if (rsp_valid) begin
          command_end_bit_error_o.de = (check_end_bit_err & end_bit_err & clk_en_p_i);
          command_crc_error_o.de     = (check_crc_err & ~crc_corr & clk_en_p_i);
          command_index_error_o.de   = (check_index_err & index_err & clk_en_p_i);
        end
      end

      READ_RSP_BUSY: begin
        wait_for_busy_d = wait_for_busy_q;
        rx_started_d    = (receiving) ? '1 : rx_started_q;


        // response should still start within 64 clock cycles, card may become busy during response
        timing_counter_en  = 1'b1;
        timing_counter_clr = rx_started_q; // stop counter when we are receiving


        if (timing_counter >= 63) begin
          // timeout interrupt if response didn't start within 64 clock cycles

          if (running_cmd12_q) auto_cmd12_errors_o.auto_cmd12_timeout_error.de = '1;
          else command_timeout_error_o.de = check_timeout_error & clk_en_p_i;
        end

        if (rsp_valid) begin
          wait_for_busy_d = 1'b1;

          if (running_cmd12_q) begin
            auto_cmd12_errors_o.auto_cmd12_end_bit_error.de = end_bit_err & clk_en_p_i;
            auto_cmd12_errors_o.auto_cmd12_crc_error.de = ~crc_corr & clk_en_p_i;
            auto_cmd12_errors_o.auto_cmd12_index_error.de = index_err & clk_en_p_i;
          end else begin
            command_end_bit_error_o.de = (check_end_bit_err & end_bit_err & clk_en_p_i);
            command_crc_error_o.de     = (check_crc_err & ~crc_corr & clk_en_p_i);
            command_index_error_o.de   = (check_index_err & index_err & clk_en_p_i);
          end
        end
      end

      RSP_RECEIVED: begin
        timing_counter_en  = 1'b1;
        timing_counter_clr = 1'b0;
        sd_rsp_done_o      = 1'b1;
      end

      default:;
    endcase
  end : cmd_seq_ctrl


  // cmd phase assignment
  logic cmd_phase_d, cmd_phase_q;
  always_comb begin : cmd_phase_assignment
    cmd_phase_d = cmd_phase_q;

    if (cmd_seq_state_q != WRITE_CMD) begin
      cmd_phase_d = ~reg2hw.host_control.high_speed_enable.q;
    end
  end : cmd_phase_assignment
  `FFL(cmd_phase_q, cmd_phase_d, clk_en_p_i, 1'b1, clk_i, rst_ni);


  logic cmd12_requested_q, cmd12_requested_d;
  `FF(cmd12_requested_q, cmd12_requested_d, '0, clk_i, rst_ni);

  // high if command was requested by driver but not started yet
  logic driver_cmd_requested_q, driver_cmd_requested_d;
  `FF(driver_cmd_requested_q, driver_cmd_requested_d, '0, clk_i, rst_ni);

  logic dat_busy_q, dat_busy_d;
  `FF(dat_busy_q, dat_busy_d, '0, clk_i, rst_ni);

  assign sd_cmd_dat_busy_o = dat_busy_q;

  logic [5:0] command_index;
  assign command_index = running_cmd12_q ? 6'd12 : reg2hw.command.command_index.q;


  logic  command_requested;
  assign command_requested        = cmd12_requested_q || driver_cmd_requested_q || reg2hw.command.command_index.qe;

  assign command_inhibit_cmd_o.de = '1;
  assign command_inhibit_cmd_o.d  = (cmd_seq_state_q != READY) || command_requested;

  // host registers operate on clk, cmd/rsp logic on sd_clk
  // assumes clock edges are simultaneous
  always_comb begin : start_tx_cdc
    auto_cmd12_errors_o.auto_cmd12_not_executed                = '{ de: '0, d: '1 };
    auto_cmd12_errors_o.command_not_issued_by_auto_cmd12_error = '{ de: '0, d: '1 };

    driver_cmd_requested_d = driver_cmd_requested_q;
    dat_busy_d = dat_busy_q;

    // extend pulse
    cmd12_requested_d = cmd12_requested_q | request_cmd12_i;

    running_cmd12_d = running_cmd12_q;
    start_tx_d      = start_tx_q;

    // write to command index starts transmission
    if (reg2hw.command.command_index.qe) begin
      driver_cmd_requested_d = '1;
      if (reg2hw.command.response_type_select.q == 2'b11) dat_busy_d = '1;
    end

    if (cmd_seq_state_q == READY) begin
      if (!start_tx_q) begin
        running_cmd12_d = '0;
        if (cmd12_requested_q) begin
          if (
            reg2hw.error_interrupt_status.command_index_error.q ||
            reg2hw.error_interrupt_status.command_end_bit_error.q ||
            reg2hw.error_interrupt_status.command_crc_error.q ||
            reg2hw.error_interrupt_status.command_timeout_error.q
          ) begin
            // prior command failed, do not execute auto cmd 12
            cmd12_requested_d = '0;
            auto_cmd12_errors_o.auto_cmd12_not_executed.de = '1;
          end else begin
            // execute auto cmd 12
            start_tx_d      = '1;
            running_cmd12_d = '1;
          end

        end else if (driver_cmd_requested_q) begin
          if (
            reg2hw.auto_cmd12_error_status.auto_cmd12_index_error.q ||
            reg2hw.auto_cmd12_error_status.auto_cmd12_end_bit_error.q ||
            reg2hw.auto_cmd12_error_status.auto_cmd12_crc_error.q ||
            reg2hw.auto_cmd12_error_status.auto_cmd12_timeout_error.q
          ) begin
            // prior auto cmd 12 failed, do not execute cmd
            driver_cmd_requested_d = '0;
            auto_cmd12_errors_o.command_not_issued_by_auto_cmd12_error.de = '1;
          end else begin
            // execute cmd
            start_tx_d = '1;
          end

        end else if (!reg2hw.command.command_index.qe) begin
          dat_busy_d = '0;
        end
      end

    end else if (start_tx_q) begin
      // Request received by sdclk domain, transmission has started
      start_tx_d = '0;
      if (running_cmd12_q) begin
        cmd12_requested_d = '0;
      end else begin
        driver_cmd_requested_d = '0;
      end
    end

  end : start_tx_cdc


  logic [31:0] rsp0, rsp1, rsp2, rsp3;
  logic [119:0] rsp;
  logic long_rsp;

  assign index_err = (rsp [37:32] != command_index);

  logic update_rsp_reg;

  always_comb begin : rsp_assignment

    rsp0 = reg2hw.response0.q;
    rsp1 = reg2hw.response1.q;
    rsp2 = reg2hw.response2.q;
    rsp3 = reg2hw.response3.q;
    update_rsp_reg = 1'b0; // only update response register when there was a response

    if (running_cmd12_q) begin
      // auto cmd 12 response goes to upper word of rsp register
      rsp3 = rsp [31:0];
    end else begin

      unique case (reg2hw.command.response_type_select.q)
        2'b00:;
        // no response

        2'b01: begin
          // long response
          rsp0 = rsp[31:0];
          rsp1 = rsp[63:32];
          rsp2 = rsp[95:64];
          rsp3[23:0] = rsp[119:96]; // save bits 31:24 of rsp3
          update_rsp_reg = 1'b1;
        end

        2'b10: begin
          // short response without busy signaling
          rsp0 = rsp[31:0];
          update_rsp_reg = 1'b1;
        end

        2'b11: begin
          // short response with busy signaling
          rsp0 = rsp[31:0];
          update_rsp_reg = 1'b1;
        end

        default:;
      endcase
    end

    response0_d_o  = rsp0;
    response1_d_o  = rsp1;
    response2_d_o  = rsp2;
    response3_d_o  = rsp3;

    response0_de_o = (update_rsp_reg & rsp_valid & clk_en_p_i);
    response1_de_o = (update_rsp_reg & rsp_valid & clk_en_p_i);
    response2_de_o = (update_rsp_reg & rsp_valid & clk_en_p_i);
    response3_de_o = (update_rsp_reg & rsp_valid & clk_en_p_i);
  end : rsp_assignment

  ///////////////////////////
  // Module Instantiations //
  ///////////////////////////

  cmd_write i_cmd_write (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),

    .clk_en_p_i     (clk_en_p_i),
    .clk_en_n_i     (clk_en_n_i),
    .div_1_i        (div_1_i),

    .cmd_o          (sd_bus_cmd_o),
    .cmd_en_o       (sd_bus_cmd_en_o),
    .start_tx_i     (start_tx_q), // need to buffer when registers run faster than cmd_write
    .cmd_argument_i (running_cmd12_q ? '0 : reg2hw.argument.q),
    .cmd_nr_i       (command_index),
    .cmd_phase_i    (cmd_phase_q),
    .tx_done_o      (tx_done)
  );

  // response type is "Response Length 136"
  assign long_rsp = (reg2hw.command.response_type_select.q == 2'b01);

  rsp_read  i_rsp_read (
    .clk_i             (clk_i),
    .clk_en_i          (clk_en_p_i),
    .rst_ni            (rst_ni),
    .cmd_i             (sd_bus_cmd_i),
    .long_rsp_i        (long_rsp),
    .start_listening_i (start_listening),
    .receiving_o       (receiving),
    .rsp_valid_o       (rsp_valid),
    .end_bit_err_o     (end_bit_err),
    .rsp_o             (rsp),
    .crc_corr_o        (crc_corr)
  );

  counter #(
    .WIDTH            (3'd6),
    .STICKY_OVERFLOW  (1'b0)
  ) i_counter (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .clear_i    (timing_counter_clr),
    .en_i       (timing_counter_en & clk_en_p_i),
    .load_i     (1'b0),
    .down_i     (1'b0),
    .d_i        (6'b0),
    .q_o        (timing_counter),
    .overflow_o ()
  );

endmodule
