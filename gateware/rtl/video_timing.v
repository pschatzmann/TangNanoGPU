`timescale 1ns / 1ps
`default_nettype none
//
// 640x480@60 (VESA DMT / CEA-861 format 1) raster counters, 25.2MHz pixel
// clock (nominal 25.175MHz - every sink tested by the wider community locks
// to 25.2MHz). Both syncs are active low.
//
//   H: 640 active + 16 front porch + 96 sync + 48 back porch = 800
//   V: 480 active + 10 front porch +  2 sync + 33 back porch = 525
//
// hc/vc are the raw counters; de/hsync/vsync are registered so all
// outputs refer to the same (hc, vc) pixel.
//
module video_timing #(
    parameter integer H_ACTIVE = 640,
    parameter integer H_FP     = 16,
    parameter integer H_SYNC   = 96,
    parameter integer H_BP     = 48,
    parameter integer V_ACTIVE = 480,
    parameter integer V_FP     = 10,
    parameter integer V_SYNC   = 2,
    parameter integer V_BP     = 33
) (
    input  wire       clk,
    input  wire       rst,
    output reg  [9:0] hc,
    output reg  [9:0] vc,
    output wire       de,      // combinational from hc/vc
    output wire       hsync_n, // combinational from hc
    output wire       vsync_n  // combinational from vc
);

  localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
  localparam integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

  always @(posedge clk) begin
    if (rst) begin
      hc <= 10'd0;
      vc <= 10'd0;
    end else if (hc == H_TOTAL - 1) begin
      hc <= 10'd0;
      vc <= (vc == V_TOTAL - 1) ? 10'd0 : vc + 10'd1;
    end else begin
      hc <= hc + 10'd1;
    end
  end

  assign de      = (hc < H_ACTIVE) && (vc < V_ACTIVE);
  assign hsync_n = ~((hc >= H_ACTIVE + H_FP) && (hc < H_ACTIVE + H_FP + H_SYNC));
  assign vsync_n = ~((vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC));

endmodule
`default_nettype wire
