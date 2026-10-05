`timescale 1ns / 1ps
`default_nettype none
//
// SPI slave for TangNanoGPU (mode 0: CPOL=0, CPHA=0, MSB first).
//
// SCK/MOSI/CS are double-flopped into the system clock domain and edges
// are detected there (the same robust technique as TangNanoAI's
// spi_slave.v), so SCK must be well below clk/4: up to ~16MHz at 64.8MHz
// for writes. MISO changes a few system clocks after SCK falls, so reads
// (PING / STATUS / READ_DATA) need a slower SCK - the host library uses
// 4MHz for them. See docs/protocol.md.
//
// Every transaction (one CS-low period) is [ADDR][OPCODE][payload...]:
//   - ADDR must equal the ADDR parameter, otherwise the board ignores the
//     rest of the transaction and keeps MISO tri-stated (several boards
//     can share one bus).
//   - Immediate opcodes are handled here:
//       0x01 PING      -> "TANG" + version (response lags one byte)
//       0x02 RESET     -> soft reset: flush FIFOs, reset the drawing engine
//       0x03 STATUS    -> 7 status bytes (snapshot taken at the opcode)
//       0x51 READ_DATA -> streams bytes out of the response FIFO
//   - Every other opcode, and all bytes following it until CS rises, are
//     pushed into the command FIFO for gpu_exec.v to parse.
//
// Like TangNanoAI: the response to byte N is shifted out during byte N+1.
//
module spi_gpu #(
    parameter [7:0] ADDR    = 8'h00,
    parameter [7:0] VERSION = 8'h01
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        sck,
    input  wire        mosi,
    input  wire        cs_n,
    output wire        miso,
    output wire        miso_oe,

    // command FIFO write side
    output reg         cmd_push,
    output reg  [7:0]  cmd_data,
    input  wire        cmd_full,

    // response FIFO read side (first-word-fall-through)
    input  wire        resp_valid,
    input  wire [7:0]  resp_dout,
    output reg         resp_pop,

    // status inputs for STATUS
    input  wire [15:0] cmd_free,
    input  wire [15:0] resp_used,
    input  wire [7:0]  flags,
    input  wire [15:0] frame_count,

    output reg         soft_reset,
    output reg         overflow       // sticky: a command byte arrived while the FIFO was full
);

  localparam [7:0] OP_PING = 8'h01, OP_RESET = 8'h02, OP_STATUS = 8'h03,
                   OP_READ_DATA = 8'h51;

  // ---- synchronisers ----
  reg [2:0] sck_s, cs_s;
  reg [1:0] mosi_s;
  always @(posedge clk) begin
    sck_s  <= {sck_s[1:0], sck};
    cs_s   <= {cs_s[1:0], cs_n};
    mosi_s <= {mosi_s[0], mosi};
  end
  wire sck_rise = (sck_s[2:1] == 2'b01);
  wire sck_fall = (sck_s[2:1] == 2'b10);
  wire cs_active = !cs_s[1];

  // ---- byte assembly ----
  reg [2:0] bitn;
  reg [6:0] rx;
  reg [7:0] tx_shift;
  reg [7:0] tx_next;
  reg [15:0] byten;     // bytes completed in this transaction (saturating)
  reg       selected;
  reg [7:0] op;

  reg [7:0] st [0:6];   // STATUS snapshot

  assign miso    = tx_shift[7];
  assign miso_oe = cs_active && selected;

  wire       byte_done = cs_active && sck_rise && (bitn == 3'd7);
  wire [7:0] rx_byte   = {rx, mosi_s[1]};

  always @(posedge clk) begin
    cmd_push   <= 1'b0;
    resp_pop   <= 1'b0;
    soft_reset <= 1'b0;

    if (rst) begin
      bitn     <= 3'd0;
      byten    <= 16'd0;
      selected <= 1'b0;
      tx_shift <= 8'h00;
      tx_next  <= 8'h00;
      overflow <= 1'b0;
      op       <= 8'h00;
    end else if (!cs_active) begin
      bitn     <= 3'd0;
      byten    <= 16'd0;
      selected <= 1'b0;
      tx_shift <= 8'h00;
      tx_next  <= 8'h00;
    end else begin
      // shift out on the falling edge; a completed byte loads the next
      // response byte instead of shifting
      if (sck_fall) begin
        if (bitn == 3'd0) tx_shift <= tx_next;
        else              tx_shift <= {tx_shift[6:0], 1'b0};
      end

      if (sck_rise) begin
        rx   <= rx_byte[6:0];
        bitn <= bitn + 3'd1;
      end

      if (byte_done) begin
        if (byten != 16'hffff) byten <= byten + 16'd1;
        tx_next <= 8'h00;

        if (byten == 16'd0) begin
          // address byte
          selected <= (rx_byte == ADDR);
        end else if (selected) begin
          if (byten == 16'd1) begin
            op <= rx_byte;
            case (rx_byte)
              OP_PING:   tx_next <= "T";
              OP_RESET:  soft_reset <= 1'b1;
              OP_STATUS: begin
                st[0] <= cmd_free[7:0];
                st[1] <= cmd_free[15:8];
                st[2] <= flags;
                st[3] <= frame_count[7:0];
                st[4] <= frame_count[15:8];
                st[5] <= resp_used[7:0];
                st[6] <= resp_used[15:8];
                tx_next <= cmd_free[7:0];
              end
              OP_READ_DATA: begin
                tx_next  <= resp_valid ? resp_dout : 8'h00;
                resp_pop <= resp_valid;
              end
              default: begin
                if (cmd_full) overflow <= 1'b1;
                else begin
                  cmd_push <= 1'b1;
                  cmd_data <= rx_byte;
                end
              end
            endcase
          end else begin
            // payload / further response bytes; byten-1 response bytes sent so far
            case (op)
              OP_PING: begin
                case (byten)
                  16'd2: tx_next <= "A";
                  16'd3: tx_next <= "N";
                  16'd4: tx_next <= "G";
                  16'd5: tx_next <= VERSION;
                  default: tx_next <= 8'h00;
                endcase
              end
              OP_STATUS: begin
                tx_next <= (byten <= 16'd7) ? st[byten[2:0] - 3'd1] : 8'h00;
              end
              OP_READ_DATA: begin
                tx_next  <= resp_valid ? resp_dout : 8'h00;
                resp_pop <= resp_valid;
              end
              OP_RESET: ;
              default: begin
                if (cmd_full) overflow <= 1'b1;
                else begin
                  cmd_push <= 1'b1;
                  cmd_data <= rx_byte;
                end
              end
            endcase
          end
        end
      end
    end
  end

endmodule
`default_nettype wire
