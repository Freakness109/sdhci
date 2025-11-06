# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Micha Wehrli <miwehrli@student.ethz.ch>
# - Axel Vanoni <axvanoni@student.ethz.ch>

REGGEN ?= python $(shell $(BENDER) path register_interface)/vendor/lowrisc_opentitan/util/regtool.py

$(SDHCI_ROOT)/hw/reg/%_reg_pkg.sv: $(SDHCI_ROOT)/hw/reg/%_regs.hjson
	$(REGGEN) $< -r -t $(shell dirname $@)

$(SDHCI_ROOT)/hw/reg/%_reg_top.sv: $(SDHCI_ROOT)/hw/reg/%_regs.hjson
	$(REGGEN) $< -r -t $(shell dirname $@)

sdhci-reggen: $(SDHCI_ROOT)/hw/reg/sdhci_reg_pkg.sv $(SDHCI_ROOT)/hw/reg/sdhci_reg_top.sv
.PHONY: sdhci-reggen

sdhci-hw-all: sdhci-reggen
.PHONY: sdhci-hw-all
