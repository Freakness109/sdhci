// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Anton Buchner <abuchner@student.ethz.ch>
// - Micha Wehrli <miwehrli@student.ethz.ch>

// Handles reception of responses on CMD line

`include "common_cells/registers.svh"

module rsp_read (
  input logic clk_i,
  input logic clk_en_i,
  input logic rst_ni,
  input logic cmd_i,

  input logic long_rsp_i,         // high if response is of type R2 (136 bit)
  input logic start_listening_i,  // should be asserted 2nd cycle after end bit of CMD
  input logic timeout_i, // TODO: implement

  output  logic receiving_o,      // start bit was observed
  output  logic rsp_valid_o,      // write response, end_bit_err and crc_corr to register
  output  logic end_bit_err_o,    // valid at the same time as response
  output  logic [119:0] rsp_o,    // without start, transmission, reserved, crc and end bits
  output  logic crc_corr_o        // active if crc7 was correct, valid when rsp_valid_o is active
);

  //////////////////////
  // State Transition //
  //////////////////////

  typedef enum logic [2:0] {
    INACTIVE,
    WAIT_FOR_START_BIT,
    SHIFT_IN,
    FINISHED
  } rx_state_e;
  rx_state_e rx_state_d, rx_state_q;

  logic start_bit_observed, all_bits_received;

  always_comb begin : rsp_state_transition
    rx_state_d = rx_state_q;

    unique case (rx_state_q)

      INACTIVE: begin
        if (start_listening_i) begin
          rx_state_d = WAIT_FOR_START_BIT;
        end
      end

      WAIT_FOR_START_BIT: begin
        if (start_bit_observed) begin
          rx_state_d = SHIFT_IN;
        end
      end

      SHIFT_IN: begin
        if (all_bits_received) begin
          rx_state_d = FINISHED;
        end
      end

      FINISHED: begin
        rx_state_d = INACTIVE;
      end

      default: begin
        rx_state_d = INACTIVE;
      end
    endcase
  end : rsp_state_transition

  `FFL(rx_state_q, rx_state_d, clk_en_i, INACTIVE, clk_i, rst_ni);

  ///////////////
  // Data Path //
  ///////////////

  // sequence
  logic cnt_clear, cnt_en;
  logic [7:0] bit_cnt;

  logic rsp_ser;
  assign rsp_ser = cmd_i;

  logic shift_reg_shift_in_en, shift_reg_par_output_en;

  logic crc_start, crc_end_output;
  logic [6:0] crc7_calc;

  logic [8:0] shift_start_cnt, shift_done_cnt, crc_done_cnt, done_cnt;

  // sequence depends on rsp length
  assign shift_start_cnt  = (long_rsp_i) ? 8'd7 : 8'd1;
  assign shift_done_cnt   = (long_rsp_i) ? 8'd127 : 8'd39;
  assign crc_done_cnt     = (long_rsp_i) ? 8'd133 : 8'd45;
  assign done_cnt         = (long_rsp_i) ? 8'd134 : 8'd46;

  always_comb begin : rsp_data_path
    start_bit_observed      = 1'b0;
    all_bits_received       = 1'b0;
    shift_reg_shift_in_en   = 1'b0;
    shift_reg_par_output_en = 1'b0;
    crc_start               = 1'b0;
    crc_end_output          = 1'b0;
    crc_corr_o              = 1'b0;
    cnt_clear               = 1'b1;
    cnt_en                  = 1'b0;
    end_bit_err_o           = 1'b1;
    rsp_valid_o             = 1'b0;
    receiving_o             = 1'b0;


    unique case (rx_state_q)

      WAIT_FOR_START_BIT: begin
        start_bit_observed = ~rsp_ser; // start bit is first 0 on bus
        if (~long_rsp_i) begin
          crc_start = ~rsp_ser; // start crc for short response
        end
      end

      SHIFT_IN: begin
        cnt_clear = 1'b0;
        cnt_en    = 1'b1;
        receiving_o = 1'b1;
        if (bit_cnt == 8'd6) begin
          crc_start = 1'b1; // start crc for long response
        end

        // shift in response. Start and transmission bit are not needed. Index is not needed for long response
        if (bit_cnt >= shift_start_cnt) begin
          shift_reg_shift_in_en = 1'b1;
        end

        // all relevant data is in the shift register
        if (bit_cnt >= shift_done_cnt) begin
          shift_reg_shift_in_en   = 1'b0;
          shift_reg_par_output_en = 1'b1;
        end

        // crc calculation is finished. Output crc
        if (bit_cnt == crc_done_cnt) begin
          crc_end_output = 1'b1;
        end

        if (bit_cnt >= done_cnt) begin
          all_bits_received = 1'b1;
        end
      end

      FINISHED: begin
        shift_reg_par_output_en = 1'b1;
        rsp_valid_o             = 1'b1;
        receiving_o             = 1'b1;

        crc_corr_o    = (crc7_calc == 7'b0);
        end_bit_err_o = ~rsp_ser;
      end

      default: ;
    endcase
  end : rsp_data_path

  ///////////////////////////
  // Module Instantiations //
  ///////////////////////////

  ser_par_shift_reg #(
    .NumBits    (120), // r2 response, start, transmission, reserved, crc and end bits not needed
    .MaskOutput (1)    // to avoid large number of gates switching during shifting
  ) i_rsp_shift_reg (
    .clk_i            (clk_i),
    .clk_en_i         (clk_en_i),
    .rst_ni           (rst_ni),
    .shift_in_en_i    (shift_reg_shift_in_en),
    .par_output_en_i  (shift_reg_par_output_en),
    .dat_ser_i        (rsp_ser),
    .dat_par_o        (rsp_o)
  );

  crc7_read i_crc7_read (
    .clk_i        (clk_i),
    .clk_en_i     (clk_en_i),
    .rst_ni       (rst_ni),
    .start_i      (crc_start),
    .end_output_i (crc_end_output),
    .rsp_ser_i    (rsp_ser),
    .crc7_o       (crc7_calc)
  );

  counter #(
    .WIDTH            (8), // longest response is 136 bits
    .STICKY_OVERFLOW  (1)
  ) i_rsp_counter (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .clear_i    (cnt_clear),
    .en_i       (cnt_en && clk_en_i),
    .load_i     (1'b0),
    .down_i     (1'b0),
    .d_i        (8'b0),
    .q_o        (bit_cnt),
    .overflow_o ()
  );
endmodule
