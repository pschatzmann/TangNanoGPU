`timescale 1ns / 1ps
`default_nettype none
//
// Small asynchronous FIFO (Gray-coded pointers, 2-flop synchronisers),
// used to carry received SPI bytes from the SCK clock domain into the
// system clock domain.
//
// The write side is clocked by SCK, which stops between transactions -
// that is fine: a word and its write-pointer update are both registered
// on the SCK edge that completes the word, and the read side only needs
// its own clock to see the new pointer.
//
// Storage is plain flip-flops (DEPTH x W), read combinationally on the
// read side, so no dual-clock RAM primitive is needed.
//
module async_fifo #(
    parameter integer W  = 9,
    parameter integer AW = 4         // depth = 2**AW
) (
    input  wire         rst,         // asynchronous, both domains

    input  wire         wclk,
    input  wire         we,
    input  wire [W-1:0] wdata,
    output wire         full,

    input  wire         rclk,
    input  wire         re,
    output wire [W-1:0] rdata,
    output wire         empty
);

  reg [W-1:0] mem [0:(1<<AW)-1];

  // write side (binary + Gray pointer)
  // initial values: the write clock (SCK) may never tick while the
  // asynchronous reset is active, so the reset alone can't be relied on
  reg  [AW:0] wbin = 0, wgray = 0;
  wire [AW:0] wbin_n  = wbin + 1'b1;
  wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
  reg  [AW:0] rgray_w1 = 0, rgray_w2 = 0;   // read pointer synchronised into wclk

  // read side
  reg  [AW:0] rbin = 0, rgray = 0;
  wire [AW:0] rbin_n  = rbin + 1'b1;
  wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;
  reg  [AW:0] wgray_r1 = 0, wgray_r2 = 0;   // write pointer synchronised into rclk

  assign full  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
  assign empty = (rgray == wgray_r2);
  assign rdata = mem[rbin[AW-1:0]];

  always @(posedge wclk or posedge rst) begin
    if (rst) begin
      wbin  <= {(AW+1){1'b0}};
      wgray <= {(AW+1){1'b0}};
    end else if (we && !full) begin
      wbin  <= wbin_n;
      wgray <= wgray_n;
    end
  end

  always @(posedge wclk)
    if (we && !full) mem[wbin[AW-1:0]] <= wdata;

  always @(posedge wclk or posedge rst) begin
    if (rst) begin
      rgray_w1 <= {(AW+1){1'b0}};
      rgray_w2 <= {(AW+1){1'b0}};
    end else begin
      rgray_w1 <= rgray;
      rgray_w2 <= rgray_w1;
    end
  end

  always @(posedge rclk or posedge rst) begin
    if (rst) begin
      rbin     <= {(AW+1){1'b0}};
      rgray    <= {(AW+1){1'b0}};
      wgray_r1 <= {(AW+1){1'b0}};
      wgray_r2 <= {(AW+1){1'b0}};
    end else begin
      wgray_r1 <= wgray;
      wgray_r2 <= wgray_r1;
      if (re && !empty) begin
        rbin  <= rbin_n;
        rgray <= rgray_n;
      end
    end
  end

endmodule
`default_nettype wire
