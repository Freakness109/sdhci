// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@student.ethz.ch>

module tb_block_read #(
    parameter time         ClkPeriod     = 50ns,
    parameter int unsigned RstCycles     = 1,
    parameter int unsigned ClkEnPeriod   = 1,
    parameter int unsigned BlockSize     = 512,
    parameter int unsigned BlockCount    = 2,
    parameter logic        Do4Bit        = 1'b1
)();

  sdhci_fixture #(
    .ClkPeriod(ClkPeriod),
    .RstCycles(RstCycles)
  ) fixture ();

  task automatic wfi(input int unsigned timeout_cycles, string error_context);
    fork
      begin
        fork
          begin
            fixture.vip.wait_for_interrupt();
          end
          begin
            repeat(timeout_cycles) fixture.vip.wait_for_sdclk();
            $fatal(1, "Interrupt timed out waiting for %s", error_context);
          end
        join_any
        disable fork;
      end
    join
  endtask

  task automatic check_irq(logic [15:0] expected_normal, logic [15:0] expected_error, string error_context);
    logic [15:0] error_interrupt_status;
    logic [15:0] error_interrupt_status_all;
    logic [15:0] normal_interrupt_status;
    logic [15:0] normal_interrupt_status_all;

    fixture.vip.obi.get_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    fixture.vip.obi.clear_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    normal_interrupt_status_all = normal_interrupt_status;
    error_interrupt_status_all  = error_interrupt_status;

    fixture.vip.obi.get_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    while (normal_interrupt_status || error_interrupt_status) begin
      fixture.vip.obi.clear_interrupt_status(
        .normal_interrupt_status(normal_interrupt_status),
        .error_interrupt_status(error_interrupt_status)
      );

      normal_interrupt_status_all |= normal_interrupt_status;
      error_interrupt_status_all  |= error_interrupt_status;

      fixture.vip.obi.get_interrupt_status(
        .normal_interrupt_status(normal_interrupt_status),
        .error_interrupt_status(error_interrupt_status)
      );
    end

    if (error_interrupt_status_all != expected_error) begin
      $fatal(1, "Unexpected error interrupt status, got %x, expected %x (%s)", error_interrupt_status_all, expected_error, error_context);
    end

    if (normal_interrupt_status_all != expected_normal) begin
      $fatal(1, "Unexpected normal interrupt status, got %x, expected %x (%s)", normal_interrupt_status_all, expected_normal, error_context);
    end
  endtask

  initial begin : cmd_response
    fixture.vip.wait_for_reset();

    // cmd0 with data
    fixture.vip.sd.wait_for_cmd_held();
    fixture.vip.sd.wait_for_cmd_released();

    // bus is idle for 2 cycles
    fixture.vip.wait_for_sdclk();
    fixture.vip.sd.send_response_48('d18, 'h3A);

    // cmd12 with busy
    fixture.vip.sd.wait_for_cmd_held();
    fixture.vip.sd.wait_for_cmd_released();

    // bus is idle for 2 cycles
    fixture.vip.wait_for_sdclk();
    fixture.vip.sd.send_response_48('d12, 'h7A);
  end

  initial begin : dat_response
    logic was_interrupted;
    logic [511:0][7:0] block;
    block = {
      // 512 * 8 bits
      // -> 4096
      64 {
        // 64 bits
        {8'hde},
        {8'had},
        {8'hbe},
        {8'hef},
        {8'hca},
        {8'hfe},
        {8'hba},
        {8'hbe}
      }
  };

    was_interrupted = 1'b0;
    fixture.vip.wait_for_reset();

    // wait for the read command
    fixture.vip.sd.wait_for_cmd_held();
    fixture.vip.sd.wait_for_cmd_released();

    while (was_interrupted == 1'b0) begin
      fixture.vip.wait_for_sdclk();
      fixture.vip.sd.send_data_block_interruptible(
        .block(block),
        .block_size(BlockSize),
        .is_4_bit(Do4Bit),
        .was_interrupted(was_interrupted)
      );
      repeat(100) fixture.vip.wait_for_sdclk();
    end
  end

  initial begin : obi_driver
    logic [31:0] read_data;
    logic buffer_read_enable, buffer_write_enable;

    fixture.vip.wait_for_reset();
    fixture.vip.obi.set_interrupt_status_enable(
      .normal_interrupt_status_enable('hFFFF),
      .error_interrupt_status_enable('hFFFF),
      .finish_transaction(1'b0)
    );
    fixture.vip.obi.set_interrupt_signal_enable(
      .normal_interrupt_signal_enable('hFFFF),
      .error_interrupt_signal_enable('hFFFF),
      .finish_transaction(1'b0)
    );

    fixture.vip.obi.set_host_control_1(
      .dma_select('0),
      .high_speed_enable(1'b1),
      .do_4_bit_transfer(Do4Bit),
      .finish_transaction(1'b0)
    );

    fixture.vip.obi.set_frequency_select(
      .divider(8'(ClkEnPeriod >> 1)),
      .finish_transaction(1'b0)
    );
    fixture.vip.obi.set_clock_enable(.enable(1'b1), .finish_transaction(1'b0));

    fixture.vip.obi.set_transfer_mode(
      .is_multi_block(1'b1),
      .is_read(1'b1),
      .auto_cmd12_enable(1'b0),
      .block_count_enable(1'b1),
      .dma_enable(1'b0),
      .finish_transaction(1'b0)
    );

    fixture.vip.obi.set_block_size_count(
      .block_size(BlockSize),
      .block_count(16'd2),
      .finish_transaction(1'b0)
    );

    fixture.vip.obi.launch_command(
      .command_index(6'd18),
      .command_type (2'b00), // normal command
      .data_present (1'b1),
      .index_check_enable(1'b1),
      .crc_check_enable(1'b1),
      .response_type(2'b10), // 48 bit no busy
      .finish_transaction(1'b1)
    );

    wfi(200, "cmd18 complete");
    check_irq(
      .expected_normal('h01), // cmd complete
      .expected_error ('h0),  // no error
      .error_context("cmd18 complete")
    );

    wfi(BlockSize * 8 + 500, "first data present");
    check_irq(
      .expected_normal('h20), // data present
      .expected_error ('h0),  // no error
      .error_context("first data present")
    );

    repeat (BlockCount - 1) begin
      repeat (BlockSize / 4) begin
        fixture.vip.obi.read_buffer_data(.data(read_data));
      end
      fixture.vip.obi.get_present_status_buffer_enable(
        .buffer_read_enable(buffer_read_enable),
        .buffer_write_enable(buffer_write_enable)
      );
      if (!buffer_read_enable) begin
        wfi(BlockSize * 8 + 500, "data present during loop");
      end
      check_irq(
        .expected_normal('h20), // data present
        .expected_error ('h0),  // no error
        .error_context("data present during loop")
      );
    end
    repeat (BlockSize / 4) begin
      fixture.vip.obi.read_buffer_data(.data(read_data));
    end
    wfi(200, "cmd18 transfer complete");
    check_irq(
      .expected_normal('h02), // transfer complete
      .expected_error ('h0),  // no error
      .error_context("cmd18 transfer complete")
    );
    fixture.vip.obi.get_present_status_buffer_enable(
      .buffer_read_enable(buffer_read_enable),
      .buffer_write_enable(buffer_write_enable)
    );

    if (buffer_read_enable) begin
      $fatal(1, "We should no longer have data!");
    end

    // TODO: read interrupt registers + check transfer complete

    fixture.vip.obi.launch_command(
      .command_index(6'd12),
      .command_type (2'b00), // normal command
      .data_present (1'b0),
      .index_check_enable(1'b1),
      .crc_check_enable(1'b1),
      .response_type(2'b11), // 48 bit with busy
      .finish_transaction(1'b1)
    );

    wfi(200, "cmd12 complete and transfer complete");
    check_irq(
      .expected_normal('h03), // cmd complete
      .expected_error ('h0),  // no error
      .error_context("cmd12 complete and transfer complete")
    );

    $display("All good");

    $finish();
  end

endmodule
