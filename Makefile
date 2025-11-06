# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Axel Vanoni <axvanoni@student.ethz.ch>

SDHCI_ROOT ?= .
BENDER     ?= bender -d $(SDHCI_ROOT)

.DEFAULT_GOAL = all

include sdhci.mk


all: sdhci-all
hw: sdhci-hw-all
sw: sdhci-sw-all
sim: sdhci-sim-all
clean: sdhci-clean
deepclean: sdhci-deepclean

help:
	@echo "Some available commands"
	@echo "all:       Fetch & compile everything"
	@echo "hw:        Regenerate generated hardware"
	@echo "sw:        Compile the software libraries"
	@echo "sim:       Generate simulation scripts and download models."
	@echo "           Note: Some of these models are under other licenses."
	@echo "                 Make sure you agree to them before downloading them."
	@echo "clean:     Remove compilation artifacts"
	@echo "deepclean: *clean* and remove downloaded models"

.PHONY: all sw hw sim clean deepclean help
