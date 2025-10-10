// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Micha Wehrli <miwehrli@student.ethz.ch>

`include "common_cells/registers.svh"
`include "defines.svh"

module sdhci_reg_logic (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic rst_cmd_ni,
  input  logic rst_dat_ni,

  input sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,
  input sdhci_reg_pkg::sdhci_hw2reg_t hw2reg_i,

  output sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_modified_o,

  input logic sd_cmd_dat_busy_i,

  output `writable_reg_t() error_interrupt_o,
  output `writable_reg_t() auto_cmd12_error_o,

  output `writable_reg_t() buffer_read_ready_o,
  output `writable_reg_t() buffer_write_ready_o,

  output `writable_reg_t() dat_line_active_o,
  output `writable_reg_t() command_inhibit_dat_o,

  output `writable_reg_t() transfer_complete_o,
  output `writable_reg_t() command_complete_o,

  output `writable_reg_t() card_removal_o,
  output `writable_reg_t() card_insertion_o,

  output logic [15:0]            block_count_o,
  input  `writable_reg_t([15:0]) block_count_hw_i,

  output sdhci_reg_pkg::sdhci_hw2reg_block_size_reg_t    block_size_reg_o,
  output sdhci_reg_pkg::sdhci_hw2reg_transfer_mode_reg_t transfer_mode_reg_o,

  output logic [7:0] interrupt_signal_for_each_slot_o,
  output logic interrupt_o
);
  `define did_get_set(register, field) ( \
    hw2reg_i.register.field.de & // Was written \
    (|(~reg2hw_i.register.field.q & // Was 0 \
        hw2reg_i.register.field.d))) // Is 1

  `define did_get_unset(register, field) ( \
    hw2reg_i.register.field.de & // Was written \
    (|(reg2hw_i.register.field.q & // Was 1 \
      ~hw2reg_i.register.field.d))) // Is 0

  `define instant_reg_value(register, field)  \
      (hw2reg_i.register.field.de ? hw2reg_i.register.field.d : reg2hw_i.register.field.q)

  `define should_interrupt(register, field) ( \
    |( reg2hw_i.register``_status.field.q & // Is 1 \
        reg2hw_i.register``_signal_enable.field``_signal_enable.q)) // Should interrupt \
    
  assign interrupt_signal_for_each_slot_o[7:1] = '0;
  assign interrupt_signal_for_each_slot_o[0] =
    // `should_interrupt(normal_interrupt, card_interrupt    ) |
    `should_interrupt(normal_interrupt, card_removal      ) |
    `should_interrupt(normal_interrupt, card_insertion    ) |
    `should_interrupt(normal_interrupt, buffer_read_ready ) |
    `should_interrupt(normal_interrupt, buffer_write_ready) |
    // `should_interrupt(normal_interrupt, dma_interrupt     ) |
    // `should_interrupt(normal_interrupt, block_gap_event   ) |
    `should_interrupt(normal_interrupt, transfer_complete ) |
    `should_interrupt(normal_interrupt, command_complete  ) |

    `should_interrupt(error_interrupt, auto_cmd12_error     ) |
    // `should_interrupt(error_interrupt, current_limit_error  ) |
    `should_interrupt(error_interrupt, data_end_bit_error   ) |
    `should_interrupt(error_interrupt, data_crc_error       ) |
    `should_interrupt(error_interrupt, data_timeout_error   ) |
    `should_interrupt(error_interrupt, command_index_error  ) |
    `should_interrupt(error_interrupt, command_end_bit_error) |
    `should_interrupt(error_interrupt, command_crc_error    ) |
    `should_interrupt(error_interrupt, command_timeout_error) /*|
    `should_interrupt(error_interrupt, vendor_specific_error)*/;


  logic interrupt_status_q, interrupt_status_d;
  `FF(interrupt_status_q, interrupt_status_d, '0);
  assign interrupt_status_d = interrupt_signal_for_each_slot_o[0];

  // Send interrupt if any interupt status went from 0 to 1
  assign interrupt_o = !interrupt_status_q && interrupt_status_d;

  // Automatically write to Error Interrupt Status
  assign error_interrupt_o.d = rst_ni &
    (//(|`instant_reg_value(error_interrupt_status, vendor_specific_error)) |
       `instant_reg_value(error_interrupt_status, auto_cmd12_error     )  |
      //  `instant_reg_value(error_interrupt_status, current_limit_error  )  |
       `instant_reg_value(error_interrupt_status, data_end_bit_error   )  |
       `instant_reg_value(error_interrupt_status, data_crc_error       )  |
       `instant_reg_value(error_interrupt_status, data_timeout_error   )  |
       `instant_reg_value(error_interrupt_status, command_index_error  )  |
       `instant_reg_value(error_interrupt_status, command_end_bit_error)  |
       `instant_reg_value(error_interrupt_status, command_crc_error    )  |
       `instant_reg_value(error_interrupt_status, command_timeout_error));
  assign error_interrupt_o.de = '1;

  // Automatically write to AutoCMD12 Error Interrupt Status
  assign auto_cmd12_error_o.d = '1;
  assign auto_cmd12_error_o.de = rst_ni &
    reg2hw_i.error_interrupt_status_enable.auto_cmd12_error_status_enable.q &
    (`did_get_set(auto_cmd12_error_status, command_not_issued_by_auto_cmd12_error) |
     `did_get_set(auto_cmd12_error_status, auto_cmd12_index_error                ) |
     `did_get_set(auto_cmd12_error_status, auto_cmd12_end_bit_error              ) |
     `did_get_set(auto_cmd12_error_status, auto_cmd12_crc_error                  ) |
     `did_get_set(auto_cmd12_error_status, auto_cmd12_timeout_error              ) |
     `did_get_set(auto_cmd12_error_status, auto_cmd12_not_executed               ));

  assign buffer_read_ready_o.d = '1;
  assign buffer_read_ready_o.de = rst_dat_ni & `did_get_set(present_state, buffer_read_enable);

  assign buffer_write_ready_o.d = '1;
  assign buffer_write_ready_o.de = rst_dat_ni & `did_get_set(present_state, buffer_write_enable);


  assign dat_line_active_o.de = '1;
  assign dat_line_active_o.d = rst_dat_ni & (sd_cmd_dat_busy_i |
    `instant_reg_value(present_state, write_transfer_active) |
    `instant_reg_value(present_state, read_transfer_active));

  assign command_inhibit_dat_o.de = '1;
  assign command_inhibit_dat_o.d = rst_dat_ni &
    `instant_reg_value(present_state, dat_line_active);
  
    
  logic reading;
  assign reading = reg2hw_i.transfer_mode.data_transfer_direction_select.q;

  assign transfer_complete_o.d = '1;
  assign transfer_complete_o.de = rst_dat_ni &
    (`did_get_unset(present_state, read_transfer_active) |
     (~reading & `did_get_unset(present_state, dat_line_active)));

  assign command_complete_o.d = '1;
  assign command_complete_o.de = rst_cmd_ni & `did_get_unset(present_state, command_inhibit_cmd);


  assign card_insertion_o.d = '1;
  assign card_insertion_o.de = rst_dat_ni & `did_get_set(present_state, card_inserted);

  assign card_removal_o.d = '1;
  assign card_removal_o.de = rst_dat_ni & `did_get_unset(present_state, card_inserted);
  
  // Writes to the transfer_mode register should be ignored when command_inhibit_cmd is active
  `FFL (transfer_mode_reg_o.multi_single_block_select     .d, reg2hw_i.transfer_mode.multi_single_block_select     .q,
        !reg2hw_i.present_state.command_inhibit_cmd.q && reg2hw_i.transfer_mode.multi_single_block_select     .qe, '0)
  `FFL (transfer_mode_reg_o.data_transfer_direction_select.d, reg2hw_i.transfer_mode.data_transfer_direction_select.q,
        !reg2hw_i.present_state.command_inhibit_cmd.q && reg2hw_i.transfer_mode.data_transfer_direction_select.qe, '0)
  `FFL (transfer_mode_reg_o.auto_cmd12_enable             .d, reg2hw_i.transfer_mode.auto_cmd12_enable             .q,
        !reg2hw_i.present_state.command_inhibit_cmd.q && reg2hw_i.transfer_mode.auto_cmd12_enable             .qe, '0)
  `FFL (transfer_mode_reg_o.block_count_enable            .d, reg2hw_i.transfer_mode.block_count_enable            .q,
        !reg2hw_i.present_state.command_inhibit_cmd.q && reg2hw_i.transfer_mode.block_count_enable            .qe, '0)
  `FFL (transfer_mode_reg_o.dma_enable                    .d, reg2hw_i.transfer_mode.dma_enable                    .q,
        !reg2hw_i.present_state.command_inhibit_cmd.q && reg2hw_i.transfer_mode.dma_enable                    .qe, '0)

  // Writes to the block_count and block_size register should be ignored when command_inhibit_dat is active
  logic [11:0] block_size;
  `FFL (block_size, reg2hw_i.block_size.transfer_block_size.q,
        !reg2hw_i.present_state.command_inhibit_dat.q && reg2hw_i.block_size.transfer_block_size.qe, '0);

  assign block_size_reg_o.transfer_block_size.d = block_size;
  assign block_size_reg_o.host_dma_buffer_boundary.d = '0;

  logic [15:0] block_count_q, block_count_d;
  `FF (block_count_q, block_count_d, '0);
  always_comb begin
    block_count_d = block_count_q;   
    if (!reg2hw_i.present_state.command_inhibit_dat.q && reg2hw_i.block_count.qe) begin
      block_count_d = reg2hw_i.block_count.q;
    end else if (block_count_hw_i.de) begin
      block_count_d = block_count_hw_i.d;   
    end
  end
  assign block_count_o = block_count_q;

  always_comb begin
    reg2hw_modified_o = reg2hw_i;   

    reg2hw_modified_o.transfer_mode.multi_single_block_select     .q = transfer_mode_reg_o.multi_single_block_select     .d;
    reg2hw_modified_o.transfer_mode.data_transfer_direction_select.q = transfer_mode_reg_o.data_transfer_direction_select.d;
    reg2hw_modified_o.transfer_mode.auto_cmd12_enable             .q = transfer_mode_reg_o.auto_cmd12_enable             .d;
    reg2hw_modified_o.transfer_mode.block_count_enable            .q = transfer_mode_reg_o.block_count_enable            .d;
    reg2hw_modified_o.transfer_mode.dma_enable                    .q = transfer_mode_reg_o.dma_enable                    .d;

    reg2hw_modified_o.block_size.transfer_block_size.q = block_size_reg_o.transfer_block_size.d;

    reg2hw_modified_o.block_count.q = block_count_o;
  end
endmodule
