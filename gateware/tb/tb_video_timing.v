`timescale 1ns / 1ps
//
// video_timing.v: one full frame must be 800x525 clocks with 640x480 data
// enable, a 96-clock hsync starting at pixel 656 and a 2-line vsync
// starting at line 490 (VESA 640x480@60).
//
module tb_video_timing;
  reg clk = 0;
  always #19.84 clk = ~clk;  // 25.2MHz
  reg rst = 1;
  wire [9:0] hc, vc;
  wire de, hs, vs;

  video_timing dut (.clk(clk), .rst(rst), .hc(hc), .vc(vc), .de(de),
                    .hsync_n(hs), .vsync_n(vs));

  integer errors = 0;
  integer total = 0, de_cnt = 0, hs_cnt = 0, vs_lines = 0;
  integer first_hs_x = -1, first_vs_y = -1;

  initial begin
    repeat (3) @(posedge clk);
    rst <= 0;
    @(posedge clk);
    while (!(hc == 0 && vc == 0)) @(posedge clk);
    repeat (800 * 525) begin
      total = total + 1;
      if (de) de_cnt = de_cnt + 1;
      if (!hs && vc == 0) begin
        hs_cnt = hs_cnt + 1;
        if (first_hs_x < 0) first_hs_x = hc;
      end
      if (!vs && hc == 0) begin
        vs_lines = vs_lines + 1;
        if (first_vs_y < 0) first_vs_y = vc;
      end
      @(posedge clk);
    end
    if (!(hc == 0 && vc == 0)) begin $display("FAIL: frame length"); errors = errors + 1; end
    if (de_cnt != 640 * 480) begin $display("FAIL: de count %0d", de_cnt); errors = errors + 1; end
    if (hs_cnt != 96 || first_hs_x != 656) begin
      $display("FAIL: hsync %0d @ %0d", hs_cnt, first_hs_x); errors = errors + 1;
    end
    if (vs_lines != 2 || first_vs_y != 490) begin
      $display("FAIL: vsync %0d @ %0d", vs_lines, first_vs_y); errors = errors + 1;
    end
    if (errors == 0) $display("PASS tb_video_timing");
    else             $display("FAIL tb_video_timing: %0d errors", errors);
    $finish;
  end
endmodule
