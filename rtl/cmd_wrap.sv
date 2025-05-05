import sdhci_reg_pkg::*;
`include "common_cells/registers.svh"

module cmd_wrap (
  input   logic clk_i,
  input   logic sd_clk_i,
  input   logic rst_ni,

  input   logic sd_bus_cmd_i,
  output  logic sd_bus_cmd_o,
  output  logic sd_bus_cmd_en_o,

  input   sdhci_reg2hw_t reg2hw,

  input   logic busy_dat0_i,    //busy signal on dat0 line
  input   logic request_cmd12_i,

  // These 2 signals are updated on the sd clock edge
  output  logic sd_cmd_done_o,
  output  logic sd_rsp_done_o,

  output  logic [31:0] hw2reg_response0_d, //hook up to hw2reg.response0.d etc.
  output  logic [31:0] hw2reg_response1_d,
  output  logic [31:0] hw2reg_response2_d,
  output  logic [31:0] hw2reg_response3_d,
  output  logic hw2reg_response0_de,
  output  logic hw2reg_response1_de,
  output  logic hw2reg_response2_de,
  output  logic hw2reg_response3_de,

  output  logic hw2reg_present_state_command_inhibit_cmd_d,
  output  logic hw2reg_present_state_command_inhibit_cmd_de,

  output  logic hw2reg_error_interrupt_status_command_end_bit_error_d,
  output  logic hw2reg_error_interrupt_status_command_end_bit_error_de,
  output  logic hw2reg_error_interrupt_status_command_crc_error_d,
  output  logic hw2reg_error_interrupt_status_command_crc_error_de,
  output  logic hw2reg_error_interrupt_status_command_index_error_d,
  output  logic hw2reg_error_interrupt_status_command_index_error_de,
  output  logic hw2reg_error_interrupt_status_command_timeout_error_d,
  output  logic hw2reg_error_interrupt_status_command_timeout_error_de
);
  //cmd sequence state machine
  typedef enum logic  [2:0] { //more states for timeout detection?
    READY,
    WRITE_CMD,
    BUS_SWITCH, //wait 2 clock cycles before listening for Response
    READ_RSP,
    READ_RSP_BUSY,  //read response with busy signalling on dat0 line
    RSP_RECEIVED, //wait for N_RC=8 clock cylces before allowing next command 
    ERROR         //for simulation
  } cmd_seq_state_e;
  
  logic [5:0] cnt;
  logic cnt_en, cnt_clr;  //for N_rc (for now)

  cmd_seq_state_e cmd_seq_state_d, cmd_seq_state_q;
      
  always_comb begin : cmd_sequence_next_state
    cmd_seq_state_d = cmd_seq_state_q;

    unique case (cmd_seq_state_q)
      READY:          cmd_seq_state_d = (start_tx_q) ?  WRITE_CMD : READY;

      WRITE_CMD:      begin
        cmd_seq_state_d = WRITE_CMD;
        if (tx_done) begin  //possibly unstable, observe!
          cmd_seq_state_d = (reg2hw.command.response_type_select.q == 2'b00) ? RSP_RECEIVED : BUS_SWITCH;
        end
      end
      BUS_SWITCH:     cmd_seq_state_d = (reg2hw.command.response_type_select == 2'b11) ?  READ_RSP_BUSY : READ_RSP;

      READ_RSP:       cmd_seq_state_d = (rsp_valid) ? RSP_RECEIVED : READ_RSP;

      READ_RSP_BUSY:  cmd_seq_state_d = (rsp_valid & ~busy_dat0_i) ? RSP_RECEIVED  : READ_RSP_BUSY;
      
      RSP_RECEIVED:   cmd_seq_state_d = (cnt == 3'd7) ? READY : RSP_RECEIVED;

      ERROR: ;
      
      default:        cmd_seq_state_d = ERROR;
    endcase
  end

  `FF (cmd_seq_state_q, cmd_seq_state_d, READY, sd_clk_i, rst_ni);

  logic check_end_bit_err, check_crc_err, check_index_err;
  
  assign check_end_bit_err  = reg2hw.error_interrupt_status_enable.command_end_bit_error_status_enable.q;
  assign check_crc_err  = reg2hw.error_interrupt_status_enable.command_crc_error_status_enable.q & reg2hw.command.command_crc_check_enable.q;
  assign check_index_err  = reg2hw.error_interrupt_status_enable.command_index_error_status_enable.q & reg2hw.command.command_index_check_enable.q;

  always_comb begin : cmd_seq_ctrl
    start_listening = 1'b0;
    cnt_en  = 1'b0;
    cnt_clr = 1'b1;
    hw2reg_present_state_command_inhibit_cmd_d  = 1'b1;
    hw2reg_present_state_command_inhibit_cmd_de = 1'b0;
    hw2reg_error_interrupt_status_command_end_bit_error_d = 1'b1;
    hw2reg_error_interrupt_status_command_end_bit_error_de = 1'b0;
    hw2reg_error_interrupt_status_command_crc_error_d = 1'b1;
    hw2reg_error_interrupt_status_command_crc_error_de = 1'b0;
    hw2reg_error_interrupt_status_command_index_error_d = 1'b1;
    hw2reg_error_interrupt_status_command_index_error_de  = 1'b0;
    hw2reg_error_interrupt_status_command_timeout_error_d = 1'b1;
    hw2reg_error_interrupt_status_command_timeout_error_de = 1'b0;

    sd_rsp_done_o = 1'b0;
    sd_cmd_done_o = 1'b0;

    unique case (cmd_seq_state_q)
      READY:;   

      WRITE_CMD: if (!running_cmd12_d) hw2reg_present_state_command_inhibit_cmd_de = 1'b1;

      BUS_SWITCH:     begin
        sd_cmd_done_o   = 1'b1;
        start_listening =  1'b1;
      end
      
      READ_RSP:       begin
        cnt_en  = 1'b1;
        cnt_clr = receiving;  //reset counter when we are receiving

        if  (cnt >= 62) hw2reg_error_interrupt_status_command_timeout_error_de = 1'b1;  //timeout interrupt if resonse didn't start within 64 clock cycles

        if (rsp_valid) begin
          hw2reg_error_interrupt_status_command_end_bit_error_de = (check_end_bit_err & end_bit_err);
          hw2reg_error_interrupt_status_command_crc_error_de = (check_crc_err & ~crc_corr);
          hw2reg_error_interrupt_status_command_index_error_de = (check_index_err & index_err);
        end
      end

      READ_RSP_BUSY:  begin
        cnt_en  = 1'b1;
        cnt_clr = receiving;  //reset counter when we are receiving

        if  (cnt >= 62) hw2reg_error_interrupt_status_command_timeout_error_de = 1'b1;  //timeout interrupt if resonse didn't start within 64 clock cycles
        
        if(rsp_valid) begin
          hw2reg_error_interrupt_status_command_end_bit_error_de = (check_end_bit_err & end_bit_err);
          hw2reg_error_interrupt_status_command_crc_error_de = (check_crc_err & ~crc_corr);
          hw2reg_error_interrupt_status_command_index_error_de = (check_index_err & index_err);
        end
      end

      RSP_RECEIVED:   begin
        cnt_en        = 1'b1;
        cnt_clr       = 1'b0;
        sd_rsp_done_o = 1'b1;
        if (cnt == 6'd7) begin
          hw2reg_present_state_command_inhibit_cmd_d  = 1'b0;
          hw2reg_present_state_command_inhibit_cmd_de = 1'b1;
        end
      end

      ERROR: ;
    endcase

    if (!rst_ni) begin  : cmd_soft_reset
      hw2reg_present_state_command_inhibit_cmd_d = 1'b0;
      hw2reg_present_state_command_inhibit_cmd_de = 1'b1;
    end 
  end

  //cmd phase assignment
  logic cmd_phase_d, cmd_phase_q;
  always_comb begin : cmd_phase_assignment
    cmd_phase_d = cmd_phase_q;

    if (cmd_seq_state_q != WRITE_CMD) begin
      cmd_phase_d = ~reg2hw.host_control.high_speed_enable.q; 
    end 
  end
  `FF (cmd_phase_q, cmd_phase_d, 1'b1, sd_clk_i, rst_ni);

  logic tx_done;

  // TODO only reset this once command is done, not when its stats
  logic running_cmd12_q, running_cmd12_d;
  `FF (running_cmd12_q, running_cmd12_d, '0, sd_clk_i, rst_ni);

  logic cmd12_requested_q, cmd12_requested_d;
  `FF (cmd12_requested_q, cmd12_requested_d, '0, clk_i, rst_ni);

  logic driver_cmd_requested_q, driver_cmd_requested_d;
  `FF (driver_cmd_requested_q, driver_cmd_requested_d, '0, clk_i, rst_ni);

  logic start_tx_q, start_tx_d;
  `FF (start_tx_q, start_tx_d, 1'b0, clk_i, rst_ni);

  logic [5:0] command_index;
  assign command_index = running_cmd12_q ? 6'd12 : reg2hw.command.command_index.q;

  always_comb begin : start_tx_cdc  //assumes clock edges are simultaneous
    // write to command index starts transmission
    // extend pulse for slower sd clock
    driver_cmd_requested_d = driver_cmd_requested_q | reg2hw.command.command_index.qe;
    cmd12_requested_d      = cmd12_requested_q      | request_cmd12_i;

    start_tx_d      = '0;
    running_cmd12_d = running_cmd12_q;

    if (cmd_seq_state_q == READY) begin
      running_cmd12_d = '0;
      if (cmd12_requested_q) begin
        start_tx_d      = '1;
        running_cmd12_d = '1;
      end else if (driver_cmd_requested_q) begin
        start_tx_d      = '1;
      end
    end else if (start_tx_q) begin
      if (cmd12_requested_q) begin
        cmd12_requested_d = '0;
      end else if (driver_cmd_requested_q) begin
        driver_cmd_requested_d = '0;
      end
    end
  end


  cmd_write i_cmd_write (
    .sd_freq_clk_i  (sd_clk_i),
    .rst_ni         (rst_ni),
    .cmd_o          (sd_bus_cmd_o),
    .cmd_en_o       (sd_bus_cmd_en_o),
    .start_tx_i     (start_tx_q), //need to buffer when registers run faster than sd cmd_write
    .cmd_argument_i (running_cmd12_q ? '0 : reg2hw.argument.q),
    .cmd_nr_i       (command_index),
    .cmd_phase_i    (cmd_phase_d),
    .tx_done_o      (tx_done)
  );

  logic [31:0] rsp_0, rsp_1, rsp_2, rsp_3;
  logic [119:0] rsp;
  logic receiving, rsp_valid, end_bit_err, crc_corr, long_rsp, start_listening;

  assign long_rsp = (reg2hw.command.response_type_select == 2'b01); //response type is "Response Length 136"

  rsp_read  i_rsp_read (
    .sd_clk_i           (sd_clk_i),
    .rst_ni             (rst_ni),
    .cmd_i              (sd_bus_cmd_i),
    .long_rsp_i         (long_rsp),
    .start_listening_i  (start_listening),
    .receiving_o        (receiving),
    .rsp_valid_o        (rsp_valid),
    .end_bit_err_o      (end_bit_err),
    .rsp_o              (rsp),
    .crc_corr_o         (crc_corr)
  );


  logic update_rsp_reg, index_err;

  always_comb begin : rsp_assignment

    rsp_0 = reg2hw.response0.q;
    rsp_1 = reg2hw.response1.q;
    rsp_2 = reg2hw.response2.q;
    rsp_3 = reg2hw.response3.q;
    update_rsp_reg  = 1'b0; //only update response register when there was a response

    //TODO: integrate auto cmd12 response written to rsp_4
    unique case (reg2hw.command.response_type_select.q)
      2'b00:;      //no response

      2'b01:  begin //long response
        rsp_0 = rsp [31:0];
        rsp_1 = rsp [63:32];
        rsp_2 = rsp [95:64];
        rsp_3 [23:0]  = rsp [119:96]; //save bits 31:24 of rsp_3
        update_rsp_reg = 1'b1;
      end 

      2'b10:  begin //short response without busy signalling
        rsp_0 = rsp [31:0];
        update_rsp_reg = 1'b1;
      end

      2'b11:  begin //short response with busy signalling
        rsp_0 = rsp [31:0];
        update_rsp_reg = 1'b1;
      end

      default:; 
    endcase

    hw2reg_response0_d  = rsp_0;
    hw2reg_response1_d  = rsp_1;
    hw2reg_response2_d  = rsp_2;
    hw2reg_response3_d  = rsp_3;

    hw2reg_response0_de = (update_rsp_reg & rsp_valid);
    hw2reg_response1_de = (update_rsp_reg & rsp_valid);
    hw2reg_response2_de = (update_rsp_reg & rsp_valid);
    hw2reg_response3_de = (update_rsp_reg & rsp_valid);
  end 

  assign index_err = (rsp [37:32] != command_index);

  counter #(
    .WIDTH            (3'd6), //6 bit counter 
    .STICKY_OVERFLOW  (1'b0)  //overflow not needed
  ) i_counter (
    .clk_i      (sd_clk_i),
    .rst_ni     (rst_ni),
    .clear_i    (cnt_clr),  //clears to 0
    .en_i       (cnt_en),
    .load_i     (1'b0), //always start at 0, no loading needed
    .down_i     (1'b0), //count up
    .d_i        (6'b0), //not needed
    .q_o        (cnt),  
    .overflow_o ()  //overflow not needed
  );


  
endmodule