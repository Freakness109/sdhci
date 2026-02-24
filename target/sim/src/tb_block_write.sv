// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@student.ethz.ch>

module tb_block_write #(
    parameter time         ClkPeriod     = 50ns,
    parameter int unsigned RstCycles     = 1,
    parameter int unsigned ClkEnPeriod   = 2,
    parameter int unsigned BlockSize     = 512,
    parameter int unsigned BlockCount    = 16,
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
    fixture.vip.sd.send_response_48('d25, 'h4B);

    // cmd12 with busy
    fixture.vip.sd.wait_for_cmd_held();
    fixture.vip.sd.wait_for_cmd_released();

    // bus is idle for 2 cycles
    fixture.vip.wait_for_sdclk();
    fixture.vip.sd.send_response_48('d12, 'h7A);
  end

  initial begin : dat_response
    fixture.vip.wait_for_reset();

    // write
    repeat (BlockCount) begin
      fixture.vip.sd.wait_for_dat_held();
      fixture.vip.sd.wait_for_dat_released();

      // crc status after 2 idle cycles
      fixture.vip.wait_for_sdclk();
      fixture.vip.sd.send_response_dat(.is_ok(1'b1));

      // claim busy for a while to assert interrupt timing
      fixture.vip.sd.claim_busy();
      repeat(50) fixture.vip.wait_for_sdclk();
      fixture.vip.sd.release_busy();
    end

    // autocmd12 with busy
    fixture.vip.sd.wait_for_cmd_held();
    fixture.vip.sd.wait_for_cmd_released();
    // claim busy for a while to assert interrupt timing
    fixture.vip.sd.claim_busy();
    repeat(50) fixture.vip.wait_for_sdclk();
    fixture.vip.sd.release_busy();
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
      .is_read(1'b0),
      .auto_cmd12_enable(1'b0),
      .block_count_enable(1'b1),
      .dma_enable(1'b0),
      .finish_transaction(1'b0)
    );

    fixture.vip.obi.set_block_size_count(
      .block_size(BlockSize),
      .block_count(BlockCount),
      .finish_transaction(1'b0)
    );

    fixture.vip.obi.launch_command(
      .command_index(6'd25),
      .command_type (2'b00), // normal command
      .data_present (1'b1),
      .index_check_enable(1'b1),
      .crc_check_enable(1'b1),
      .response_type(2'b11), // 48 bit busy
      .finish_transaction(1'b1)
    );

    wfi(200, "cmd18 complete");
    check_irq(
      .expected_normal('h10), // write data ready
      .expected_error ('h0),  // no error
      .error_context("cmd18 complete")
    );
    repeat (BlockSize / 4 - 1) begin
      fixture.vip.obi.write_buffer_data(.data(32'hdeadbeef), .finish_transaction(1'b1));
    end
    fixture.vip.obi.write_buffer_data(.data(32'hdeadbeef), .finish_transaction(1'b1));
    wfi(BlockSize * 8 + 500, "first data write");
    check_irq(
      .expected_normal('h11), // buffer has space
      .expected_error ('h0),  // no error
      .error_context("first data write")
    );
    fixture.vip.obi.get_present_status_buffer_enable(
      .buffer_read_enable(buffer_read_enable),
      .buffer_write_enable(buffer_write_enable)
    );
    while (!buffer_write_enable) begin
      wfi(BlockSize * 8 + 500, "data write during loop");
      check_irq(
        .expected_normal('h10), // buffer has space
        .expected_error ('h0),  // no error
        .error_context("data write during loop")
      );
      fixture.vip.obi.get_present_status_buffer_enable(
        .buffer_read_enable(buffer_read_enable),
        .buffer_write_enable(buffer_write_enable)
      );
    end
    repeat (BlockCount - 1) begin
      repeat (BlockSize / 4 - 1) begin
        fixture.vip.obi.write_buffer_data(.data(32'hdeadbeef), .finish_transaction(1'b1));
      end
      fixture.vip.obi.write_buffer_data(.data(32'hdeadbeef), .finish_transaction(1'b1));
      fixture.vip.obi.get_present_status_buffer_enable(
        .buffer_read_enable(buffer_read_enable),
        .buffer_write_enable(buffer_write_enable)
      );
      while (!buffer_write_enable) begin
        wfi(BlockSize * 8 + 500, "data write during loop");
        check_irq(
          .expected_normal('h10), // buffer has space
          .expected_error ('h0),  // no error
          .error_context("data write during loop")
        );
        fixture.vip.obi.get_present_status_buffer_enable(
          .buffer_read_enable(buffer_read_enable),
          .buffer_write_enable(buffer_write_enable)
        );
      end
    end
    // clear buffer ready
    wfi(BlockSize * 8 + 500, "after write loop");
    check_irq(
      .expected_normal('h02), // transfer complete
      .expected_error ('h0),  // no error
      .error_context("after write loop")
    );

    fixture.vip.obi.get_present_status_buffer_enable(
      .buffer_read_enable(buffer_read_enable),
      .buffer_write_enable(buffer_write_enable)
    );

    if (buffer_write_enable) begin
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
