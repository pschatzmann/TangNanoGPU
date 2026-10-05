`timescale 1ns / 1ps
`default_nettype none
//
// SPI / quad-SPI slave for TangNanoGPU (mode 0: CPOL=0, CPHA=0, MSB first).
//
// Receive path: SCK itself clocks the input shift register (no
// oversampling), so writes run at the host's full SPI clock (tested in
// simulation at 40MHz). Every completed byte goes, tagged with a
// "first byte of the transaction" flag, through a small async FIFO
// (async_fifo.v) into the system clock domain, where it is parsed. The
// flag - not a synchronised CS - frames transactions, so a CS that rises
// right after the last byte can't overtake that byte.
//
// Quad mode (QUAD = 1): the first byte of every transaction (the address
// byte) is always received single-line on IO0/MOSI. If its bit 7 is set,
// the rest of the transaction is received four bits per SCK rising edge on
// IO3..IO0, high nibble first (2 clocks per byte). Quad transactions are
// write-only: MISO/IO1 is an input then.
//
// Transmit path (PING / STATUS / READ_DATA): unchanged behaviour - the
// response to byte N is shifted out during byte N+1. The SCK-domain output
// register loads the system domain's `tx_next` on the falling edge after
// each byte, so a read needs the system domain to see the byte first:
// reads must use a slower SCK (the host library uses 4MHz).
//
// Every transaction (one CS-low period) is [ADDR][OPCODE][payload...]:
//   - ADDR[6:0] must equal the ADDR parameter, otherwise the board ignores
//     the rest of the transaction and keeps MISO tri-stated. ADDR[7] is the
//     quad flag.
//   - Immediate opcodes are handled here:
//       0x01 PING      -> "TANG" + version + capabilities (bit0 = quad)
//       0x02 RESET     -> soft reset: flush FIFOs, reset the drawing engine,
//                         clear the sticky flags
//       0x03 STATUS    -> 7 status bytes (snapshot taken at the opcode)
//       0x51 READ_DATA -> streams bytes out of the response FIFO
//   - Every other opcode, and all bytes following it until CS rises, are
//     pushed into the command FIFO for gpu_exec.v to parse.
//
module spi_gpu #(
    parameter [6:0] ADDR    = 7'h00,
    parameter [7:0] VERSION = 8'h02,
    parameter integer QUAD  = 1
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        sck,
    input  wire        cs_n,
    input  wire [3:0]  io_in,     // IO3..IO0 (IO0 = MOSI, IO1 = MISO pin)
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
  localparam [7:0] CAPS = (QUAD != 0) ? 8'h01 : 8'h00;

  // =================== SCK domain: receive ===================
  // Initial values matter here: these registers are only reset by a rising
  // CS edge, and at power-up CS is already high, so without them the first
  // transaction would start from undefined state (Gowin registers take
  // their INIT value at configuration).
  reg  [2:0] bitn = 3'd0;       // bit within the byte (single-line mode)
  reg  [6:0] rx = 7'd0;
  reg        first = 1'b1;      // next completed byte is the address byte
  reg        quad = 1'b0;       // rest of this transaction is quad
  reg        half = 1'b0;       // quad: high nibble already received
  reg  [3:0] hi = 4'd0;
  reg        any_byte = 1'b0;   // at least one byte completed in this transaction

  wire       single_done = !quad && (bitn == 3'd7);
  wire       quad_done   = quad && half;
  wire       byte_we     = single_done || quad_done;
  wire [7:0] byte_in     = quad ? {hi, io_in} : {rx, io_in[0]};

  always @(posedge sck or posedge cs_n) begin
    if (cs_n) begin
      bitn     <= 3'd0;
      first    <= 1'b1;
      quad     <= 1'b0;
      half     <= 1'b0;
      any_byte <= 1'b0;
    end else begin
      if (!quad) begin
        rx   <= {rx[5:0], io_in[0]};
        bitn <= bitn + 3'd1;
        if (bitn == 3'd7) begin
          first    <= 1'b0;
          any_byte <= 1'b1;
          // the address byte's bit 7 (its first bit, now rx[6]) switches
          // the rest of the transaction to quad
          if (first && QUAD != 0 && rx[6]) quad <= 1'b1;
        end
      end else begin
        half <= !half;
        if (!half) hi <= io_in;
      end
    end
  end

  wire       rxq_empty;
  wire [8:0] rxq_dout;
  reg        rxq_pop;

  async_fifo #(.W(9), .AW(4)) u_rxq (
      .rst(rst),
      .wclk(sck), .we(byte_we && !cs_n), .wdata({first, byte_in}), .full(),
      .rclk(clk), .re(rxq_pop), .rdata(rxq_dout), .empty(rxq_empty)
  );

  // =================== SCK domain: transmit ===================
  reg  [7:0] tx_next;     // system domain: next response byte
  reg  [7:0] tx_shift = 8'h00;
  reg        selected;    // system domain

  always @(negedge sck or posedge cs_n) begin
    if (cs_n) tx_shift <= 8'h00;
    else if (bitn == 3'd0 && any_byte) tx_shift <= tx_next;   // byte boundary
    else tx_shift <= {tx_shift[6:0], 1'b0};
  end

  assign miso    = tx_shift[7];
  assign miso_oe = !cs_n && selected && !quad && any_byte;

  // =================== system domain: parse ===================
  reg [1:0]  cs_s;
  always @(posedge clk) cs_s <= {cs_s[0], cs_n};

  reg [15:0] byten;       // bytes of this transaction parsed so far
  reg [7:0]  op;
  reg [7:0]  st [0:6];    // STATUS snapshot

  wire       rx_valid = !rxq_empty;
  wire       rx_first = rxq_dout[8];
  wire [7:0] rx_byte  = rxq_dout[7:0];

  always @(posedge clk) begin
    cmd_push   <= 1'b0;
    resp_pop   <= 1'b0;
    soft_reset <= 1'b0;
    rxq_pop    <= 1'b0;

    if (rst) begin
      byten    <= 16'd0;
      selected <= 1'b0;
      tx_next  <= 8'h00;
      overflow <= 1'b0;
      op       <= 8'h00;
    end else begin
      // CS high and nothing left to parse: tri-state MISO, idle
      if (cs_s[1] && rxq_empty) begin
        selected <= 1'b0;
        tx_next  <= 8'h00;
      end

      if (rx_valid && !rxq_pop) begin
        rxq_pop <= 1'b1;
        tx_next <= 8'h00;

        if (rx_first) begin
          // address byte (bit 7 = quad flag)
          selected <= (rx_byte[6:0] == ADDR);
          byten    <= 16'd1;
        end else begin
          if (byten != 16'hffff) byten <= byten + 16'd1;
          if (selected) begin
            if (byten == 16'd1) begin
              op <= rx_byte;
              case (rx_byte)
                OP_PING:   tx_next <= "T";
                OP_RESET: begin
                  soft_reset <= 1'b1;
                  overflow   <= 1'b0;   // RESET clears every sticky error flag
                end
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
              // payload / further response bytes
              case (op)
                OP_PING: begin
                  case (byten)
                    16'd2: tx_next <= "A";
                    16'd3: tx_next <= "N";
                    16'd4: tx_next <= "G";
                    16'd5: tx_next <= VERSION;
                    16'd6: tx_next <= CAPS;
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
  end

endmodule
`default_nettype wire
