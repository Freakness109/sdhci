//write 512-Byte data block


module dat_write ( 
  input logic sd_clk_i,
  input logic rst_ni,

  input logic start_send_i,
  //when a stop command was issued, the end bit of the data transmission must be issued 2 cycles later than the end bit of the command
  //transmitting the end bit is done first cycle after stop_transmission_i is asserted, thus it should be asserted the cycle after the command stop bit
  input logic stop_transmission_i, 
  input logic pull_up_i,    //pass to bus driver. Should be only possible when no data is being transmitted
  input logic [31:0]  dat_i_par,

  output  logic next_word_o, //active for one cycle when next data word should be made available. Got time for 7 sd clock cycles after to provide data
  output  logic done_transmitting_o //high when card is in READY state? TODO: Might be better to set while stop bit is transmitted
);

  logic load_even, first_load_even, load_odd, shift_even, shift_odd;
  logic load, shift;
  logic [7:0] dat_in_0, dat_in_1, dat_in_2, dat_in_3; //input to shift registers
  logic dat_0_even_ser, dat_1_even_ser, dat_2_even_ser, dat_3_even_ser, dat_0_odd_ser, dat_1_odd_ser, dat_2_odd_ser, dat_3_odd_ser; //output of data shift registers
  logic dat_0, dat_1, dat_2, dat_3; //output of data shift registers combined
  logic shift_out_crc, crc_0, crc_1, crc_2, crc_3;
  logic sd_dat0, sd_dat1, sd_dat2, sd_dat3;    //hook up to sd dat lines
  logic odd_even; //1 for odd, 0 for even
  logic [10:0] count; //1024 data bits + 16 crc bits per channel
  logic count_clear, count_en;
  logic dat_done, crc_done;
  logic highZ;

  always_comb begin : input_bit_assignment  //shure hope this is right :)
    dat_in_0  = {dat_i_par[4], dat_i_par[0], dat_i_par[12], dat_i_par[8], dat_i_par[20], dat_i_par[16], dat_i_par[28], dat_i_par[24]};
    dat_in_1  = {dat_i_par[5], dat_i_par[1], dat_i_par[13], dat_i_par[9], dat_i_par[21], dat_i_par[17], dat_i_par[29], dat_i_par[25]};
    dat_in_2  = {dat_i_par[6], dat_i_par[2], dat_i_par[14], dat_i_par[10], dat_i_par[22], dat_i_par[18], dat_i_par[30], dat_i_par[26]};
    dat_in_3  = {dat_i_par[7], dat_i_par[3], dat_i_par[15], dat_i_par[11], dat_i_par[23], dat_i_par[19], dat_i_par[31], dat_i_par[27]};
  end

  //8th place bit. Since 32-bit word gets split up into 4 8-bit chunks, we need a new word every 8 clock cycles.
  //0 for 0th data word, 1 for 1st data word, 0 for 2nd etc.
  assign  odd_even  = count [3];

  //Double buffering of shift register
  assign  dat_0     = (odd_even)  ? dat_0_odd_ser : dat_0_even_ser;
  assign  dat_1     = (odd_even)  ? dat_1_odd_ser : dat_1_even_ser;
  assign  dat_2     = (odd_even)  ? dat_2_odd_ser : dat_2_even_ser;
  assign  dat_3     = (odd_even)  ? dat_3_odd_ser : dat_3_even_ser;

  //need only look at lower 5 bit of count to determine load and shift 
  assign load_even  = (odd_even & load) | first_load_even;  //to be able to load before counter starts
  assign load_odd   = (~odd_even) & load;   //load the shift register we are not currently using
  assign shift_even = (~odd_even) & shift;
  assign shift_odd  = odd_even  & shift;
  
  //state transition
  typedef enum logic [2:0] { 
    READY,
    START_BIT,
    DAT,
    CRC,
    END_BIT,
    ERROR //only for testing
  } dat_tx_state_e;

  dat_tx_state_e  dat_tx_state_d, dat_tx_state_q;

  always_comb begin : dat_write_state_transition
    dat_tx_state_d  =   dat_tx_state_q;
    
    unique case (dat_tx_state_q)

      READY:    dat_tx_state_d  = (start_send_i && !stop_transmission_i) ? START_BIT : READY;

      STAR_BIT: dat_tx_state_d  = (stop_transmission_i) ? END_BIT : DAT;

      DAT:      dat_tx_state_d  = (stop_transmission_i) ? END_BIT : ((dat_done)  ? CRC : DAT);

      CRC:      dat_tx_state_d  = (crc_done || stop_transmission_i)  ? END_BIT : CRC;

      END_BIT:  dat_tx_state_d  = READY;

      default:  dat_tx_state_d  = ERROR; 
    endcase
  end
  
  `FF (dat_tx_state_q, dat_tx_state_d, READY, sd_clk_i, rst_ni);

  //Data Path

  always_comb begin : dat_write_datapath
    sd_dat0         = 1'b1; //bus high in idle
    sd_dat1         = 1'b1;
    sd_dat2         = 1'b1;
    sd_dat3         = 1'b1;
    count_en        = 1'b0;
    shift           = 1'b0;
    load            = 1'b0;
    first_load_even = 1'b0;
    highZ           = 1'b0;
    dat_done        = 1'b0;
    crc_done        = 1'b0;
    next_word_o     = 1'b0;

    unique case (dat_tx_state_q)
      
      READY:      highZ = 1'b0;
      
      START_BIT:  begin
        count_en        = 1'b1;
        first_load_even = 1'b1; //to load even shift register before count starts

        sd_dat0 = 1'b0; //start bits
        sd_dat1 = 1'b0;
        sd_dat2 = 1'b0;
        sd_dat3 = 1'b0;

      end

      DAT:        begin
        count_en  = 1'b1;
        shift     = 1'b1;

        if (count[2:0] == 3'd7) load  = 1'b1;  //load idle shift register at last possible moment? 

        if (count[2:0] ==3'd0)  next_word_o = 1'b1;  //request next word on input bus
        
        if (count == 1023) dat_done = 1'b1; //only works for 512 Byte blocks

        sd_dat0 = dat_0;
        sd_dat1 = dat_1;
        sd_dat2 = dat_2;
        sd_dat3 = dat_3;
      end

      CRC:        begin
        count_en      = 1'b1;
        shift_out_crc = 1'b1;

        if  (count == 1039) crc_done  = 1'b1; //only works for 512 Byte blocks

        sd_dat0 = crc_0;
        sd_dat1 = crc_1;
        sd_dat2 = crc_2;
        sd_dat3 = crc_3;
      end

      END_BIT:    begin
        sd_dat0 = 1'b1; //end Bit
        sd_dat1 = 1'b1;
        sd_dat2 = 1'b1;
        sd_dat3 = 1'b1;
      end

      default: ;
    endcase
  end

  assign done_transmitting_o = (tx_state_q == READY)  ? 1'b1: 1'b0;

  //module instantiations

  //first shift register bank
  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_0_even (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_even),
    .shift_en_i     (shift_even),
    .dat_par_i      (dat_in_0),
    .dat_ser_o      (dat_0_even_ser)
  );

  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_1_even (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_even),
    .shift_en_i     (shift_even),
    .dat_par_i      (dat_in_1),
    .dat_ser_o      (dat_1_even_ser)
  );

  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_2_even (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_even),
    .shift_en_i     (shift_even),
    .dat_par_i      (dat_in_2),
    .dat_ser_o      (dat_2_even_ser)
  );

  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_3_even (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_even),
    .shift_en_i     (shift_even),
    .dat_par_i      (dat_in_3),
    .dat_ser_o      (dat_3_even_ser)
  );
  
  //second shift register bank
  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_0_odd (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_odd),
    .shift_en_i     (shift_odd),
    .dat_par_i      (dat_in_0),
    .dat_ser_o      (dat_0_odd_ser)
  );
  
  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_1_odd (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_odd),
    .shift_en_i     (shift_odd),
    .dat_par_i      (dat_in_1),
    .dat_ser_o      (dat_1_odd_ser)
  );
  
  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_2_odd (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_odd),
    .shift_en_i     (shift_odd),
    .dat_par_i      (dat_in_2),
    .dat_ser_o      (dat_2_odd_ser)
  );
  
  par_ser_shift_reg #(
    .NumBits    (8),  //32 bits of data at a time, 8 bits per channel
    .ShiftInVal (0)
  ) i_shift_reg_3_odd (
    .clk_i          (sd_clk_i),
    .rst_ni         (rst_ni),
    .par_write_en_i (load_odd),
    .shift_en_i     (shift_odd),
    .dat_par_i      (dat_in_3),
    .dat_ser_o      (dat_3_odd_ser)
  );

  //crc calculation
  crc16_write i_crc16_write_0 (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .shift_out_crc16_i  (shift_out_crc),
    .dat_ser_i          (dat_0),
    .crc_ser_o          (crc_0)
  );
  
  crc16_write i_crc16_write_1 (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .shift_out_crc16_i  (shift_out_crc),
    .dat_ser_i          (dat_1),
    .crc_ser_o          (crc_1)
  );

  crc16_write i_crc16_write_2 (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .shift_out_crc16_i  (shift_out_crc),
    .dat_ser_i          (dat_2),
    .crc_ser_o          (crc_2)
  );

  crc16_write i_crc16_write_3 (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .shift_out_crc16_i  (shift_out_crc),
    .dat_ser_i          (dat_3),
    .crc_ser_o          (crc_3)
  );

  sd_bus_dat_driver i_sd_bus_dat_driver (
    .dat0_i        (sd_dat0),
    .dat1_i        (sd_dat1),
    .dat2_i        (sd_dat2),
    .dat3_i        (sd_dat3),
    .dat_highz_i    (highZ),
    .dat0_pull_up_i ()
  );

  counter #(
    .WIDTH            (11),
    .STICKY_OVERFLOW  (0)
  ) i_bit_counter (
    .clk_i      (sd_clk_i),
    .rst_ni     (rst_ni),
    .clear_i    (cout_clear),
    .en_i       (count_start),
    .load_i     ('0),
    .down_i     ('0),
    .d_i        ('0),
    .q_o        (count),
    .overflow_o ()
  );
endmodule