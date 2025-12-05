// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Micha Wehrli <miwehrli@student.ethz.ch>

`include "obi/typedef.svh"

module tb_acmd12 #(
    parameter time         ClkPeriod     = 50ns,
    parameter int unsigned RstCycles     = 1
  )();
  logic clk, rst_n;

  clk_rst_gen #(
    .ClkPeriod    ( ClkPeriod ),
    .RstClkCycles ( RstCycles )
  ) i_clk_rst_sys (
    .clk_o  ( clk   ),
    .rst_no ( rst_n )
  );

  localparam obi_pkg::obi_cfg_t sdhci_obi_cfg = obi_pkg::obi_default_cfg(32, 32, 1, '0);
  `OBI_TYPEDEF_DEFAULT_ALL(sdhci_obi, sdhci_obi_cfg);

  sdhci_obi_req_t obi_req;
  sdhci_obi_rsp_t obi_rsp;

  logic sdhc_dat_en, sdhc_cmd_en, sdhc_cmd, tb_cmd;
  logic [3:0] sdhc_dat, tb_dat;

  sdhci_top_obi #(
      .ObiCfg           (sdhci_obi_cfg),
      .obi_req_t        (sdhci_obi_req_t),
      .obi_rsp_t        (sdhci_obi_rsp_t),
      .ClkPreDivLog     (0),
      .NumDebounceCycles(2)
  ) i_sdhci_top (
      .clk_i  (clk),
      .rst_ni (rst_n),

      .obi_req_i (obi_req),
      .obi_rsp_o (obi_rsp),
      .sd_clk_o  (),
      .sd_cd_ni  (1'b0),

      .sd_cmd_i    (tb_cmd     ),
      .sd_cmd_o    (sdhc_cmd   ),
      .sd_cmd_en_o (sdhc_cmd_en),

      .sd_dat_i    (tb_dat     ),
      .sd_dat_o    (sdhc_dat   ),
      .sd_dat_en_o (sdhc_dat_en),

      .interrupt_o ()
  );

  int ClkEnPeriod;

  task automatic send_response_48(
      input logic [5:0] index,
      input logic [6:0] crc
  );
    tb_cmd = '0; // start_bit
    repeat (ClkEnPeriod) @(negedge clk);
    tb_cmd = '0; // direction bit
    repeat (ClkEnPeriod) @(negedge clk);

    // index
    for (int i = 0; i < 6; i++) begin
      tb_cmd = index[5-i];
      repeat (ClkEnPeriod) @(negedge clk);
    end

    // data
    tb_cmd = '0;
    repeat (32 * ClkEnPeriod) @(negedge clk);

    // crc
    for (int i = 0; i < 7; i++) begin
      tb_cmd = crc[6-i];
      repeat (ClkEnPeriod) @(negedge clk);
    end

    tb_cmd = '1;
  endtask



  // < 0 cmd12 gets delayed due to our command
  // = 0 both requests arrive at the same time, cmd12 goes first
  // > 0 our command gets delayed by cmd12
  int CyclesThatDriverCommandArrivesBeforeCMD12;
  int IsFirstResponseValid;

  logic AutoCMD12First;
  logic [15:0] error_status, cmd12_error_status;

  initial begin
    $timeformat(-9, 0, "ns", 12);
    $dumpfile("tb_acmd12.vcd");
    $dumpvars(0);

    if (!$value$plusargs("CyclesThatDriverCommandArrivesBeforeCMD12=%d", CyclesThatDriverCommandArrivesBeforeCMD12)) begin
      CyclesThatDriverCommandArrivesBeforeCMD12 = 0;
    end
    if (!$value$plusargs("IsFirstResponseValid=%d", IsFirstResponseValid)) begin
      IsFirstResponseValid = 0;
    end
    if (!$value$plusargs("ClkEnPeriod=%d", ClkEnPeriod)) begin
      ClkEnPeriod = 4;
    end

    AutoCMD12First = CyclesThatDriverCommandArrivesBeforeCMD12 <= 0;

    $display("Testing auto cmd12 with CyclesThatDriverCommandArrivesBeforeCMD12=%d, IsFirstResponseValid=%d, ClkEnPeriod=%d", CyclesThatDriverCommandArrivesBeforeCMD12, IsFirstResponseValid, ClkEnPeriod);

    obi_req = '0;
    obi_req.a.we    = '1;
    obi_req.a.aid   = '0;

    tb_cmd  = '1;
    tb_dat  = '1;

    repeat(5) @(negedge clk);

    // Enable error status
    obi_req.req     = '1;
    obi_req.a.addr  = 'h034;
    obi_req.a.be    = 'b1111;
    obi_req.a.wdata = 'hFFFF_FFFF; // TODO currently we need to set this for acmd12 to work, change it?
    @(negedge clk);

    // Set Clock frequency
    obi_req.a.addr  = 'h02C;
    obi_req.a.be    = 'b0011;
    obi_req.a.wdata = { 16'b0, 8'(ClkEnPeriod >> 1), 8'h0 };
    @(negedge clk);
    // turn on clock
    obi_req.a.addr  = 'h02C;
    obi_req.a.be    = 'b0011;
    obi_req.a.wdata = 'h04;
    @(negedge clk);

    // Set multi block + write + ACMD12
    obi_req.a.addr  = 'h00C;
    obi_req.a.be    = 'b0011;
    obi_req.a.wdata = 'b100110;
    @(negedge clk);

    // Set to one block of 64 bytes
    obi_req.a.addr  = 'h004;
    obi_req.a.be    = 'b1111;
    obi_req.a.wdata = 'h0001_0040;
    @(negedge clk);

    // Dispatch command (no response + data present)
    obi_req.a.addr  = 'h00C;
    obi_req.a.be    = 'b1100;
    obi_req.a.wdata = ('b100000) << 16;
    @(negedge clk);

    obi_req.req     = '0;

    repeat(10*ClkEnPeriod) @(negedge clk);
    repeat (64 / 4) begin
      obi_req.req     = '1;
      obi_req.a.addr  = 'h020;
      obi_req.a.be    = 'b1111;
      obi_req.a.wdata = 'hDEAD_BEEF;
      @(negedge clk);
      obi_req.req     = '0;
      repeat(ClkEnPeriod - 1) @(negedge clk);
    end

    obi_req.req = '0;

    // These values are slightly random because of the offset between command start and sd clk period
    case (ClkEnPeriod)
      1: repeat(541 - CyclesThatDriverCommandArrivesBeforeCMD12) @(negedge clk);
      2: repeat(1079 - CyclesThatDriverCommandArrivesBeforeCMD12) @(negedge clk);
      4: repeat(2158 - CyclesThatDriverCommandArrivesBeforeCMD12) @(negedge clk);
      default: $fatal("ClkEnPeriod not supported");
    endcase

    // Dispatch command (cmd0 + 48bit response + no data)
    obi_req.req     = '1;
    obi_req.a.addr  = 'h00C;
    obi_req.a.be    = 'b1100;
    obi_req.a.wdata = ('b0_00011010) << 16;
    @(negedge clk);
    obi_req.req     = '0;
    repeat(ClkEnPeriod - 1) @(negedge clk);
    obi_req.req = '0;

    repeat(80*ClkEnPeriod) @(negedge clk);

    if (IsFirstResponseValid) begin
      // valid response, next command should run
      if (AutoCMD12First)
        send_response_48(12, 'h7A);
      else
        send_response_48(0, '0);
    end else
      // invalid response, next command should not run
      send_response_48('1, '1);

    if (IsFirstResponseValid) begin
      repeat(80*ClkEnPeriod) @(negedge clk);

      // Valid response for the second command
      if (AutoCMD12First)
        send_response_48(0, '0);
      else
        send_response_48(12, 'h7A);
    end else begin
      repeat (80*ClkEnPeriod) begin
        if (!sdhc_cmd) $fatal("Second command should not have been sent");
        @(negedge clk);
      end
    end

    repeat(10*ClkEnPeriod) @(negedge clk);

    // Read out error register
    obi_req.req     = '1;
    obi_req.a.we      = '0;
    obi_req.a.addr  = 'h030;
    obi_req.a.be    = 'b1100;

    @(negedge clk);
    error_status = obi_rsp.r.rdata[31:16];
    error_status[15:4] = '0; // Only care about cmd errors

    obi_req.a.addr  = 'h03C;
    obi_req.a.be    = 'b0011;

    @(negedge clk);
    cmd12_error_status = obi_rsp.r.rdata;

    obi_req.req = '0;

    // leave some time so we get a cleaner waveform
    repeat(10) @(negedge clk);

    if (IsFirstResponseValid) begin
      if (|(error_status)) begin
        $error("Got an error when we shouldnt have 0x%h", error_status);
        $fatal();
      end
      if (|(cmd12_error_status)) begin
        $error("Got a cmd12 error when we shouldnt have 0x%h", cmd12_error_status);
        $fatal();
      end
    end else begin
      if (AutoCMD12First) begin
        if (|(error_status)) begin
          $error("Got an error when we shouldnt have 0x%h", error_status);
          $fatal();
        end
        if (cmd12_error_status != /* command not issues by acmd12 error + crc error + index error */ 'b1001_0100) begin
          $error("Got a cmd12 error when we shouldnt have 0x%h", cmd12_error_status);
          $fatal();
        end
      end else begin
        if (error_status != /* crc error + index error */ 'b1010) begin
          $error("Got an error when we shouldnt have 0x%h", error_status);
          $fatal();
        end
        if (cmd12_error_status != /* command not executed */ 'b1) begin
          $error("Got a cmd12 error when we shouldnt have 0x%h", cmd12_error_status);
          $fatal();
        end
      end
    end

    $dumpflush;
    $finish();
  end

endmodule
