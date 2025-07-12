`include "common_cells/registers.svh"

`define writable_reg_t(size) \
  struct packed {            \
    logic size d;            \
    logic de;                \
  }

module dat_wrap #(
  // TODO change this if we want to support 1bit buswidth
  parameter int MaxBlockBitSize = 10 // max_block_length = 512 in caps => max 1024 data + 16 crc
) (
  input  logic clk_i,
  input  logic sd_clk_i,
  input  logic rst_ni,
  
  input  logic [3:0] dat_i,
  output logic       dat_en_o,
  output logic [3:0] dat_o,

  input  logic sd_cmd_done_i,
  input  logic sd_rsp_done_i,

  input  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,

  output `writable_reg_t()       data_crc_error_o,
  output `writable_reg_t()       data_end_bit_error_o,
  output `writable_reg_t()       data_timeout_error_o,

  output logic [31:0]            buffer_data_port_d_o,
  output `writable_reg_t()       buffer_read_enable_o,
  output `writable_reg_t()       buffer_write_enable_o,

  output `writable_reg_t()       read_transfer_active_o,
  output `writable_reg_t()       write_transfer_active_o,
  output `writable_reg_t()       dat_line_active_o,

  output `writable_reg_t([15:0])       block_count_o,

  output sdhci_reg_pkg::sdhci_hw2reg_auto_cmd12_error_status_reg_t auto_cmd12_errors_o
);
  ///////////////////////////////////////////////////////////////////////////////
  //                          Synchronization Signals                          //
  ///////////////////////////////////////////////////////////////////////////////
  
  logic sd_rst_n; 

  typedef struct packed {
    logic write;
    logic read;
    logic wait_for_cmd;
    logic [MaxBlockBitSize-1:0] block_size;
  } sd_start_t;
  logic start_valid, start_ready, sd_start_valid, sd_start_ready;
  sd_start_t start, sd_start;
  cdc_2phase #(
    .T (sd_start_t)
  ) i_cdc_read_start (
    .src_rst_ni  (sd_rst_n),
    .src_clk_i   (clk_i),
    .src_data_i  (start),
    .src_valid_i (start_valid),
    .src_ready_o (start_ready),

    .dst_rst_ni  (sd_rst_n),
    .dst_clk_i   (sd_clk_i),
    .dst_data_o  (sd_start),
    .dst_valid_o (sd_start_valid),
    .dst_ready_i (sd_start_ready)
  );

  typedef struct packed {
    logic crc_err;
    logic end_bit_err;
  } sd_done_t;
  logic sd_done_valid, sd_done_ready, done_valid, done_ready;
  sd_done_t sd_done, done;
  cdc_2phase #(
    .T (sd_done_t)
  ) i_cdc_done (
    .src_rst_ni  (sd_rst_n),
    .src_clk_i   (sd_clk_i),
    .src_data_i  (sd_done),
    .src_valid_i (sd_done_valid),
    .src_ready_o (sd_done_ready),

    .dst_rst_ni  (sd_rst_n),
    .dst_clk_i   (clk_i),
    .dst_data_o  (done),
    .dst_valid_o (done_valid),
    .dst_ready_i (done_ready)
  );


  logic sd_read_valid, sd_read_ready, read_valid;
  logic [31:0] sd_read_data, read_data;
  cdc_2phase #(
    .T (logic [31:0])
  ) i_cdc_read (
    .src_rst_ni  (sd_rst_n),
    .src_clk_i   (sd_clk_i),
    .src_data_i  (sd_read_data),
    .src_valid_i (sd_read_valid),
    .src_ready_o (sd_read_ready),

    .dst_rst_ni  (sd_rst_n),
    .dst_clk_i   (clk_i),
    .dst_data_o  (read_data),
    .dst_valid_o (read_valid),
    .dst_ready_i ('1)
  );

  logic write_ready, write_valid, sd_write_ready, sd_write_valid;
  logic [31:0] write_data, sd_write_data;
  cdc_2phase #(
    .T (logic [31:0])
  ) i_cdc_write (
    .src_rst_ni  (sd_rst_n),
    .src_clk_i   (clk_i),
    .src_data_i  (write_data),
    .src_valid_i (write_valid),
    .src_ready_o (write_ready),

    .dst_rst_ni  (sd_rst_n),
    .dst_clk_i   (sd_clk_i),
    .dst_data_o  (sd_write_data),
    .dst_valid_o (sd_write_valid),
    .dst_ready_i (sd_write_ready)
  );

  ///////////////////////////////////////////////////////////////////////////////
  //                           Register Clock Domain                           //
  ///////////////////////////////////////////////////////////////////////////////

  typedef enum logic [3:0] {
    READY,

    // Read
    START_READING,
    STARTING_READING,
    READING,
    DONE_READING,
    TIMEOUT_READING,

    // Write
    START_WRITING,
    WAIT_FOR_WRITE_DATA,
    SEND_FIRST_WORD,
    WRITING,
    DONE_WRITING_BLOCK,
    DONE_WRITING
  } dat_state_e;

  dat_state_e state_q, state_d;
  `FF (state_q, state_d, READY, clk_i, rst_ni);

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      READY: begin
        if (reg2hw_i.command.command_index.qe && reg2hw_i.command.data_present_select.q) begin
          if (reg2hw_i.transfer_mode.data_transfer_direction_select.q) begin
            state_d = START_READING;
          end else begin
            state_d = START_WRITING;
          end
        end
      end

      START_READING:    state_d = STARTING_READING;
      STARTING_READING: if (start_ready) state_d = READING;
      READING: begin
        if (read_timeout) begin
          state_d = TIMEOUT_READING;
          // Reset reader
        end else if (done_valid) begin
          state_d = DONE_READING;
        end
      end
      TIMEOUT_READING: state_d = READY;
      DONE_READING:    state_d = READY;

      START_WRITING:       if (start_ready) state_d = WAIT_FOR_WRITE_DATA;
      WAIT_FOR_WRITE_DATA: if (write_reg_length * 4 >= block_size_q) state_d = SEND_FIRST_WORD;
      SEND_FIRST_WORD:     if (write_ready) state_d = WRITING;
      WRITING:             if (done_valid) state_d = DONE_WRITING_BLOCK;
      DONE_WRITING_BLOCK:  begin
        // TODO Block Count Enable and Abort Operation
        if (reg2hw_i.transfer_mode.multi_single_block_select.q && reg2hw_i.block_count.q > 16'b1) state_d = START_WRITING;
        else state_d = DONE_WRITING;
      end
      DONE_WRITING:        state_d = READY;

      default: state_d = READY;
    endcase
  end
  

  logic [MaxBlockBitSize-1:0] block_size_q, block_size_d;
  `FF (block_size_q, block_size_d, '0, clk_i, rst_ni);

  logic first_block_q, first_block_d;
  `FF (first_block_q, first_block_d, '0, clk_i, rst_ni);

  logic software_reset_dat;
  `FF(software_reset_dat, reg2hw_i.software_reset.software_reset_for_dat_line.q, '0, clk_i, rst_ni);

  logic read_run_timeout, pop_write_buffer;
  always_comb begin
    sd_rst_n = rst_ni & ~software_reset_dat;

    block_size_d  = block_size_q;
    first_block_d = first_block_q;

    start_valid        = '0;
    start.write        = '0;
    start.read         = '0;
    start.wait_for_cmd = first_block_q;
    start.block_size   = block_size_q;

    done_ready = '0;

    write_valid      = '0;
    pop_write_buffer = '0;

    read_run_timeout = '0;

    data_crc_error_o.de     = '0;
    data_crc_error_o.d      = '1;
    data_end_bit_error_o.de = '0;
    data_end_bit_error_o.d  = '1;
    data_timeout_error_o.de = '0;
    data_timeout_error_o.d  = '1;

    read_transfer_active_o.de  = '0;
    read_transfer_active_o.d   = 'X;
    write_transfer_active_o.de = '0;
    write_transfer_active_o.d  = 'X;
    dat_line_active_o.de       = '0;
    dat_line_active_o.d        = 'X;

    block_count_o.de = '0;
    block_count_o.d  = 'X;

    buffer_write_enable_o.de = '0;
    buffer_write_enable_o.d  = 'X;
    
    unique case (state_q)
      READY: begin
        block_size_d = MaxBlockBitSize'(reg2hw_i.block_size.transfer_block_size.q);
        first_block_d = '1;

        dat_line_active_o.de       = '1;
        dat_line_active_o.d        = '0;
      end
      START_READING: begin
        dat_line_active_o.de      = '1;
        dat_line_active_o.d       = '1;
        read_transfer_active_o.de = '1;
        read_transfer_active_o.d  = '1;

        start_valid      = '1;
        start.read       = '1;
      end
      READING: begin
        first_block_d = '0;

        read_run_timeout = '1;
      end
      DONE_READING: begin
        data_crc_error_o.de     = done.crc_err;
        data_end_bit_error_o.de = done.end_bit_err;
        done_ready              = '1;

        read_transfer_active_o.de = '1;
        read_transfer_active_o.d  = '0;
      end
      TIMEOUT_READING: begin
        data_timeout_error_o.de   = '1;
        read_transfer_active_o.de = '1;
        read_transfer_active_o.d  = '0;

        sd_rst_n = '0;
      end
      
      START_WRITING: begin
        buffer_write_enable_o.de = '1;
        buffer_write_enable_o.d =  '1;

        dat_line_active_o.de       = '1;
        dat_line_active_o.d        = '1;
        write_transfer_active_o.de = '1;
        write_transfer_active_o.d  = '1;

        start_valid      = '1;
        start.write      = '1;
      end
      SEND_FIRST_WORD: begin
        first_block_d = '0;

        buffer_write_enable_o.de = '1;
        buffer_write_enable_o.d  = '0;

        write_valid = '1;
        pop_write_buffer = '1;
      end
      WRITING: begin
        if (write_ready) begin
          if (write_reg_length > 8'b0) begin
            if (write_reg_length > 8'b1) write_valid = '1;
            pop_write_buffer = '1;
          end
        end
      end
      DONE_WRITING_BLOCK: begin
        if (reg2hw_i.transfer_mode.multi_single_block_select.q) begin
          block_count_o.de = '1;
          block_count_o.d  = reg2hw_i.block_count.q - 1;
        end
      end
      DONE_WRITING: begin
        data_crc_error_o.de     = done.crc_err;
        data_end_bit_error_o.de = done.end_bit_err;
        done_ready              = '1;

        write_transfer_active_o.de = '1;
        write_transfer_active_o.d  = '0;
      end
      
      default: ;
    endcase
  end
  
  // Read timeout
  logic read_timeout;
  dat_read_timeout i_read_timeout (
    .clk_i,
    .rst_ni,

    .running_i      (read_run_timeout),
    .timeout_bits_i (reg2hw_i.timeout_control.data_timeout_counter_value),

    .timeout_o      (read_timeout)
  );

  logic read_reg_empty;
  always_comb begin
    buffer_read_enable_o.de = '0;
    buffer_read_enable_o.d  = 'X;

    if (reg2hw_i.present_state.buffer_read_enable.q) begin
      if (read_reg_empty) begin
        buffer_read_enable_o.de = '1;
        buffer_read_enable_o.d  = '0;
      end
    end else begin
      if (done_valid) begin
        buffer_read_enable_o.de = '1;
        buffer_read_enable_o.d  = '1;
      end
    end
  end

  sram_shift_reg #(
    .NumWords (128)
  ) i_shift_read (
    .clk_i,
    .rst_ni,
  
    .pop_front_i  (reg2hw_i.buffer_data_port.re),
    .front_data_o (buffer_data_port_d_o),
  
    .push_back_i  (read_valid),
    .back_data_i  (read_data),
  
    .full_o   (),
    .empty_o  (read_reg_empty),
    .length_o ()
  );

  logic [7:0] write_reg_length;
  logic write_reg_empty, write_reg_full, write_pop;
  sram_shift_reg #(
    .NumWords (128)
  ) i_shift_write (
    .clk_i,
    .rst_ni,

    .pop_front_i  (pop_write_buffer),
    .front_data_o (write_data),

    .push_back_i  (reg2hw_i.buffer_data_port.qe),
    .back_data_i  (reg2hw_i.buffer_data_port.q),

    .full_o   (write_reg_full),
    .empty_o  (write_reg_empty),
    .length_o (write_reg_length)
  );

  ///////////////////////////////////////////////////////////////////////////////
  //                              SD Clock Domain                              //
  ///////////////////////////////////////////////////////////////////////////////

  logic sd_read_done,  sd_read_crc_err,  sd_read_end_bit_err;
  logic sd_write_done, sd_write_crc_err, sd_write_end_bit_err;

  logic sd_done_valid_q, sd_done_valid_d;
  `FF (sd_done_valid_q, sd_done_valid_d, '0, sd_clk_i, sd_rst_n);
  assign sd_done_valid = sd_done_valid_q;

  sd_done_t sd_done_q, sd_done_d;
  `FF (sd_done_q, sd_done_d, '0, sd_clk_i, sd_rst_n);

  always_comb begin
    sd_done_valid_d = sd_done_valid_q;
    sd_done_d       = sd_done_q;

    if (sd_read_done) begin
      sd_done_valid_d       = '1;
      sd_done_d.crc_err     = sd_read_crc_err;
      sd_done_d.end_bit_err = sd_read_end_bit_err;
    end else if (sd_write_done) begin
      sd_done_valid_d       = '1;
      sd_done_d.crc_err     = sd_write_crc_err;
      sd_done_d.end_bit_err = sd_write_end_bit_err;
    end else if (sd_done_ready) begin
      sd_done_valid_d = '0;
      sd_done_d       = '0;
    end
  end


  logic sd_read_valid_q, sd_read_valid_d, sd_read_valid_out;
  `FF (sd_read_valid_q, sd_read_valid_d, '0, sd_clk_i, sd_rst_n);
  assign sd_read_valid = sd_read_valid_q;

  logic [31:0] sd_read_data_q, sd_read_data_d, sd_read_data_out;
  `FF (sd_read_data_q, sd_read_data_d, '0, sd_clk_i, sd_rst_n);
  assign sd_read_data = sd_read_data_q;
  
  always_comb begin
    sd_read_valid_d = sd_read_valid_q;
    sd_read_data_d  = sd_read_data_q;

    if (sd_read_valid_out) begin
      sd_read_valid_d = '1;
      sd_read_data_d  = sd_read_data_out;
    end else if (sd_read_ready) begin
      sd_read_valid_d = '0;
      sd_read_data_d  = '0;
    end
  end

  logic sd_start_read, sd_start_write;

  logic sd_rsp_done_q, sd_rsp_done_d;
  `FF (sd_rsp_done_q, sd_rsp_done_d, '0, sd_clk_i, sd_rst_n);

  always_comb begin
    sd_start_ready = '0;

    sd_start_read  = '0;
    sd_start_write = '0;

    sd_rsp_done_d = '0;

    if (sd_start_valid) begin
      sd_rsp_done_d = sd_rsp_done_q;

      if (sd_start.read) begin
        if (!start.wait_for_cmd || sd_cmd_done_i) begin
          sd_start_ready = '1;
          sd_start_read  = '1;
        end
      end
      if (sd_start.write) begin
        if (sd_rsp_done_i) sd_rsp_done_d = '1;

        if (sd_write_valid && (!start.wait_for_cmd || sd_rsp_done_q)) begin
          sd_start_ready = '1;
          sd_start_write = '1;
        end
      end
    end
  end

  dat_read #(
    .MaxBlockBitSize (MaxBlockBitSize)
  ) i_read (
    .sd_clk_i,
    .rst_ni        (sd_rst_n),
    .dat_i,

    .start_i       (sd_start_read),
    .block_size_i  (sd_start.block_size),
    
    .data_valid_o  (sd_read_valid_out),
    .data_o        (sd_read_data_out),
    
    .done_o        (sd_read_done),
    .crc_err_o     (sd_read_crc_err),
    .end_bit_err_o (sd_read_end_bit_err)
  );

  dat_write #(
    .MaxBlockBitSize (MaxBlockBitSize)
  ) i_write (
    .sd_clk_i,
    .rst_ni        (sd_rst_n),
    .dat0_i        (dat_i[0]),
    .dat_o,
    .dat_en_o,

    .start_i       (sd_start_write),
    .block_size_i  (sd_start.block_size),

    // Not using sd_write_valid signal here because the data has to always arrive on time
    .data_i        (sd_write_data),
    .next_word_o   (sd_write_ready),

    .done_o        (sd_write_done),
    .crc_err_o     (sd_write_crc_err),
    .end_bit_err_o (sd_write_end_bit_err)
  );
endmodule