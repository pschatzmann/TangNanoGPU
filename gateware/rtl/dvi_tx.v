`timescale 1ns / 1ps
`default_nettype none
//
// DVI transmitter: three TMDS encoders + Gowin OSER10 10:1 serialisers +
// true-LVDS output buffers, matching the structure of Apicula's own
// Tang Nano 20K DVI example (examples/DVI/dvi-example.v), which is known
// to work with the open-source yosys/nextpnr-himbaechel/gowin_pack flow.
//
// clk_pix_x5 is 5x the pixel clock; OSER10 shifts on both of its edges
// (DDR), giving the 10x bit rate. The TMDS clock pair carries clk_pix.
//
// Channel mapping (DVI): 0 = blue + {vsync, hsync}, 1 = green, 2 = red.
//
module dvi_tx (
    input  wire       clk_pix,
    input  wire       clk_pix_x5,
    input  wire       rst,
    input  wire       de,
    input  wire       hsync_n,
    input  wire       vsync_n,
    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

  wire [9:0] sym [0:2];

  // DVI sync bits are the raw (active-low for 640x480) sync levels.
  tmds_encoder u_enc0 (.clk(clk_pix), .rst(rst), .de(de), .d(b),
                       .c({vsync_n, hsync_n}), .dout(sym[0]));
  tmds_encoder u_enc1 (.clk(clk_pix), .rst(rst), .de(de), .d(g),
                       .c(2'b00), .dout(sym[1]));
  tmds_encoder u_enc2 (.clk(clk_pix), .rst(rst), .de(de), .d(r),
                       .c(2'b00), .dout(sym[2]));

  wire [2:0] ser;

`ifdef SIMULATION
  // Behavioural stand-in for simulation: just expose the parallel symbols
  // through a trivial serialiser so testbenches can link the top level.
  reg [9:0] sh [0:2];
  reg [3:0] bitn = 4'd0;
  integer k;
  always @(posedge clk_pix_x5) begin
    bitn <= (bitn == 4'd4) ? 4'd0 : bitn + 4'd1;
    for (k = 0; k < 3; k = k + 1)
      if (bitn == 4'd0) sh[k] <= sym[k];
      else              sh[k] <= sh[k] >> 2;
  end
  assign ser = {sh[2][0], sh[1][0], sh[0][0]};
  assign tmds_d_p   = ser;
  assign tmds_d_n   = ~ser;
  assign tmds_clk_p = clk_pix;
  assign tmds_clk_n = ~clk_pix;
`else
  genvar ch;
  generate
    for (ch = 0; ch < 3; ch = ch + 1) begin : g_ser
      OSER10 u_ser (
          .Q(ser[ch]),
          .D0(sym[ch][0]), .D1(sym[ch][1]), .D2(sym[ch][2]), .D3(sym[ch][3]),
          .D4(sym[ch][4]), .D5(sym[ch][5]), .D6(sym[ch][6]), .D7(sym[ch][7]),
          .D8(sym[ch][8]), .D9(sym[ch][9]),
          .PCLK(clk_pix), .FCLK(clk_pix_x5), .RESET(rst)
      );
    end
  endgenerate

  TLVDS_OBUF u_obuf [3:0] (
      .I ({clk_pix, ser}),
      .O ({tmds_clk_p, tmds_d_p}),
      .OB({tmds_clk_n, tmds_d_n})
  );
`endif

endmodule
`default_nettype wire
