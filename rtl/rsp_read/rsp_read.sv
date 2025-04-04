//Handles reception of responses on CMD line

`include "common_cells/registers.svh"

//Untested!
module rsp_read (
  input logic sd_clk_i,         //should be synchronous with clk line of Sd card
  input logic rst_ni,
  
  input logic long_rsp_i,        //high if response is of type R2 (136 bit)
  input logic start_listening_i,  //should be asserted 2nd cycle after end bit of CMD
  
  output  logic rsp_valid_o,     //write response, end_bit_err and crc_corr to register
  output  logic end_bit_err_o,    //valid at the same time as response
  output  logic [126:0] rsp_o,   //without start, transmission, reserved and end bits
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
      
      INACTIVE:           rx_state_d  = (start_listening_i) ? INACTIVE  : WAIT_FOR_START_BIT;
      
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

  logic start_bit_observed, all_bits_received;

  logic shift_reg_shift_in_en, shift_reg_par_output_en;
  
  logic crc_start, crc_end_output;
  logic [6:0] crc7_calc;

  logic cnt_clear, cnt_en;
  logic [7:0] bit_cnt;

  logic [8:0] shift_start_cnt, crc_start_cnt, done_cnt;

  assign shift_start_cnt= (long_rsp_i)  ? 8'd7    : 8'd2;      //should be right
  assign crc_start_cnt  = (long_rsp_i)  ? 8'd126  : 8'd38;     //could be wrong
  assign done_cnt       = (long_rsp_i)  ? 8'd134  : 8'd46;     //could be wrong

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


    unique case (rx_state_q)
      
      INACTIVE:           begin
        //?
      end
      
      WAIT_FOR_START_BIT: start_bit_observed  = (~rsp_ser) ? SHIFT_IN : WAIT_FOR_START_BIT;

      SHIFT_IN:           begin
        cnt_clear = 1'b0;
        cnt_en    = 1'b1;
        
        if  (bit_cnt >= shift_start_cnt) shift_reg_shift_in_en = 1'b1;

        if  (bit_cnt == crc_start_cnt)    crc_start = 1'b1;

        if  (bit_cnt >= done_cnt) begin
          cnt_en                  = 1'b0;
          all_bits_received       = 1'b1;
          crc_end_output          = 1'b1;
          shift_reg_shift_in_en   = 1'b0;
          shift_reg_par_output_en = 1'b1;
        end
      end

      FINISHED:           begin
        shift_reg_par_output_en = 1'b1;
        rsp_valid_o             = 1'b1;
        
        crc_corr_o    = (crc7_calc == rsp_o[6:0]) ? 1'b1  : 1'b0;
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
    .dat_par_o        (rsp_o)
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

  sd_bus_cmd_receiver i_sd_bus_cmd_receiver (
    .cmd_o  (rsp_ser)
  );
endmodule