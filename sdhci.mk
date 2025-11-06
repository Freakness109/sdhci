# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Axel Vanoni <axvanoni@student.ethz.ch>

BENDER ?= bender

SDHCI_ROOT ?= $(shell $(BENDER) path sdhci)

include hw/hw.mk
include sw/sw.mk
include target/sim/sim.mk

sdhci-all: sdhci-sw-all sdhci-hw-all sdhci-sim-all
sdhci-clean: sdhci-sim-clean
sdhci-deepclean: sdhci-clean sdhci-sim-deepclean

.PHONY: sdhci-all sdhci-clean sdhci-deepclean
