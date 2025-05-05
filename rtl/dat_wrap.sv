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

  output logic request_cmd12_o,
  output logic pause_sd_clk_o,

  input  sdhci_reg_pkg::sdhci_reg2hw_t reg2hw_i,

  output `writable_reg_t()        data_crc_error_o,
  output `writable_reg_t()        data_end_bit_error_o,
  output `writable_reg_t()        data_timeout_error_o,

  output logic [31:0]             buffer_data_port_d_o,
  output `writable_reg_t()        buffer_read_enable_o,
  output `writable_reg_t()        buffer_write_enable_o,

  output `writable_reg_t()        read_transfer_active_o,
  output `writable_reg_t()        write_transfer_active_o,
  output `writable_reg_t()        dat_line_active_o,

  output `writable_reg_t([15:0])  block_count_o,

  output sdhci_reg_pkg::sdhci_hw2reg_auto_cmd12_error_status_reg_t auto_cmd12_errors_o
);
  localparam int RegisterWordCount = 32;
  localparam int RegisterByteCount = RegisterWordCount * 4;

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
  logic sd_start_ready;
  sd_start_t start_q, start_d;
  `FF (start_q, start_d, '0, clk_i, rst_ni);

  typedef struct packed {
    logic crc_err;
    logic end_bit_err;
  } sd_done_t;
  logic sd_done_valid;
  sd_done_t sd_done;

  logic sd_read_valid;
  logic [31:0] sd_read_data;

  logic write_valid, sd_write_ready;
  logic [31:0] write_data;

  ///////////////////////////////////////////////////////////////////////////////
  //                           Register Clock Domain                           //
  ///////////////////////////////////////////////////////////////////////////////

  typedef enum logic [3:0] {
    READY,

    // Read
    START_READING,
    STARTING_READING,
    READING,
    READING_BUSY,
    DONE_READING_BLOCK,
    TIMEOUT_READING,
    DONE_READING,

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

  logic last_block;
  assign last_block = reg2hw_i.transfer_mode.multi_single_block_select.q == 1'b0 || reg2hw_i.block_count.q - 1 == '0;

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
      STARTING_READING: if (sd_start_ready) state_d = READING;
      READING: begin
        if (read_timeout) begin
          state_d = TIMEOUT_READING;
          // Reset reader
        end else if (sd_done_valid) begin
          state_d = last_block || read_reg_remaining_bytes < start_q.block_size ? READING_BUSY : DONE_READING_BLOCK;
        end
      end
      READING_BUSY: if (read_reg_empty) state_d = DONE_READING_BLOCK;
      DONE_READING_BLOCK:  begin
        // TODO Block Count Enable and Abort Operation
        // TODO stop writing when crc error happens
        state_d = last_block ? DONE_READING : START_READING;
      end
      TIMEOUT_READING: state_d = DONE_READING;
      DONE_READING:    state_d = READY;

      START_WRITING:       state_d = WAIT_FOR_WRITE_DATA;
      WAIT_FOR_WRITE_DATA: if (write_reg_length * 4 >= start_q.block_size) state_d = SEND_FIRST_WORD;
      SEND_FIRST_WORD:     if (sd_start_ready) state_d = WRITING;
      WRITING:             if (sd_done_valid) state_d = DONE_WRITING_BLOCK;
      DONE_WRITING_BLOCK:  begin
        // TODO Block Count Enable and Abort Operation
        // TODO stop writing when crc error happens
        state_d = last_block ? DONE_WRITING : START_WRITING;
      end
      DONE_WRITING:        state_d = READY;

      default: state_d = READY;
    endcase
  end
  
  logic first_block_q, first_block_d;
  `FF (first_block_q, first_block_d, '0, clk_i, rst_ni);

  logic software_reset_dat;
  `FF(software_reset_dat, reg2hw_i.software_reset.software_reset_for_dat_line.q, '0, clk_i, rst_ni);

  logic prev_read_valid;
  `FF(prev_read_valid, sd_read_valid, '0, clk_i, rst_ni);

  logic [MaxBlockBitSize-1:0] read_reg_start_length_q, read_reg_start_length_d;
  `FF (read_reg_start_length_q, read_reg_start_length_d, '0, clk_i, rst_ni)

  logic read_run_timeout, pop_write_buffer;
  always_comb begin
    sd_rst_n = rst_ni & ~software_reset_dat;

    first_block_d = first_block_q;

    start_d = start_q;

    pop_write_buffer = '0;
    write_valid      = '0;
    read_run_timeout = '0;

    request_cmd12_o  = '0;
    pause_sd_clk_o   = '0;

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

    read_reg_start_length_d = '0;
    buffer_read_enable_o.de = '0;
    buffer_read_enable_o.d  = 'X;
    
    unique case (state_q)
      READY: begin
        first_block_d = '1;

        dat_line_active_o.de       = '1;
        dat_line_active_o.d        = '0;

        start_d = '0;
      end
      START_READING: begin
        dat_line_active_o.de      = '1;
        dat_line_active_o.d       = '1;
        read_transfer_active_o.de = '1;
        read_transfer_active_o.d  = '1;

        start_d.read         = '1;
        start_d.wait_for_cmd = first_block_q;
        start_d.block_size   = MaxBlockBitSize'(reg2hw_i.block_size.transfer_block_size.q);
      end
      READING: begin
        read_run_timeout = '1;

        // Have to do it here already because of strict timing
        if (last_block) start_d.read = '0;

        if (sd_done_valid) begin
          data_crc_error_o.de     = sd_done.crc_err;
          data_end_bit_error_o.de = sd_done.end_bit_err;
        end

        read_reg_start_length_d = read_reg_length;
      end
      READING_BUSY: begin
        read_reg_start_length_d = read_reg_start_length_q;
        buffer_read_enable_o.de = '1;
        buffer_read_enable_o.d  = '1;

        if (read_reg_length * 4 + start_q.block_size <= read_reg_start_length_q * 4) begin
          buffer_read_enable_o.d = '0;
          read_reg_start_length_d = read_reg_length;
        end

        pause_sd_clk_o          = '1;
      end
      DONE_READING_BLOCK: begin
        first_block_d = '0;

        if (reg2hw_i.transfer_mode.multi_single_block_select.q) begin
          block_count_o.de = '1;
          block_count_o.d  = reg2hw_i.block_count.q - 1;
        end
      end
      TIMEOUT_READING: begin
        data_timeout_error_o.de   = '1;
        sd_rst_n = '0;
      end
      DONE_READING: begin
        read_transfer_active_o.de = '1;
        read_transfer_active_o.d  = '0;

        if (reg2hw_i.transfer_mode.auto_cmd12_enable.q) request_cmd12_o = '1;
      end
      
      START_WRITING: begin
        buffer_write_enable_o.de = '1;
        buffer_write_enable_o.d =  '1;

        dat_line_active_o.de       = '1;
        dat_line_active_o.d        = '1;
        write_transfer_active_o.de = '1;
        write_transfer_active_o.d  = '1;

        start_d.write        = '1;
        start_d.wait_for_cmd = first_block_q;
        start_d.block_size   = MaxBlockBitSize'(reg2hw_i.block_size.transfer_block_size.q);
      end
      SEND_FIRST_WORD: begin
        buffer_write_enable_o.de = '1;
        buffer_write_enable_o.d  = '0;
        
        write_valid = '1;
      end
      WRITING: begin
        if (sd_write_ready) pop_write_buffer = '1;

        if (sd_done_valid) begin
          data_crc_error_o.de     = sd_done.crc_err;
          data_end_bit_error_o.de = sd_done.end_bit_err;
        end
      end
      DONE_WRITING_BLOCK: begin
        first_block_d = '0;

        if (reg2hw_i.transfer_mode.multi_single_block_select.q) begin
          block_count_o.de = '1;
          block_count_o.d  = reg2hw_i.block_count.q - 1;
        end
      end
      DONE_WRITING: begin
        write_transfer_active_o.de = '1;
        write_transfer_active_o.d  = '0;

        if (reg2hw_i.transfer_mode.auto_cmd12_enable.q) request_cmd12_o = '1;
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

  logic [cf_math_pkg::idx_width(RegisterWordCount + 1)*4-1:0] read_reg_remaining_bytes;
  assign read_reg_remaining_bytes = {cf_math_pkg::idx_width(RegisterWordCount + 1)*4}'(RegisterByteCount - read_reg_length * 4);

  logic [cf_math_pkg::idx_width(RegisterWordCount + 1)-1:0] read_reg_length;
  logic read_reg_empty;
  sram_shift_reg #(
    .NumWords (RegisterWordCount)
  ) i_shift_read (
    .clk_i,
    .rst_ni,
  
    .pop_front_i  (reg2hw_i.buffer_data_port.re),
    .front_data_o (buffer_data_port_d_o),
  
    .push_back_i  (!prev_read_valid && sd_read_valid),
    .back_data_i  (sd_read_data),
  
    .full_o   (),
    .empty_o  (read_reg_empty),
    .length_o (read_reg_length)
  );

  logic [cf_math_pkg::idx_width(RegisterWordCount + 1)-1:0] write_reg_length;
  logic write_reg_empty, write_reg_full, write_pop;
  sram_shift_reg #(
    .NumWords (RegisterWordCount)
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

  logic sd_start_read, sd_start_write;

  logic sd_rsp_done_q, sd_rsp_done_d;
  `FF (sd_rsp_done_q, sd_rsp_done_d, '0, sd_clk_i, sd_rst_n);

  always_comb begin
    sd_start_ready = '0;

    sd_start_read  = '0;
    sd_start_write = '0;

    sd_rsp_done_d = '0;

    if (start_q.read) begin
      // We know that start will always be valid when sd_cmd_done comes 
      if (!start_q.wait_for_cmd || sd_cmd_done_i) begin
        sd_start_ready  = '1;
        sd_start_read   = '1;
      end
    end
    if (start_q.write) begin
      sd_rsp_done_d = sd_rsp_done_q || sd_rsp_done_i;

      if (write_valid && (!start_q.wait_for_cmd || sd_rsp_done_q)) begin
        sd_start_ready   = '1;
        sd_start_write   = '1;
      end
    end
  end


  logic sd_read_done,  sd_read_crc_err,  sd_read_end_bit_err;
  logic sd_write_done, sd_write_crc_err, sd_write_end_bit_err;

  assign sd_done_valid       = sd_read_done | sd_write_done;
  assign sd_done.crc_err     = sd_read_done ? sd_read_crc_err     : sd_write_crc_err;
  assign sd_done.end_bit_err = sd_read_done ? sd_read_end_bit_err : sd_write_end_bit_err;

  dat_read #(
    .MaxBlockBitSize (MaxBlockBitSize)
  ) i_read (
    .sd_clk_i,
    .rst_ni        (sd_rst_n),
    .dat_i,

    .start_i       (sd_start_read),
    .block_size_i  (start_q.block_size),
    
    .data_valid_o  (sd_read_valid),
    .data_o        (sd_read_data),
    
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
    .block_size_i  (start_q.block_size),

    // Not using sd_write_valid signal here because the data has to always arrive on time
    .data_i        (write_data),
    .next_word_o   (sd_write_ready),

    .done_o        (sd_write_done),
    .crc_err_o     (sd_write_crc_err),
    .end_bit_err_o (sd_write_end_bit_err)
  );
endmodule