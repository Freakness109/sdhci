//Handles reception of responses on CMD line

`include "common_cells/registers.svh"

//Untested!
module rsp_read (
  input logic sd_clk_i,         //should be synchronous with clk line of Sd card
  input logic rst_ni,
  input logic cmd_i, 

  input logic long_rsp_i,        //high if response is of type R2 (136 bit)
  input logic start_listening_i,  //should be asserted 2nd cycle after end bit of CMD
  
  output  logic receiving_o,       //start bit was observed
  output  logic rsp_valid_o,     //write response, end_bit_err and crc_corr to register
  output  logic end_bit_err_o,    //valid at the same time as response
  output  logic [119:0] rsp_o,   //without start, transmission, reserved, crc and end bits
  output  logic crc_corr_o       //active if crc7 was correct, valid when rsp_valid_o is active
);
  //state transition
  typedef enum logic  [2:0] { 
    INACTIVE,
    WAIT_FOR_START_BIT,
    SHIFT_IN,
    FINISHED,
    FORMAT_ERROR, //unused for now
    ERROR
  } rx_state_e;
  rx_state_e rx_state_d, rx_state_q;

  always_comb begin : rsp_state_transition
    rx_state_d  = rx_state_q;

    unique case (rx_state_q)
      
      INACTIVE:           rx_state_d  = (start_listening_i) ? WAIT_FOR_START_BIT  : INACTIVE;
      
      WAIT_FOR_START_BIT: rx_state_d  = (start_bit_observed)? SHIFT_IN  : WAIT_FOR_START_BIT;

      SHIFT_IN:           rx_state_d  = (all_bits_received) ? FINISHED  : SHIFT_IN;

      FINISHED:           rx_state_d  = INACTIVE;

      FORMAT_ERROR:       rx_state_d  = INACTIVE;

      default:            rx_state_d  = ERROR;
    endcase
  end

  `FF (rx_state_q, rx_state_d, INACTIVE, sd_clk_i, rst_ni);

  //data path
  logic rsp_ser;
  assign rsp_ser = cmd_i;

  logic start_bit_observed, all_bits_received;

  logic shift_reg_shift_in_en, shift_reg_par_output_en;
  
  logic crc_start, crc_end_output;
  logic [6:0] crc7_calc;

  logic cnt_clear, cnt_en;
  logic [7:0] bit_cnt;

  logic [8:0] shift_start_cnt, crc_done_cnt, done_cnt;
  logic [126:0] rsp_with_crc7;

  assign shift_start_cnt= (long_rsp_i)  ? 8'd7    : 8'd1;      
  assign crc_done_cnt  = (long_rsp_i)  ? 8'd126  : 8'd38;     //long could be wrong
  assign done_cnt       = (long_rsp_i)  ? 8'd134  : 8'd46;     //long could be wrong
  assign rsp_o  = rsp_with_crc7 [126:7];
  always_comb begin : rsp_data_path
    start_bit_observed      = 1'b0;
    all_bits_received       = 1'b0;
    shift_reg_shift_in_en   = 1'b0;
    shift_reg_par_output_en = 1'b0;
    crc_start               = 1'b0;
    crc_end_output          = 1'b0;
    crc_corr_o              = 1'b0;
    cnt_clear               = 1'b1;
    cnt_en                  = 1'b0;
    end_bit_err_o           = 1'b1;
    rsp_valid_o             = 1'b0;
    receiving_o             = 1'b0;


    unique case (rx_state_q)
      
      INACTIVE:           begin
        //?
      end
      
      WAIT_FOR_START_BIT: begin 
        start_bit_observed  = ~rsp_ser;
        if(~long_rsp_i) crc_start = ~rsp_ser; //start crc for short response
      end
      SHIFT_IN:           begin
        cnt_clear = 1'b0;
        cnt_en    = 1'b1;
        receiving_o = 1'b1;
        if(bit_cnt >= 8'd4) crc_start = 1'b1; //start crc for long response, check!

        if  (bit_cnt >= shift_start_cnt) begin
          shift_reg_shift_in_en = 1'b1;
        end

        if(bit_cnt >= crc_done_cnt) begin 
          crc_start      =  1'b0;
          crc_end_output =  1'b1;
        end

        if  (bit_cnt >= done_cnt) begin
          cnt_en                  = 1'b0;
          all_bits_received       = 1'b1;
          shift_reg_shift_in_en   = 1'b0;
          shift_reg_par_output_en = 1'b1;
        end
      end

      FINISHED:           begin
        shift_reg_par_output_en = 1'b1;
        rsp_valid_o             = 1'b1;
        receiving_o             = 1'b1;

        crc_corr_o    = (crc7_calc == rsp_with_crc7[6:0]) ? 1'b1  : 1'b0;
        end_bit_err_o = ~rsp_ser;
      end

      FORMAT_ERROR:;

      default: ;
    endcase
  end


  

  ser_par_shift_reg #(
    .NumBits    (127), //r2 response, start, transmission, reserved and end bits not needed 
    .MaskOutput (1)    //to avoid large number of gates switching during shifting
  ) i_rsp_shift_reg (
    .clk_i            (sd_clk_i),
    .rst_ni           (rst_ni),
    .shift_in_en_i    (shift_reg_shift_in_en),
    .par_output_en_i  (shift_reg_par_output_en),
    .dat_ser_i        (rsp_ser),
    .dat_par_o        (rsp_with_crc7)
  );

  crc7_read i_crc7_read (
    .sd_clk_i     (sd_clk_i),
    .rst_ni       (rst_ni),
    .start_i      (crc_start),
    .end_output_i (crc_end_output),
    .rsp_ser_i    (rsp_ser),
    .crc7_o       (crc7_calc)
  );

  counter #(
    .WIDTH            (8), //longest response is 136 bits
    .STICKY_OVERFLOW  (1)
  ) i_rsp_counter (
    .clk_i      (sd_clk_i),
    .rst_ni     (rst_ni),
    .clear_i    (cnt_clear),
    .en_i       (cnt_en),
    .load_i     (1'b0),
    .down_i     (1'b0),
    .d_i        (8'b0),
    .q_o        (bit_cnt),
    .overflow_o ()
  );
endmodule