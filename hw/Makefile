# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Micha Wehrli <miwehrli@student.ethz.ch>

deps:
	@test `pwd` = '/fosic/designs/croc/rtl/user_domain/sdhci' && echo '[WARNING] THIS WILL NOT WORK INSIDE THE DOCKER IMAGE' || true

	mkdir -p model
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/rtl/verilog/sd_crc_7.v
	cd model && curl -O https://raw.githubusercontent.com/fabriziotappero/ip-cores/refs/heads/communication_controller_wishbone_sd_card_controller/rtl/verilog/sd_crc_16.v
	cd model && curl -O https://gist.githubusercontent.com/micha4w/38fad58c1cea3157f204709d4eca227e/raw/6bd185335ec809baef707e8ec3cdde7fd5bcb6fa/sdModel.v

REGGEN ?= python $(shell bender path register_interface)/vendor/lowrisc_opentitan/util/regtool.py

reggen: reg/sdhci_reg_pkg.sv

reg/%_reg_pkg.sv: reg/%_regs.hjson
	$(REGGEN) $< -r -t $(shell dirname $@)

reg/%_reg_top.sv: reg/%_regs.hjson
	$(REGGEN) $< -r -t $(shell dirname $@)

.PHONY: reggen

clean:
	rm -rf model
