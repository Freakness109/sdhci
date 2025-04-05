`include "common_cells/registers.svh"

`define writable_reg(size) \
struct packed {            \
  logic size d;            \
  logic de;                \
}

module sdhci_reg_logic (
  input  logic clk_i,
  input  logic rst_ni,

  input sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,
  input sdhci_reg_pkg::sdhci_hw2reg_t hw2reg_i,

  output `writable_reg() error_interrupt_o,
  output `writable_reg() auto_cmd12_error_o,

  output `writable_reg() buffer_read_ready_o,
  output `writable_reg() buffer_write_ready_o,

  output logic interrupt_o
);
  `define did_get_set(register, field) ( \
    hw2reg_i.register``_status.field.de & // Was written \
    (|(~reg2hw_i.register``_status.field.q & // Was 0 \
        hw2reg_i.register``_status.field.d & // Is 1 \
        reg2hw_i.register``_signal_enable.field``_signal_enable.q))) // Should interrupt \
    
  // Send interrupt if any interupt status is going from 0 to 1
  logic interrupt_q, interrupt_d;
  `FF(interrupt_q, interrupt_d, '0, clk_i, rst_ni);
  assign interrupt_d = 
    `did_get_set(normal_interrupt, card_interrupt    ) |
    `did_get_set(normal_interrupt, card_removal      ) |
    `did_get_set(normal_interrupt, card_insertion    ) |
    `did_get_set(normal_interrupt, buffer_read_ready ) |
    `did_get_set(normal_interrupt, buffer_write_ready) |
    `did_get_set(normal_interrupt, dma_interrupt     ) |
    `did_get_set(normal_interrupt, block_gap_event   ) |
    `did_get_set(normal_interrupt, transfer_complete ) |
    `did_get_set(normal_interrupt, command_complete  ) |

    `did_get_set(error_interrupt, auto_cmd12_error     ) |
    `did_get_set(error_interrupt, current_limit_error  ) |
    `did_get_set(error_interrupt, data_end_bit_error   ) |
    `did_get_set(error_interrupt, data_crc_error       ) |
    `did_get_set(error_interrupt, data_timeout_error   ) |
    `did_get_set(error_interrupt, command_index_error  ) |
    `did_get_set(error_interrupt, command_end_bit_error) |
    `did_get_set(error_interrupt, command_crc_error    ) |
    `did_get_set(error_interrupt, command_timeout_error) |
    `did_get_set(error_interrupt, vendor_specific_error);

  assign interrupt_o = interrupt_q;

  // Automatically write to Error Interrupt Status
  assign error_interrupt_o.de =
    hw2reg_i.error_interrupt_status.vendor_specific_error.de |
    hw2reg_i.error_interrupt_status.auto_cmd12_error     .de |
    hw2reg_i.error_interrupt_status.current_limit_error  .de |
    hw2reg_i.error_interrupt_status.data_end_bit_error   .de |
    hw2reg_i.error_interrupt_status.data_crc_error       .de |
    hw2reg_i.error_interrupt_status.data_timeout_error   .de |
    hw2reg_i.error_interrupt_status.command_index_error  .de |
    hw2reg_i.error_interrupt_status.command_end_bit_error.de |
    hw2reg_i.error_interrupt_status.command_crc_error    .de |
    hw2reg_i.error_interrupt_status.command_timeout_error.de;

  assign error_interrupt_o.d =
    (|hw2reg_i.error_interrupt_status.vendor_specific_error.d) |
      hw2reg_i.error_interrupt_status.auto_cmd12_error     .d  |
      hw2reg_i.error_interrupt_status.current_limit_error  .d  |
      hw2reg_i.error_interrupt_status.data_end_bit_error   .d  |
      hw2reg_i.error_interrupt_status.data_crc_error       .d  |
      hw2reg_i.error_interrupt_status.data_timeout_error   .d  |
      hw2reg_i.error_interrupt_status.command_index_error  .d  |
      hw2reg_i.error_interrupt_status.command_end_bit_error.d  |
      hw2reg_i.error_interrupt_status.command_crc_error    .d  |
      hw2reg_i.error_interrupt_status.command_timeout_error.d; 

  // Automatically write to AutoCMD12 Error Interrupt Status
  assign auto_cmd12_error_o.d =
    hw2reg_i.auto_cmd12_error_status.command_not_issued_by_auto_cmd12_error.d |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_index_error                .d |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_end_bit_error              .d |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_crc_error                  .d |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_timeout_error              .d |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_not_executed               .d;
  
  assign auto_cmd12_error_o.de =
    hw2reg_i.auto_cmd12_error_status.command_not_issued_by_auto_cmd12_error.de |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_index_error                .de |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_end_bit_error              .de |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_crc_error                  .de |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_timeout_error              .de |
    hw2reg_i.auto_cmd12_error_status.auto_cmd12_not_executed               .de;

  assign buffer_read_ready_o.d = '1;
  assign buffer_read_ready_o.de = 
    ~reg2hw_i.present_state.buffer_read_enable.q &
    hw2reg_i.present_state.buffer_read_enable.d &
    hw2reg_i.present_state.buffer_read_enable.de;

  assign buffer_write_ready_o.d = '1;
  assign buffer_write_ready_o.de =
    ~reg2hw_i.present_state.buffer_write_enable.q &
    hw2reg_i.present_state.buffer_write_enable.d &
    hw2reg_i.present_state.buffer_write_enable.de;
endmodule