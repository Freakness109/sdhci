`include "common_cells/registers.svh"

`define writable_reg_t(size) \
struct packed {            \
    logic size d;            \
    logic de;                \
  }

module sdhci_reg_logic (
  input  logic clk_i,
  input  logic rst_ni,

  input sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,
  input sdhci_reg_pkg::sdhci_hw2reg_t hw2reg_i,

  output `writable_reg_t() error_interrupt_o,
  output `writable_reg_t() auto_cmd12_error_o,

  output `writable_reg_t() buffer_read_ready_o,
  output `writable_reg_t() buffer_write_ready_o,

  output `writable_reg_t() transfer_complete_o,
  output `writable_reg_t() command_complete_o,

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
    hw2reg_i.register``_status.field.de & // Was written \
    (|(~reg2hw_i.register``_status.field.q & // Was 0 \
        hw2reg_i.register``_status.field.d & // Is 1 \
        reg2hw_i.register``_signal_enable.field``_signal_enable.q))) // Should interrupt \
    
  // Send interrupt if any interupt status went from 0 to 1
  logic interrupt_q, interrupt_d;
  `FF(interrupt_q, interrupt_d, '0, clk_i, rst_ni);
  assign interrupt_d =
    `should_interrupt(normal_interrupt, card_interrupt    ) |
    `should_interrupt(normal_interrupt, card_removal      ) |
    `should_interrupt(normal_interrupt, card_insertion    ) |
    `should_interrupt(normal_interrupt, buffer_read_ready ) |
    `should_interrupt(normal_interrupt, buffer_write_ready) |
    `should_interrupt(normal_interrupt, dma_interrupt     ) |
    `should_interrupt(normal_interrupt, block_gap_event   ) |
    `should_interrupt(normal_interrupt, transfer_complete ) |
    `should_interrupt(normal_interrupt, command_complete  ) |

    `should_interrupt(error_interrupt, auto_cmd12_error     ) |
    `should_interrupt(error_interrupt, current_limit_error  ) |
    `should_interrupt(error_interrupt, data_end_bit_error   ) |
    `should_interrupt(error_interrupt, data_crc_error       ) |
    `should_interrupt(error_interrupt, data_timeout_error   ) |
    `should_interrupt(error_interrupt, command_index_error  ) |
    `should_interrupt(error_interrupt, command_end_bit_error) |
    `should_interrupt(error_interrupt, command_crc_error    ) |
    `should_interrupt(error_interrupt, command_timeout_error) |
    `should_interrupt(error_interrupt, vendor_specific_error);

  assign interrupt_o = interrupt_q;

  // Automatically write to Error Interrupt Status
  assign error_interrupt_o.d = rst_ni &
    (|`instant_reg_value(error_interrupt_status, vendor_specific_error)) |
      `instant_reg_value(error_interrupt_status, auto_cmd12_error     )  |
      `instant_reg_value(error_interrupt_status, current_limit_error  )  |
      `instant_reg_value(error_interrupt_status, data_end_bit_error   )  |
      `instant_reg_value(error_interrupt_status, data_crc_error       )  |
      `instant_reg_value(error_interrupt_status, data_timeout_error   )  |
      `instant_reg_value(error_interrupt_status, command_index_error  )  |
      `instant_reg_value(error_interrupt_status, command_end_bit_error)  |
      `instant_reg_value(error_interrupt_status, command_crc_error    )  |
      `instant_reg_value(error_interrupt_status, command_timeout_error); 
  assign error_interrupt_o.de = '1;

  // Automatically write to AutoCMD12 Error Interrupt Status
  assign auto_cmd12_error_o.d = '1;
  assign auto_cmd12_error_o.de = rst_ni &
    `did_get_set(auto_cmd12_error_status, command_not_issued_by_auto_cmd12_error) |
    `did_get_set(auto_cmd12_error_status, auto_cmd12_index_error                ) |
    `did_get_set(auto_cmd12_error_status, auto_cmd12_end_bit_error              ) |
    `did_get_set(auto_cmd12_error_status, auto_cmd12_crc_error                  ) |
    `did_get_set(auto_cmd12_error_status, auto_cmd12_timeout_error              ) |
    `did_get_set(auto_cmd12_error_status, auto_cmd12_not_executed               );

  assign buffer_read_ready_o.d = '1;
  assign buffer_read_ready_o.de = rst_ni & `did_get_set(present_state, buffer_read_enable);

  assign buffer_write_ready_o.d = '1;
  assign buffer_write_ready_o.de = rst_ni & `did_get_set(present_state, buffer_write_enable);
    
  assign transfer_complete_o.d = '1;
  assign transfer_complete_o.de = rst_ni & `did_get_unset(present_state, command_inhibit_dat);

  assign command_complete_o.d = '1;
  assign command_complete_o.de = rst_ni & `did_get_unset(present_state, command_inhibit_cmd);
  
  // TODO ignore writes to transfer mode if command_inhibit_cmd is set
endmodule