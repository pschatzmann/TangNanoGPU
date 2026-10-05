`timescale 1ns / 1ps
//
// tmds_encoder.v: every symbol must decode back to its input byte (DVI
// decoder rule: bit 9 = inverted, bit 8 = XOR vs XNOR), the running DC
// disparity must stay bounded, and control periods must emit the four
// DVI control codes.
//
module tb_tmds;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  reg de = 0;
  reg [7:0] d = 0;
  reg [1:0] c = 0;
  wire [9:0] q;

  tmds_encoder dut (.clk(clk), .rst(rst), .de(de), .d(d), .c(c), .dout(q));

  function [7:0] decode(input [9:0] s);
    reg [7:0] v;
    integer i;
    begin
      v = s[9] ? ~s[7:0] : s[7:0];
      decode[0] = v[0];
      for (i = 1; i < 8; i = i + 1)
        decode[i] = s[8] ? (v[i] ^ v[i-1]) : ~(v[i] ^ v[i-1]);
    end
  endfunction

  function integer ones(input [9:0] s);
    integer i;
    begin
      ones = 0;
      for (i = 0; i < 10; i = i + 1) ones = ones + s[i];
    end
  endfunction

  integer errors = 0, n, disp = 0, maxdisp = 0;
  reg [7:0] prev_d;
  reg prev_de;
  reg [1:0] prev_c;
  integer seed = 1;

  initial begin
    repeat (3) @(posedge clk);
    rst <= 0;
    prev_de = 0;
    for (n = 0; n < 20000; n = n + 1) begin
      @(posedge clk);
      // check the symbol produced from the previous inputs
      #1;
      if (n > 1) begin
        if (prev_de) begin
          if (decode(q) !== prev_d) begin
            $display("FAIL decode: d=%h sym=%b got %h", prev_d, q, decode(q));
            errors = errors + 1;
          end
          disp = disp + 2 * ones(q) - 10;
          if (disp > maxdisp) maxdisp = disp;
          if (-disp > maxdisp) maxdisp = -disp;
        end else begin
          disp = 0;
          case (prev_c)
            2'b00: if (q !== 10'b1101010100) errors = errors + 1;
            2'b01: if (q !== 10'b0010101011) errors = errors + 1;
            2'b10: if (q !== 10'b0101010100) errors = errors + 1;
            2'b11: if (q !== 10'b1010101011) errors = errors + 1;
          endcase
        end
      end
      // next stimulus (applied after the edge, sampled at the next one):
      // long data bursts of random and constant values
      de = (n % 1000) < 800;
      d  = (n % 3000 < 1500) ? $random(seed) : 8'h00 + (n / 100);
      c  = $random(seed);
      prev_d = d; prev_de = de; prev_c = c;
    end
    if (maxdisp > 20) begin
      $display("FAIL: DC disparity reached %0d", maxdisp);
      errors = errors + 1;
    end
    if (errors == 0) $display("PASS tb_tmds (max disparity %0d)", maxdisp);
    else             $display("FAIL tb_tmds: %0d errors", errors);
    $finish;
  end
endmodule
