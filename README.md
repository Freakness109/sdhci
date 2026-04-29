# SDHCI Controller

This repository contains a synthesizable SD Host Controller Interface (SDHCI)
hardware block with a register interface, SD command/data-line logic, an OBI
wrapper, simulation testbenches, and simple software support files.

## Current IP Behavior

The top-level SDHCI controller is `hw/sdhci_top.sv`. It exposes a generic
register request/response interface, SD card pads (`sd_clk`, `sd_cmd`, 4-bit
`sd_dat`, card detect), and one interrupt output. `hw/sdhci_top_obi.sv` wraps
the same controller for OBI integrations.

The controller currently implements:

- SD command issue and response capture, including CRC7 handling.
- DAT read/write transfers on the 4-bit SD data bus, including CRC16 handling.
- Single-block and multi-block transfer flow, including block-count updates.
- Auto CMD12 sequencing and Auto CMD12 error status reporting.
- Command and data timeout reporting.
- Card-detect debounce and present-state reporting.
- SD clock generation from `clk_i` with `ClkPreDiv` and the SDHCI clock-control
  divider.
- A semi-handwritten SDHCI register file in `hw/reg/sdhci_reg_top.sv`, with
  register data structures in `hw/reg/sdhci_reg_pkg.sv` and register-side
  behavioral glue in `hw/reg/sdhci_reg_logic.sv`.
- Software reset of the full controller, command path, and data path.
- Write-one-to-clear interrupt/status behavior and interrupt signal generation.

The DAT buffer size is controlled by `BufferNumWords`, with one 32-bit word per
entry. The default configuration is SDHCI-compliant:

```systemverilog
parameter int unsigned BufferNumWords = 256;
parameter bit AllowNoncompliantBufferSizes = 1'b0;
```

With `AllowNoncompliantBufferSizes == 0`, the buffer must be at least 512 bytes
and data-port ready/status behavior is presented in full-block chunks. With
`AllowNoncompliantBufferSizes == 1`, smaller buffers are allowed as an explicit
integration escape hatch; software can discover the data-port chunk size through
the vendor capabilities register at offset `0x44`. In that mode, bit 31 marks
the noncompliant configuration and bits `[15:0]` report the buffer chunk size in
bytes.

The implementation intentionally does not include DMA yet. Programmed I/O
through the Buffer Data Port is the current data path.

## Tool Flow

Dependencies are managed through Bender. The root `Makefile` includes
`sdhci.mk`, which in turn includes the hardware, software, and simulation
fragments.

Common entry points:

```sh
make hw
make sw
make sim
make all
make clean
make deepclean
```

`make sim` downloads the external SD card simulation model files and generates
the Questa/ModelSim compile script at `target/sim/vsim/compile.sdhci.tcl`:

```sh
make sim
cd target/sim/vsim
vsim -c -do "do compile.sdhci.tcl; quit -f"
```

The regression testbenches used for this change were:

```sh
for tb in \
  tb_dat \
  tb_dat_buffer_sizes \
  tb_reg_reset \
  tb_driver_crc \
  tb_acmd12_errorhandling \
  tb_acmd12_interrupts \
  tb_cmd_timeout \
  tb_dat_timeout \
  tb_block_read
do
  timeout 300 vsim -c "$tb" -do "run -all; quit -f"
done
```

All of the above compiled and ran with zero simulator errors in the latest
local verification run. The previously reported `tb_acmd12_interrupts` hang was
not reproduced after the register/interrupt cleanup; that test completed under
the same timeout as the rest of the suite.

## Synthesis Snapshot

The latest synthesis check used Synopsys Design Compiler with the IHP13 target
setup under `target/ihp13/synopsys` and a 10 ns `clk_i` constraint. Two wrapper
variants were synthesized:

- Minimum-size DAT buffer: `BufferNumWords = 8`,
  `AllowNoncompliantBufferSizes = 1'b1`.
- Full compliant DAT buffer: `BufferNumWords = 256`,
  `AllowNoncompliantBufferSizes = 1'b0`.

The generated reports were written under `/tmp/sdhci_syn/{minimal,compliant}`.
The local run used temporary wrapper sources and Tcl scripts in `/tmp/sdhci_syn`
to instantiate the two parameter sets without changing the checked-in RTL. The
commands were run from `target/ihp13/synopsys`:

```sh
timeout 1800 env LD_LIBRARY_PATH=/usr/lib64 \
  /usr/sepp/bin/synopsys dc_shell \
  -f /tmp/sdhci_syn/run_variant.tcl \
  -x "set argv minimal"

timeout 1800 env LD_LIBRARY_PATH=/usr/lib64 \
  /usr/sepp/bin/synopsys dc_shell \
  -f /tmp/sdhci_syn/run_variant.tcl \
  -x "set argv compliant"
```

The area results were:

| Variant | Buffer size | Cell area | Comb area | Noncomb area | Seq cells |
| --- | ---: | ---: | ---: | ---: | ---: |
| Minimum | 8 words / 32 B | 73,647.1024 | 38,914.6469 | 34,732.4555 | 1,288 |
| Full compliant | 256 words / 1024 B | 455,444.6491 | 241,100.2964 | 214,344.3527 | 9,239 |

Timing met in both synthesis runs:

| Variant | WNS | TNS | Violating paths | Worst reported path slack |
| --- | ---: | ---: | ---: | ---: |
| Minimum | 0.0000 | 0.0000 | 0 | 1.4512 ns |
| Full compliant | 0.0000 | 0.0000 | 0 | 1.3624 ns |

For the full compliant variant, the DAT buffer dominates the area. The
`i_top/i_dat_wrap/i_dat_buffer` hierarchy accounts for 396,383.9118 area units,
with 392,445.0509 area units under the SRAM implementation.
