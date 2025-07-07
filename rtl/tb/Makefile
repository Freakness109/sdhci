VERILATOR ?= verilator

RTL   ?= ../../..
SDHCI ?= ..

all: dat acmd12

obj_dir/V%: %.sv
	$(VERILATOR) --quiet --binary -j 0 --assert --trace --trace-structs --trace-fst --timing --autoflush -O3 -CFLAGS "-O1 -march=native" \
		-Wno-style -Wno-WIDTHEXPAND -Wno-fatal \
		--top $* \
		-f $(RTL)/../verilator/croc.f \
		$*

dat: obj_dir/Vtb_dat
	set -e; \
	for BlockSize in $$(seq 1 128); do \
	for ClkEnPeriod in 1 2 3; do \
	for UseWideBus in 0 1 ; do \
		obj_dir/Vtb_dat +verilator+quiet +UseWideBus=$$UseWideBus +BlockSize=$$BlockSize +ClkEnPeriod=$$ClkEnPeriod ; \
	done \
	done \
	done

acmd12: obj_dir/Vtb_acmd12
	set -e; \
	for Cycles in $$(seq -10 10); do \
	for Valid in 0 1 ; do \
	obj_dir/Vtb_acmd12 +verilator+quiet \
		+CyclesThatDriverCommandArrivesBeforeCMD12=$$Cycles \
		+IsFirstResponseValid=$$Valid ; \
	done \
	done

#	obj_dir/Vtb_acmd12 +verilator+quiet \
#		+CyclesThatDriverCommandArrivesBeforeCMD12=3 \
#		+IsFirstResponseValid=0


.PHONY: acmd12 dat all