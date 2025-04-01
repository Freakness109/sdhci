//CRC7 calculation from serial data stream, parallel output
//output is valid 1st cycle after end_output_i is asserted to cycle where start_i is asserted
//start_i must be asserted 1 clock cycle before first input bit should be considered

//Untested!
module crc7_read (
  input   logic       sd_clk_i,
  input   logic       rst_ni,
      
  input   logic       start_i,  //start considering input next clock cycle
  input   logic       end_output_i, //stop consider input and output result next cycle

  input   logic       rsp_ser_i,  //from CMD line
  output  logic [6:0] crc7_o  //result parallel out
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
      
      OUTPUT:    crc_state_d = (start_i)  ?  START : OUTPUT;
    
      START:     crc_state_d = CALCULATE;

      CALCULATE: crc_state_d = (end_output_i) ? OUTPUT  : CALCULATE;

      default:   crc_state_d = ERROR;
    endcase
  end

  `FF (crc_state_q, crc_state_d, OUTPUT, sd_clk_i, rst_ni);

  //data path///////////////////////////////////////////////////////////////////////////////

  logic [2:0] lower_3_d, lower_3_q; //lower 3 bits lsb of crc
  logic [3:0] upper_4_d, upper_4_q; //upper 4 msb bits of crc
  logic int_rst_n, rst_n, dat_i_xor_out;

  always_comb begin : crc_data_path
    lower_3_d = lower_3_q;
    upper_4_d = upper_4_q;
    
    int_rst_n       = 1'b1;
    dat_i_xor_out   = 1'b0;
    crc7_o          = 7'b0; //avoid many switching gates down the line during calculation

    unique case (crc_state_q)
      
      OUTPUT:     begin
        crc7_o  [6:3] = upper_4_q;
        crc7_o  [2:0] = lower_3_q;  
      end

      START:    int_rst_n = 1'b0; //reset contents to zero

      CALCULATE:  begin
        dat_i_xor_out   = (rsp_ser_i ^ upper_4_q[3]);
        lower_3_d [2:1] = lower_3_q [1:0];
        lower_3_d [0]   = dat_i_xor_out;
        upper_4_d [3:1] = upper_4_q [2:0];
        upper_4_d [0]   = (lower_3_q[2] ^ dat_i_xor_out);
      end

      default: ;
    endcase
  end

  assign  rst_n = (rst_ni & int_rst_n); //only for data, not for state

  `FF (lower_3_q, lower_3_d, 3'b0, sd_clk_i, rst_n);
  `FF (upper_4_q, upper_4_d, 4'b0, sd_clk_i, rst_n);

endmodule