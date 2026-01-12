// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@student.ethz.ch>

module sdhci_sd_driver #(
  parameter time TA = 5ns,
  parameter time TT = 15ns
)(
  input  logic sd_clk_i,

  output logic sd_cmd_o,
  input  logic sd_cmd_i,
  input  logic sd_cmd_en_i,

  output logic [3:0] sd_dat_o,
  input  logic [3:0] sd_dat_i,
  input  logic       sd_dat_en_i
);

  initial begin
    sd_cmd_o  = 1'b1;
    sd_dat_o  = '1;
  end

  task automatic apply_logic (
    input logic value,
    output logic to_write
  );
    @(posedge sd_clk_i);
    #(TA);
    to_write = value;
  endtask

  task automatic wait_for_cmd_released();
    @(posedge sd_clk_i);
    #(TT);
    while (sd_cmd_en_i != 1'b0) begin
      @(posedge sd_clk_i);
      #(TT);
    end
  endtask

  task automatic wait_for_cmd_held();
    @(posedge sd_clk_i);
    #(TT);
    while (sd_cmd_en_i != 1'b1) begin
      @(posedge sd_clk_i);
      #(TT);
    end
  endtask

  task automatic wait_for_dat_released();
    @(posedge sd_clk_i);
    #(TT);
    while (sd_dat_en_i != 1'b0) begin
      @(posedge sd_clk_i);
      #(TT);
    end
  endtask

  task automatic wait_for_dat_held();
    @(posedge sd_clk_i);
    #(TT);
    while (sd_dat_en_i != 1'b1) begin
      @(posedge sd_clk_i);
      #(TT);
    end
  endtask

  task automatic send_response_48 (
    input logic [5:0] index,
    input logic [6:0] crc,
    input logic [31:0] card_status = '0,
    input logic end_bit = 1'b1
  );
    // start bit
    apply_logic(1'b0, sd_cmd_o);

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
  endtask

  task automatic claim_busy();
    apply_logic(1'b0, sd_dat_o[0]);
  endtask

  task automatic release_busy();
    apply_logic(1'b1, sd_dat_o[0]);
  endtask

  task automatic send_response_136(
    input logic [126:0] cid_status
  );
    // start bit
    apply_logic(1'b0, sd_cmd_o);
    // transmission bit
    apply_logic(1'b0, sd_cmd_o);

    // check bits
    repeat (6) apply_logic(1'b1, sd_cmd_o);

    // cid
    for (int i = 0; i < 127; i += 1) begin
      apply_logic(cid_status[126-i], sd_cmd_o);
    end

    // check bits
    apply_logic(1'b1, sd_cmd_o);
  endtask

  task automatic send_response_dat(
    input logic is_ok
  );
    // start bit
    apply_logic(1'b0, sd_dat_o[0]);
    // transmission ok: 010, transmission not ok: 101
    // keyword in spec: CRC status token
    apply_logic(~is_ok, sd_dat_o[0]);
    apply_logic( is_ok, sd_dat_o[0]);
    apply_logic(~is_ok, sd_dat_o[0]);
    // end bit
    apply_logic(1'b1, sd_dat_o[0]);
  endtask

endmodule
