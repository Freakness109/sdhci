`include "common_cells/registers.svh"
`include "defines.svh"

module dat_wrap #(
  parameter int MaxBlockBitSize = 10 // max_block_length = 512 in caps
) (
  input  logic clk_i,
  input  logic sd_clk_en_p_i,
  input  logic sd_clk_en_n_i,
  input  logic div_1_i,
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

  output `writable_reg_t([15:0])  block_count_o
);
  localparam int RegisterWordCount = 128;
  localparam int RegisterByteCount = RegisterWordCount * 4;

  typedef enum logic [3:0] {
    READY,

    // Read
    WAIT_FOR_CMD,
    START_READING,
    READING,
    READING_BUSY,
    DONE_READING_BLOCK,
    TIMEOUT_READING,
    DONE_READING,

    // Write
    WAIT_FOR_WRITE_DATA,
    WAIT_FOR_RSP,
    START_WRITING,
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
            state_d = WAIT_FOR_CMD;
          end else begin
            state_d = WAIT_FOR_WRITE_DATA;
          end
        end
      end

      WAIT_FOR_CMD:  if (sd_cmd_done_i) state_d = START_READING;
      START_READING: if (sd_clk_en_p_i)  state_d = READING;
      READING: begin
        if (read_timeout) begin
          state_d = TIMEOUT_READING;
          // Reset reader
        end else if (read_done) begin
          state_d = last_block || reg_remaining_bytes < block_size ? READING_BUSY : DONE_READING_BLOCK;
        end
      end
      READING_BUSY:       if (reg_empty) state_d = DONE_READING_BLOCK;
      DONE_READING_BLOCK: state_d = last_block ? DONE_READING : START_READING;
      TIMEOUT_READING:    state_d = DONE_READING;
      DONE_READING:       state_d = READY;

      WAIT_FOR_WRITE_DATA: if (reg_length * 4 >= block_size) state_d = first_block_q ? WAIT_FOR_RSP : START_WRITING;
      WAIT_FOR_RSP:        if (rsp_done_q) state_d = START_WRITING;
      START_WRITING:       if (sd_clk_en_p_i) state_d = WRITING;
      WRITING:             if (write_done) state_d = DONE_WRITING_BLOCK;
      DONE_WRITING_BLOCK:  state_d = last_block ? DONE_WRITING : WAIT_FOR_WRITE_DATA;
      DONE_WRITING:        state_d = READY;

      default: state_d = READY;
    endcase
  end
  
  logic first_block_q, first_block_d;
  `FF (first_block_q, first_block_d, '0, clk_i, rst_ni);

  logic [MaxBlockBitSize-1:0] reg_start_length_q, reg_start_length_d;
  `FF (reg_start_length_q, reg_start_length_d, '0, clk_i, rst_ni)

  logic [MaxBlockBitSize-1:0] block_size;
  assign block_size = MaxBlockBitSize'(reg2hw_i.block_size.transfer_block_size.q);

  logic rsp_done_q, rsp_done_d;
  `FF (rsp_done_q, rsp_done_d, '0, clk_i, rst_ni);

  logic read_run_timeout;
  always_comb begin

    first_block_d = first_block_q;

    read_run_timeout = '0;

    request_cmd12_o  = '0;
    pause_sd_clk_o   = '0;

    data_crc_error_o.de     = '0;
    data_crc_error_o.d      = '1;
    data_end_bit_error_o.de = '0;
    data_end_bit_error_o.d  = '1;
    data_timeout_error_o.de = '0;
    data_timeout_error_o.d  = '1;

    read_transfer_active_o.de  = '1;
    read_transfer_active_o.d   = '0;
    write_transfer_active_o.de = '1;
    write_transfer_active_o.d  = '0;

    block_count_o.de = '0;
    block_count_o.d  = 'X;

    reg_start_length_d = '0;
    buffer_write_enable_o = '{ de: '1, d: '0 };
    buffer_read_enable_o  = '{ de: '1, d: '0 };

    rsp_done_d = rsp_done_q || sd_rsp_done_i;

    start_read  = '0;
    start_write = '0;
    write_data  = 'X;

    clear_reg     = '0;
    reg_push      = '0;
    reg_push_data = 'X;
    reg_pop       = '0;

    unique case (state_q)
      READY: begin
        first_block_d = '1;
        rsp_done_d    = '0;
        clear_reg     = '1;
      end
      WAIT_FOR_CMD: begin
        read_transfer_active_o.d  = '1;
      end
      START_READING: begin
        read_transfer_active_o.d  = '1;
        start_read = '1;
      end
      READING: begin
        read_transfer_active_o.d = '1;
        read_run_timeout = '1;

        if (read_valid) begin
          reg_push      = '1;
          reg_push_data = read_data;
        end

        if (read_done) begin
          data_crc_error_o.de     = read_crc_err;
          data_end_bit_error_o.de = read_end_bit_err;
        end

        reg_start_length_d = reg_length;
      end
      READING_BUSY: begin
        read_transfer_active_o.d = '1;
        reg_start_length_d       = reg_start_length_q;
        buffer_read_enable_o.d   = '1;

        reg_pop              = reg2hw_i.buffer_data_port.re;
        buffer_data_port_d_o = reg_pop_data;

        if (reg_length * 4 + block_size <= reg_start_length_q * 4) begin
          buffer_read_enable_o.d  = '0;
          reg_start_length_d = reg_length;
        end

        if (!last_block) pause_sd_clk_o = '1;
      end
      DONE_READING_BLOCK: begin
        read_transfer_active_o.d = '1;
        first_block_d = '0;

        if (reg2hw_i.transfer_mode.multi_single_block_select.q) begin
          block_count_o.de = '1;
          block_count_o.d  = reg2hw_i.block_count.q - 1;
        end
      end
      TIMEOUT_READING: begin
        read_transfer_active_o.d = '1;
        data_timeout_error_o.de  = '1;
      end
      DONE_READING: begin
        read_transfer_active_o.d = '1;

        if (reg2hw_i.transfer_mode.auto_cmd12_enable.q) request_cmd12_o = '1;
      end

      WAIT_FOR_WRITE_DATA: begin
        write_transfer_active_o.d  = '1;
        buffer_write_enable_o.d    = '1;

        reg_push      = reg2hw_i.buffer_data_port.qe;
        reg_push_data = reg2hw_i.buffer_data_port.q;
      end
      WAIT_FOR_RSP: begin
        write_transfer_active_o.d  = '1;
      end
      START_WRITING: begin
        write_transfer_active_o.d  = '1;
        start_write  = '1;
      end
      WRITING: begin
        write_transfer_active_o.d = '1;

        if (write_requests_next_word) reg_pop = '1;
        write_data = reg_pop_data; 

        if (write_done) begin
          data_crc_error_o.de     = write_crc_err;
          data_end_bit_error_o.de = write_end_bit_err;
        end
      end
      DONE_WRITING_BLOCK: begin
        write_transfer_active_o.d = '1;
        first_block_d = '0;

        if (reg2hw_i.transfer_mode.multi_single_block_select.q) begin
          block_count_o.de = '1;
          block_count_o.d  = reg2hw_i.block_count.q - 1;
        end
      end
      DONE_WRITING: begin
        write_transfer_active_o.d = '1;

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


  logic [cf_math_pkg::idx_width(RegisterByteCount + 1)-1:0] reg_remaining_bytes;
  assign reg_remaining_bytes = {cf_math_pkg::idx_width(RegisterByteCount + 1)}'(RegisterByteCount - reg_length * 4);

  logic [cf_math_pkg::idx_width(RegisterWordCount + 1)-1:0] reg_length;
  logic clear_reg, reg_empty, reg_full, reg_push, reg_pop;
  logic [31:0] reg_push_data, reg_pop_data;
  sram_shift_reg #(
    .NumWords (RegisterWordCount)
  ) i_shift_read (
    .clk_i,
    .rst_ni,
  
    .clear_i      (clear_reg),
    .pop_front_i  (reg_pop),
    .front_data_o (reg_pop_data),
  
    .push_back_i  (reg_push),
    .back_data_i  (reg_push_data),
  
    .full_o   (reg_full),
    .empty_o  (reg_empty),
    .length_o (reg_length)
  );

  logic start_read, read_valid, read_done, read_crc_err, read_end_bit_err;
  logic [31:0] read_data;
  dat_read #(
    .MaxBlockBitSize (MaxBlockBitSize)
  ) i_read (
    .clk_i,
    .sd_clk_en_i   (sd_clk_en_p_i),
    .rst_ni,
    .dat_i,

    .start_i          (start_read),
    .block_size_i     (block_size),
    .bus_width_is_4_i (reg2hw_i.host_control.data_transfer_width.q),
    
    .data_valid_o  (read_valid),
    .data_o        (read_data),
    
    .done_o        (read_done),
    .crc_err_o     (read_crc_err),
    .end_bit_err_o (read_end_bit_err)
  );

  logic start_write, write_requests_next_word, write_done, write_crc_err, write_end_bit_err;
  logic [31:0] write_data;
  dat_write #(
    .MaxBlockBitSize (MaxBlockBitSize)
  ) i_write (
    .clk_i,
    .sd_clk_en_p_i  (sd_clk_en_p_i),
    .sd_clk_en_n_i  (sd_clk_en_n_i),
    .div_1_i        (div_1_i),
    .rst_ni,
    .dat0_i        (dat_i[0]),
    .dat_o,
    .dat_en_o,

    .start_i          (start_write),
    .block_size_i     (block_size),
    .bus_width_is_4_i (reg2hw_i.host_control.data_transfer_width.q),

    .data_i        (write_data),
    .next_word_o   (write_requests_next_word),

    .done_o        (write_done),
    .crc_err_o     (write_crc_err),
    .end_bit_err_o (write_end_bit_err)
  );
endmodule