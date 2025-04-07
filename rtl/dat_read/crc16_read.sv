`include "common_cells/registers.svh"

module crc16_read (
  input   logic   sd_clk_i,
  input   logic   rst_ni,

  input   logic   start_i,
  input   logic   end_output_i,

  input   logic   dat_ser_i,
  output  logic [15:0]  crc16_o
);
  //state transition/////////////////////////////////////////////////////////////////////////

  typedef enum logic  [1:0] { 
    OUTPUT, 
    START,  
    CALCULATE,  
    ERROR //only for simulation 
  } crc_state_e;  
  crc_state_e crc_state_q, crc_state_d; 

  always_comb begin : crc_state_transition  
    crc_state_d = crc_state_q;  

    unique case (crc_state_q) 

      OUTPUT:    crc_state_d = (start_i)  ?  START : OUTPUT ;

      START:     crc_state_d = CALCULATE; 

      CALCULATE: crc_state_d = (end_output_i) ? OUTPUT  : C ALCULATE;

      default:   crc_state_d = ERROR; 
    endcase 
  end 

  `FF (crc_state_q, crc_state_d, OUTPUT, sd_clk_i, rst_ni); 

  //data path//////////////////////////////////////////////////////////////////////////////

  logic [4:0] lower_5_d,  lower_5_q;
  logic [6:0] middle_7_d, middle_7_q;
  logic [4:0] upper_4_d,  upper_4_q;
  logic int_rst_n, dat_i_xor_out;

  always_comb begin : crc_data_path
    lower_5_d   = lower_5_q;
    middle_7_d  = middle_7_q;
    upper_4_d   = upper_4_q;
    
    int_rst_n       = 1'b1;
    dat_i_xor_out   = 1'b0;
    crc16_o         = 16'b0; //avoid many switching gates down the line during calculation

    unique case (crc_state_q)
      
      OUTPUT:     begin
        crc16_o [15:12] = upper_4_q;
        crc16_o [11:5]  = middle_7_q;
        crc16_o [4:0]   = lower_5_q;
      end

      START:    int_rst_n = 1'b0; //reset contents to zero

      CALCULATE:  begin
        dat_i_xor_out     = (rsp_ser_i ^ upper_4_q[3]);
        lower_5_d [4:1]   = lower_5_q [3:0];
        lower_5_d [0]     = dat_i_xor_out;
        middle_7_d  [6:1] = middle_7_q  [5:0];
        middle_7_d  [0]   = (lower_5_d[4] ^ dat_i_xor_out);
        upper_4_d [3:1]   = upper_4_q [2:0];
        upper_4_d [0]     = (middle_7_d[6] ^ dat_i_xor_out);
      end

      default: ;
    endcase
  end

  assign  rst_n = (rst_ni & int_rst_n);

  `FF (lower_5_q, lower_5_d, 5'b0, sd_clk_i, rst_n);
  `FF (middle_7_q, middle_7_d, 7'b0, sd_clk_i, rst_n);
  `FF (upper_4_q, upper_4_d, 4'b0, sd_clk_i, rst_n);
endmodule