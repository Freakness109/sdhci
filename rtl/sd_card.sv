module sd_card(
    input  logic       sd_clk_i,

    input  logic       cmd_en_i,
    input  logic       cmd_i,
    output logic       cmd_o,

    input  logic       dat_en_i,
    input  logic [3:0] dat_i,
    output logic [3:0] dat_o
);
`ifdef WITH_SD_MODEL
  tri1 cmd;
  assign cmd = cmd_en_i ? cmd_i : 'z;
  assign cmd_o = cmd;
  
  tri1 [3:0] dat;
  assign dat = dat_en_i ? dat_i : 'z;
  assign dat_o = dat;

  sdModel i_model (
    .sdClk (sd_clk_i),
    .cmd   (cmd),
    .dat   (dat)
  );
`else
  // TODO gpio?
  assign cmd_io = 'bz;
  assign dat_io = 'bz;
`endif
endmodule