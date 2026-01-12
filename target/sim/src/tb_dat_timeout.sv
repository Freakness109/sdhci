// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@student.ethz.ch>

module tb_dat_timeout #(
  parameter time         ClkPeriod = 50ns,
  parameter int unsigned RstCycles = 1,
  parameter int unsigned TimeoutDivider = 13
)();
  sdhci_fixture #(
    .ClkPeriod     (ClkPeriod),
    .RstCycles     (RstCycles),
    .TimeoutDivider(TimeoutDivider)
  ) fixture ();

  int ClkEnPeriod;
  logic [15:0] normal_interrupt_status;
  logic [15:0] error_interrupt_status;
  logic response_done;

  initial begin : configure_tb
    if (!$value$plusargs("ClkEnPeriod=%d", ClkEnPeriod)) begin
      ClkEnPeriod = 4;
    end
    $display("Testing timeouts with ClkEnPeriod=%d", ClkEnPeriod);
  end : configure_tb

  task wfi(input int unsigned timeout_cycles);
    fork
      begin
        fork
          begin
            fixture.vip.wait_for_interrupt();
          end
          begin
            repeat(timeout_cycles) fixture.vip.wait_for_sdclk();
            $fatal("Interrupt timed out");
          end
        join_any
        disable fork;
      end
    join
  endtask

  initial begin
    fixture.vip.wait_for_reset();
    fixture.vip.obi.set_interrupt_status_enable(
      // enable command complete and transaction complete
      .normal_interrupt_status_enable('h0003),
      // enable data + command timeout error
      .error_interrupt_status_enable('h0011),
      .finish_transaction(1'b0)
    );
    fixture.vip.obi.set_interrupt_signal_enable(
      // enable command complete and transaction complete
      .normal_interrupt_signal_enable('h0003),
      // enable data + command timeout error
      .error_interrupt_signal_enable('h0011),
      .finish_transaction(1'b0)
    );
    fixture.vip.obi.set_frequency_select(
      .divider(ClkEnPeriod >> 1),
      .finish_transaction(1'b0)
    );
    fixture.vip.obi.set_clock_enable(.enable(1'b1), .finish_transaction(1'b0));
    // prepare identification command
    fixture.vip.obi.set_transfer_mode(
      .is_multi_block(1'b0),
      .is_read(1'b0),
      .auto_cmd12_enable(1'b0),
      .block_count_enable(1'b0),
      .dma_enable(1'b0),
      .finish_transaction(1'b0)
    );
    fixture.vip.obi.launch_command(
      .command_index(6'd0),
      .command_type (2'b00), // normal command
      .data_present (1'b0),
      .index_check_enable(1'b1),
      .crc_check_enable(1'b1),
      .response_type(2'b11), // 48bit no busy
      .finish_transaction(1'b1)
    );

    wfi(200);

    fixture.vip.obi.get_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    fixture.vip.obi.clear_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    if (error_interrupt_status != 'h0000) begin
      $fatal("Some error occured during the transaction");
    end

    if (error_interrupt_status != 'h0001) begin
      $fatal("Interrupt status wrong. Should be command complete ('h1), but got %x", normal_interrupt_status);
    end

    wfi(400);

    fixture.vip.obi.get_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    fixture.vip.obi.clear_interrupt_status(
      .normal_interrupt_status(normal_interrupt_status),
      .error_interrupt_status(error_interrupt_status)
    );

    if (error_interrupt_status != 'h0000) begin
      $fatal("Some error occured during the transaction");
    end

    if (error_interrupt_status != 'h0002) begin
      $fatal("Interrupt status wrong. Should be transaction complete ('h2), but got %x", normal_interrupt_status);
    end

    wait (response_done);

    $display("All good");
    $finish();
  end

  initial begin
    response_done = 1'b0;
    fixture.vip.wait_for_reset();
    fixture.vip.sd.wait_for_cmd_held();
    fixture.vip.sd.wait_for_cmd_released();
    // the response must come within 64 cycles
    repeat(63) fixture.vip.wait_for_sdclk();
    fixture.vip.sd.send_response_48(
      .index(6'd0),
      .crc  (7'h0),
      .busy_cycles(300)
    );

    response_done = 1'b1;
  end

endmodule
