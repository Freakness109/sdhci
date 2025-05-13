`ifndef USER_SDHCI_DEFINES_SVH_
`define USER_SDHCI_DEFINES_SVH_

`define writable_reg_t(size) \
  struct packed {            \
    logic size d;            \
    logic de;                \
  }

`endif
