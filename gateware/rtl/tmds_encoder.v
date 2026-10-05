`timescale 1ns / 1ps
`default_nettype none
//
// DVI 1.0 TMDS encoder (8b/10b, transition-minimised + DC-balanced) for one
// channel. Written directly from the DVI 1.0 specification's encoding
// flowchart (section 3.2.3) - no HDMI data islands, so DVI-only output that
// every HDMI sink accepts.
//
// Output bit 0 is the first bit on the wire (dvi_tx.v feeds it to OSER10's
// D0, which Gowin shifts out first).
//
// One register stage: dout reflects (de, d, c) from the previous clock.
//
module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire       de,     // 1 = video data period, 0 = control period
    input  wire [7:0] d,      // pixel component
    input  wire [1:0] c,      // {c1, c0} control bits (only used when !de)
    output reg  [9:0] dout
);

  function [3:0] popcount8(input [7:0] v);
    integer i;
    begin
      popcount8 = 4'd0;
      for (i = 0; i < 8; i = i + 1) popcount8 = popcount8 + {3'd0, v[i]};
    end
  endfunction

  // ---- Stage 1: transition minimisation (q_m) ----
  wire [3:0] n1_d = popcount8(d);
  wire use_xnor = (n1_d > 4'd4) || (n1_d == 4'd4 && d[0] == 1'b0);

  wire [8:0] q_m;
  assign q_m[0] = d[0];
  genvar gi;
  generate
    for (gi = 1; gi < 8; gi = gi + 1) begin : g_qm
      assign q_m[gi] = use_xnor ? ~(q_m[gi-1] ^ d[gi]) : (q_m[gi-1] ^ d[gi]);
    end
  endgenerate
  assign q_m[8] = ~use_xnor;

  // ---- Stage 2: DC balance ----
  // Signed running disparity, in units of bits (the spec's cnt(t)). Bounded
  // well inside [-16, 16], so 5 bits signed is enough.
  reg  signed [4:0] cnt;
  wire [3:0] n1_q = popcount8(q_m[7:0]);
  // n1 - n0 = 2*n1 - 8, as a signed 5-bit value.
  wire signed [4:0] diff = $signed({1'b0, n1_q, 1'b0}) - 5'sd8;

  always @(posedge clk) begin
    if (rst) begin
      cnt  <= 5'sd0;
      dout <= 10'b1101010100;
    end else if (!de) begin
      cnt <= 5'sd0;
      case (c)
        2'b00: dout <= 10'b1101010100;
        2'b01: dout <= 10'b0010101011;
        2'b10: dout <= 10'b0101010100;
        default: dout <= 10'b1010101011;
      endcase
    end else if (cnt == 5'sd0 || diff == 5'sd0) begin
      dout[9]   <= ~q_m[8];
      dout[8]   <= q_m[8];
      dout[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
      cnt <= q_m[8] ? (cnt + diff) : (cnt - diff);
    end else if ((cnt > 5'sd0 && diff > 5'sd0) || (cnt < 5'sd0 && diff < 5'sd0)) begin
      dout[9]   <= 1'b1;
      dout[8]   <= q_m[8];
      dout[7:0] <= ~q_m[7:0];
      cnt <= cnt + (q_m[8] ? 5'sd2 : 5'sd0) - diff;
    end else begin
      dout[9]   <= 1'b0;
      dout[8]   <= q_m[8];
      dout[7:0] <= q_m[7:0];
      cnt <= cnt - (q_m[8] ? 5'sd0 : 5'sd2) + diff;
    end
  end

endmodule
`default_nettype wire
