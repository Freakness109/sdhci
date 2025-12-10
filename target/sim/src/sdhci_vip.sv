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
    obi_req_o = '0;
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

  task automatic obi_write(
    logic [31:0] address,
    logic [3:0]  be,
    logic [31:0] data,
    logic finish_transaction = 1'b1
  );
    @(posedge clk_o);
    #(TA);
    obi_req_o.a.we    = 1'b1;
    obi_req_o.a.addr  = address;
    obi_req_o.a.be    = be;
    obi_req_o.a.wdata = data;
    obi_req_o.req = 1'b1;

    // wait for the interface to be ready
    #(TT - TA);
    while (obi_rsp_i.gnt == 1'b0) begin
      @(posedge clk_o)
      #(TT);
    end

    if (finish_transaction) begin
      @(posedge clk_o)
      #(TA);
      obi_req_o.req = 1'b0;
    end
  endtask

  task automatic obi_read(
    logic [31:0] address,
    logic [3:0]  be,
    output logic [31:0] data
  );
    @(posedge clk_o);
    #(TA);
    obi_req_o.a.we    = 1'b0;
    obi_req_o.a.addr  = address;
    obi_req_o.a.be    = be;
    obi_req_o.req = 1'b1;

    // wait for the interface to be ready
    #(TT - TA);
    while (obi_rsp_i.gnt == 1'b0) begin
      @(posedge clk_o)
      #(TT);
    end

    @(posedge clk_o)
    #(TA);
    obi_req_o.req = 1'b0;

    #(TT - TA);
    while (obi_rsp_i.rvalid == 1'b0) begin
      @(posedge clk_o)
      #(TT);
    end
    data = obi_rsp_i.r.rdata;
  endtask

  task automatic set_interrupt_status_enable(
    logic [15:0] normal_interrupt_status_enable = '0,
    logic [15:0] error_interrupt_status_enable  = '0,
    logic set_normal_ise = 1'b1,
    logic set_error_ise = 1'b1,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    if (set_normal_ise) begin
      be[1:0] = '1;
    end
    if (set_error_ise) begin
      be[3:2] = '1;
    end

    obi_write('h034, be, {error_interrupt_status_enable, normal_interrupt_status_enable}, finish_transaction);
  endtask

  task automatic set_frequency_select(
    logic [7:0] divider,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    be = 4'b0010;
    obi_write('h02C, be, {16'b0, divider, 8'b0}, finish_transaction);
  endtask
  
  task automatic set_clock_enable(
    logic enable,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    be = 4'b0001;
    obi_write('h02C, be, {16'b0, 5'b0, enable, 2'b0}, finish_transaction);
  endtask

  task automatic set_transfer_mode(
    logic is_multi_block,
    logic is_read,
    logic auto_cmd12_enable,
    logic block_count_enable,
    logic dma_enable,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    be = 4'b0001;
    obi_write('h00C, be, {24'b0, 2'b0, is_multi_block, is_read, 1'b0,
                          auto_cmd12_enable, block_count_enable, dma_enable}, finish_transaction);
  endtask

  task automatic set_block_size_count(
    logic [11:0] block_size,
    logic [15:0] block_count,
    logic set_size = 1'b1,
    logic set_count = 1'b1,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    be = 4'b0000;
    if (set_size == 1'b1) begin
      be[1:0] = 2'b11;
    end
    if (set_count == 1'b1) begin
      be[3:2] = 2'b11;
    end

    obi_write('h004, be, {block_count, 4'b0, block_size}, finish_transaction);
  endtask

  task automatic launch_command(
    logic [5:0] command_index,
    logic [1:0] command_type,
    logic data_present,
    logic index_check_enable,
    logic crc_check_enable,
    logic [1:0] response_type,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    be = 4'b1100;
    obi_write('h00C, be, {2'b0, command_index, command_type, data_present, index_check_enable,
                          crc_check_enable, 1'b0, response_type, 16'b0}, finish_transaction);
  endtask

  task automatic write_buffer_data(
    logic [31:0] data,
    logic finish_transaction = 1'b1
  );
    logic [3:0] be;
    be = 4'b1111;
    obi_write('h020, be, data, finish_transaction);
  endtask

  task automatic get_interrupt_status(
    output logic [15:0] normal_interrupt_status,
    output logic [15:0] error_interrupt_status
  );
    logic [3:0] be;
    be = 4'b1111;
    obi_read('h030, be, {error_interrupt_status, normal_interrupt_status});
  endtask

  task automatic get_acmd_error_status(
    output logic [7:0] error_status
  );
    logic [3:0] be;
    logic [31:0] response;
    be = 4'b0001;
    obi_read('h03C, be, response);
    error_status = response[7:0];
  endtask

endmodule
