// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "defines.svh"

module tb_dat_buffer_sizes #(
  parameter time ClkPeriod = 50ns
)();
  logic clk;
  logic rst_n;
  logic [2:0] done;

  clk_rst_gen #(
    .ClkPeriod    ( ClkPeriod ),
    .RstClkCycles ( 1 )
  ) i_clk_rst_sys (
    .clk_o  ( clk   ),
    .rst_no ( rst_n )
  );

  tb_dat_buffer_size_case #(.NumWords(8)) i_32b (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .done_o (done[0])
  );

  tb_dat_buffer_size_case #(.NumWords(128)) i_512b (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .done_o (done[1])
  );

  tb_dat_buffer_size_case #(.NumWords(256)) i_1024b (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .done_o (done[2])
  );

  initial begin
    wait(&done);
    repeat (10) @(posedge clk);
    $finish();
  end
endmodule

module tb_dat_buffer_size_case #(
  parameter int unsigned NumWords = 8,
  parameter int unsigned BlockSize = 512
) (
  input  logic clk_i,
  input  logic rst_ni,
  output logic done_o
);
  localparam int unsigned NumBytes = NumWords * 4;
  localparam int unsigned ChunkBytes = (BlockSize < NumBytes) ? BlockSize : NumBytes;
  localparam int unsigned ChunkWords = ChunkBytes / 4;
  localparam int unsigned BlockWords = BlockSize / 4;

  logic clear;
  logic read_operation;
  logic write_operation;
  logic read_ready;
  logic read_valid;
  logic [31:0] read_data;
  logic write_valid;
  logic [31:0] write_data;
  logic write_ready;
  logic empty;
  logic [31:0] buffer_data_port_d;
  logic buffer_read_enable;
  logic buffer_write_enable;
  logic [15:0] block_count;

  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw;
  `writable_reg_t() buffer_read_enable_hw;
  `writable_reg_t() buffer_write_enable_hw;
  `writable_reg_t([15:0]) block_count_hw;

  assign buffer_read_enable = buffer_read_enable_hw.d;
  assign buffer_write_enable = buffer_write_enable_hw.d;
  assign block_count = block_count_hw.d;

  dat_buffer #(
    .NumWords        (NumWords),
    .MaxBlockBitSize (10)
  ) i_dat_buffer (
    .clk_i,
    .rst_ni,
    .clear_i           (clear),
    .read_operation_i  (read_operation),
    .write_operation_i (write_operation),
    .read_ready_i      (read_ready),
    .read_valid_o      (read_valid),
    .read_data_o       (read_data),
    .write_valid_i     (write_valid),
    .write_data_i      (write_data),
    .write_ready_o     (write_ready),
    .empty_o           (empty),
    .reg2hw_i          (reg2hw),
    .buffer_data_port_d_o(buffer_data_port_d),
    .buffer_read_enable_o(buffer_read_enable_hw),
    .buffer_write_enable_o(buffer_write_enable_hw),
    .block_count_o     (block_count_hw)
  );

  task automatic init_inputs();
    clear = 1'b0;
    read_operation = 1'b0;
    write_operation = 1'b0;
    read_ready = 1'b0;
    write_valid = 1'b0;
    write_data = '0;
    reg2hw = '0;
    reg2hw.block_size.transfer_block_size.q = BlockSize;
    reg2hw.transfer_mode.multi_single_block_select.q = 1'b1;
    reg2hw.block_count.q = 16'd2;
  endtask

  task automatic pulse_clear();
    clear = 1'b1;
    @(posedge clk_i);
    clear = 1'b0;
    @(posedge clk_i);
  endtask

  task automatic test_read_side();
    read_operation = 1'b1;
    @(posedge clk_i);

    for (int unsigned i = 0; i < ChunkWords - 1; i++) begin
      repeat (10) begin
        if (write_ready) begin
          break;
        end
        @(posedge clk_i);
      end
      if (!write_ready) begin
        $fatal(1, "read-side buffer did not become writable for NumWords=%0d", NumWords);
      end
      write_data = 32'h1000_0000 + i;
      write_valid = 1'b1;
      @(posedge clk_i);
    end

    write_valid = 1'b0;
    @(posedge clk_i);
    if (buffer_read_enable) begin
      $fatal(1, "buffer_read_enable asserted before one chunk for NumWords=%0d", NumWords);
    end

    write_data = 32'h1000_0000 + ChunkWords - 1;
    write_valid = 1'b1;
    @(posedge clk_i);
    write_valid = 1'b0;
    @(posedge clk_i);

    if (!buffer_read_enable) begin
      $fatal(1, "buffer_read_enable did not assert after one chunk for NumWords=%0d", NumWords);
    end

    for (int unsigned i = 0; i < BlockWords; i++) begin
      if (i >= ChunkWords) begin
        write_data = 32'h1000_0000 + i;
        write_valid = write_ready;
      end
      reg2hw.buffer_data_port.re = 1'b1;
      @(posedge clk_i);
      reg2hw.buffer_data_port.re = 1'b0;
      write_valid = 1'b0;
      @(posedge clk_i);
    end

    read_operation = 1'b0;
  endtask

  task automatic test_write_side();
    write_operation = 1'b1;
    @(posedge clk_i);
    if (!buffer_write_enable) begin
      $fatal(1, "buffer_write_enable not asserted on empty buffer for NumWords=%0d", NumWords);
    end

    for (int unsigned i = 0; i < ChunkWords; i++) begin
      reg2hw.buffer_data_port.q = 32'h2000_0000 + i;
      reg2hw.buffer_data_port.qe = 1'b1;
      @(posedge clk_i);
      reg2hw.buffer_data_port.qe = 1'b0;
      @(posedge clk_i);
    end

    if (ChunkWords == NumWords && buffer_write_enable) begin
      $fatal(1, "buffer_write_enable remained asserted on full buffer for NumWords=%0d", NumWords);
    end

    for (int unsigned i = 0; i < ChunkWords; i++) begin
      if (!read_valid) begin
        $fatal(1, "read_valid deasserted before buffered chunk drained for NumWords=%0d", NumWords);
      end
      read_ready = 1'b1;
      @(posedge clk_i);
      read_ready = 1'b0;
      @(posedge clk_i);
    end

    write_operation = 1'b0;
  endtask

  initial begin
    done_o = 1'b0;
    init_inputs();
    wait(rst_ni);
    @(posedge clk_i);

    pulse_clear();
    test_read_side();
    pulse_clear();
    test_write_side();

    done_o = 1'b1;
  end
endmodule
