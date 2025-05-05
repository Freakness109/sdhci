`include "common_cells/registers.svh"

// done_o and data_valid_o can be done at the same time
// theres always atleast 7 cycles between every data_valid_o

module dat_read #(
  parameter int MaxBlockBitSize
) (
  input  logic       sd_clk_i,
  input  logic       rst_ni,
  input  logic [3:0] dat_i,

  input  logic                       start_i,
  input  logic [MaxBlockBitSize-1:0] block_size_i, // In bytes

  output logic        data_valid_o,
  output logic [31:0] data_o,

  output logic done_o,
  output logic crc_err_o,     // Only valid while done_o = 1
  output logic end_bit_err_o  // Only valid while done_o = 1
);
  localparam int CounterWidth = MaxBlockBitSize + 2;

  typedef enum logic [2:0] {
    IDLE,
    READY,
    DAT,
    CRC,
    END_BIT
  } dat_rx_state_e;

  dat_rx_state_e state_q, state_d;
  `FF (state_q, state_d, IDLE, sd_clk_i, rst_ni);

  logic [CounterWidth-1:0] counter_q, counter_d;
  `FF (counter_q, counter_d, 0, sd_clk_i, rst_ni);

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      IDLE:    if (start_i) state_d = READY;
      READY:   if (dat_i == 4'b0) state_d = DAT;
      DAT:     if (counter_q == 2*block_size_i - 1) state_d = CRC;
      CRC:     if (counter_q == 2*block_size_i + 16 - 1) state_d = END_BIT;
      END_BIT: state_d = IDLE;
      default: state_d = IDLE;
    endcase
  end

  logic clear_crc;
  logic [3:0] crc_errors;
  logic [31:0] data_buildup_q, data_buildup_d;
  `FF (data_buildup_q, data_buildup_d, 0, sd_clk_i, rst_ni);

  always_comb begin
    counter_d = counter_q;
    data_valid_o = '0;
    data_o = '0;
    data_buildup_d = data_buildup_q;

    clear_crc = '0;
    done_o        = '0;
    crc_err_o     = 'X;
    end_bit_err_o = 'X;

    unique case (state_q)
      READY: begin
        counter_d = '0;
        clear_crc = '1;
      end
      DAT: begin
        // TODO make this work with buswidth of 1 ??
        counter_d = counter_q + 1;

        // Every 8 cycles (8 * 4lines = 32)
        if (counter_q[2:0] == '1) begin
          data_valid_o = '1;
          data_o = { data_buildup_q[31:28], dat_i, data_buildup_q[23:0] };
          data_buildup_d = '0;
        end else begin
          // dat 0: 4, 0
          // dat 1: 5, 1
          // dat 2: 6, 2
          // dat 3: 7, 3
          if (counter_q[0] == '0) begin
            // Leave a few empty slots for the next 4 bits
            data_buildup_d = { dat_i, 4'b0, data_buildup_q[31:8] };
          end else begin
            // Fill the empty slots
            data_buildup_d[27:24] = dat_i;
          end
        end
      end

      CRC: begin
        counter_d = counter_q + 1;

        if (counter_q == 2*block_size_i && block_size_i[1:0] != 0) begin
          data_valid_o = '1;
          unique case (block_size_i[1:0])
            2'd0: ;
            2'd1: data_o = { 24'b0, data_buildup_q[31:24] };
            2'd2: data_o = { 16'b0, data_buildup_q[31:16] };
            2'd3: data_o = {  8'b0, data_buildup_q[31: 8] };
          endcase
          data_buildup_d = '0;
        end
      end
      END_BIT: begin
        done_o = '1;
        end_bit_err_o = dat_i != '1;
        crc_err_o = crc_errors != '0;
      end
      default: ;
    endcase
  end

  for (genvar i=0; i<4 ; i++) begin
    logic [15:0] crc_val;
    assign crc_errors[i] = crc_val != '0;

    crc16_read i_crc16_read (
      .sd_clk_i,
      .rst_ni,

      .start_i      (clear_crc),

      .dat_ser_i    (dat_i[i]),
      .crc16_o      (crc_val)
    );
  end
endmodule