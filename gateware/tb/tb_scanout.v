`timescale 1ns / 1ps
//
// scanout.v end to end: a patterned framebuffer in the SDRAM model is
// fetched by the real sdram_ctrl.v + scanout.v (separate system and pixel
// clocks), and one complete output frame is checked pixel by pixel:
//
//   default    HDMI 640x480@60, 25.2MHz: pixel (x, y) = fb(x/2, y/2)
//   -DLCD      480x272 panel, 9MHz: fb(x-80, y-16) inside the centred
//              320x240 window, black outside
//
// Also checks that no line fetch was late during the checked frame.
//
module tb_scanout;
  reg clk = 0;      // 64.8MHz system clock
  always #7.716 clk = ~clk;
`ifdef LCD
  reg clk_pix = 0;  // 9MHz
  always #55.556 clk_pix = ~clk_pix;
  localparam integer HA = 480, VA = 272, X0 = 80, Y0 = 16, S = 0;
`else
  reg clk_pix = 0;  // 25.2MHz
  always #19.841 clk_pix = ~clk_pix;
  localparam integer HA = 640, VA = 480, X0 = 0, Y0 = 0, S = 1;
`endif

  reg rst = 1, rst_pix = 1, clear_late = 0;
  wire ready;
  wire a_req, a_ack, a_rvalid, a_done;
  wire [20:0] a_addr;
  wire [8:0]  a_len;
  wire [31:0] rdata;
  wire front_buf, frame_start, late;
  wire de, hs, vs;
  wire [7:0] r, g, b;

  wire [31:0] DQ;
  wire [10:0] A;
  wire [1:0]  BA;
  wire nCS, nWE, nRAS, nCAS, SCLK, CKE;
  wire [3:0] DQM;

  sdram_ctrl #(.FREQ(64_800_000), .INIT_US(2)) u_sdram (
      .clk(clk), .clk_sdram(~clk), .rst(rst), .ready(ready),
      .a_req(a_req), .a_addr(a_addr), .a_len(a_len), .a_ack(a_ack),
      .a_rvalid(a_rvalid), .a_done(a_done),
      .b_req(1'b0), .b_we(1'b0), .b_addr(21'd0), .b_len(9'd0), .b_wdata(32'd0),
      .b_wbe(4'd0), .b_ack(), .b_wpull(), .b_rvalid(), .b_done(),
      .rdata(rdata),
      .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE),
      .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_CLK(SCLK), .SDRAM_CKE(CKE),
      .SDRAM_DQM(DQM)
  );

  sdram_model #(.CAS(2)) mem (
      .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
      .SDRAM_CLK(SCLK), .SDRAM_CKE(CKE), .SDRAM_DQM(DQM)
  );

`ifdef LCD
  scanout #(
      .H_ACTIVE(480), .H_FP(8), .H_SYNC(4), .H_BP(39),
      .V_ACTIVE(272), .V_FP(8), .V_SYNC(4), .V_BP(8),
      .SCALE_SHIFT(0), .X0(80), .Y0(16)
  ) dut (
`else
  scanout dut (
`endif
      .clk(clk), .rst(rst), .show_buf(1'b0), .front_buf(front_buf),
      .frame_start(frame_start), .late(late), .clear_late(clear_late),
      .a_req(a_req), .a_addr(a_addr), .a_len(a_len), .a_ack(a_ack),
      .a_rvalid(a_rvalid), .a_rdata(rdata), .a_done(a_done),
      .clk_pix(clk_pix), .rst_pix(rst_pix), .test_pattern(1'b0),
      .de(de), .hsync_n(hs), .vsync_n(vs), .r(r), .g(g), .b(b)
  );

  // framebuffer pattern (native RGB565)
  function [15:0] fbpix(input integer x, input integer y);
    fbpix = (x * 37 + y * 1031 + ((x ^ y) << 5)) & 16'hffff;
  endfunction
  function [23:0] to888(input [15:0] p);
    to888 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
  endfunction

  integer x, y, errors = 0, pixels = 0, frames = 0;
  integer ox, oy;
  reg     de_d = 0, vs_d = 1, checking = 0;
  reg [23:0] want;

  initial begin
    for (y = 0; y < 240; y = y + 1)
      for (x = 0; x < 320; x = x + 2)
        mem.mem[{2'b00, 3'b000, 1'b0, y[7:0], x[8:1]}] = {fbpix(x + 1, y), fbpix(x, y)};
    repeat (20) @(posedge clk);
    rst = 0;
    repeat (5) @(posedge clk_pix);
    rst_pix = 0;
  end

  // output pixel coordinates: x counts DE pixels in a line, y counts DE
  // lines since the last vsync (which comes after the active lines)
  always @(posedge clk_pix) begin
    de_d <= de;
    vs_d <= vs;
    if (vs_d && !vs) begin            // vsync starts: a frame is complete
      oy = 0;
      if (checking) begin
        if (pixels != HA * VA) begin
          $display("FAIL: %0d pixels checked, expected %0d", pixels, HA * VA);
          errors = errors + 1;
        end
        if (late) begin $display("FAIL: scanout late during the frame"); errors = errors + 1; end
        if (errors == 0) $display("PASS tb_scanout (%0dx%0d, %0d pixels)", HA, VA, pixels);
        else             $display("FAIL tb_scanout: %0d errors", errors);
        $finish;
      end
      frames = frames + 1;
      if (frames == 2) begin          // check the 2nd complete frame
        checking = 1;
        pixels = 0;
      end
    end
    if (de) begin
      if (!de_d) ox = 0;
      if (checking) begin
        if (ox >= X0 && ox < X0 + (320 << S) && oy >= Y0 && oy < Y0 + (240 << S))
          want = to888(fbpix((ox - X0) >> S, (oy - Y0) >> S));
        else
          want = 24'd0;
        if ({r, g, b} !== want) begin
          if (errors < 10)
            $display("FAIL pixel (%0d,%0d): got %h expected %h", ox, oy, {r, g, b}, want);
          errors = errors + 1;
        end
        pixels = pixels + 1;
      end
      ox = ox + 1;
    end else if (de_d) begin
      oy = oy + 1;
    end
  end

  // clear the start-up "late" flag before the checked frame
  always @(posedge clk) clear_late <= (frames < 2);

  initial begin
    #200_000_000;
    $display("FAIL tb_scanout: timeout");
    $finish;
  end
endmodule
