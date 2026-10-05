`timescale 1ns / 1ps
`default_nettype none
//
// bram_sdp: simple dual-port block RAM - one write-only port, one
// read-only port with a 1-cycle registered output, independent clocks.
//
// Why a hand-instantiated wrapper instead of an inferred `reg mem[]`:
// yosys 0.33 (the distribution version) maps an inferred simple-dual-port
// memory onto the old SDPX9/DPX9 cell names, which nextpnr-himbaechel 0.11
// cannot place ("no BELs remaining to implement cell type 'SDPX9'") -
// measured on this design. Gowin's SDPB primitive, instantiated directly,
// is what Apicula's own examples (SDPB-video-ram.v) use and places fine.
//
// Supported widths are the SDPB data widths 8, 16 and 32 (no byte enables,
// which sidesteps Gowin's 9-bit byte-enable granularity entirely). One
// SDPB holds 16Kbit, i.e. 2048x8 / 1024x16 / 512x32; deeper memories are
// built from several blocks, selected by the top address bits.
//
// tools/fix_bram_oce.py is not needed for these (OCE is tied high here),
// but stays in the flow for any memory yosys infers on its own.
//
module bram_sdp #(
    parameter integer AW = 9,
    parameter integer DW = 32
) (
    input  wire          wclk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,

    input  wire          rclk,
    input  wire [AW-1:0] raddr,
    output wire [DW-1:0] rdata
);

`ifdef SIMULATION
  reg [DW-1:0] mem [0:(1<<AW)-1];
  reg [DW-1:0] q;
  always @(posedge wclk) if (we) mem[waddr] <= wdata;
  always @(posedge rclk) q <= mem[raddr];
  assign rdata = q;
`else
  // address bits one block covers at this width
  localparam integer BAW = (DW == 8) ? 11 : (DW == 16) ? 10 : 9;
  localparam integer LSB = 14 - BAW;                 // ADx[LSB-1:0] = 0
  localparam integer NB  = (AW > BAW) ? (1 << (AW - BAW)) : 1;
  localparam integer UAW = (AW > BAW) ? BAW : AW;    // address bits used per block

  wire [13:0] ada = {{(BAW-UAW){1'b0}}, waddr[UAW-1:0], {LSB{1'b0}}};
  wire [13:0] adb = {{(BAW-UAW){1'b0}}, raddr[UAW-1:0], {LSB{1'b0}}};

  wire [31:0] dout [0:NB-1];
  genvar bi;
  generate
    for (bi = 0; bi < NB; bi = bi + 1) begin : g_blk
      wire sel_w;
      if (NB > 1) begin : g_sel
        assign sel_w = (waddr[AW-1:BAW] == bi);
      end else begin : g_one
        assign sel_w = 1'b1;
      end
      SDPB #(
          .READ_MODE(1'b0),
          .BIT_WIDTH_0(DW),
          .BIT_WIDTH_1(DW),
          .BLK_SEL_0(3'b000),
          .BLK_SEL_1(3'b000),
          .RESET_MODE("SYNC")
      ) u_mem (
          .DO(dout[bi]),
          .DI({{(32-DW){1'b0}}, wdata}),
          .ADA(ada), .ADB(adb),
          .CLKA(wclk), .CLKB(rclk),
          .CEA(we & sel_w), .CEB(1'b1), .OCE(1'b1),
          .BLKSELA(3'b000), .BLKSELB(3'b000),
          .RESETA(1'b0), .RESETB(1'b0)
      );
    end
  endgenerate

  if (NB > 1) begin : g_mux
    reg [AW-BAW-1:0] rsel;
    always @(posedge rclk) rsel <= raddr[AW-1:BAW];
    assign rdata = dout[rsel][DW-1:0];
  end else begin : g_nomux
    assign rdata = dout[0][DW-1:0];
  end
`endif

endmodule
`default_nettype wire
