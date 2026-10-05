`timescale 1ns / 1ps
//
// sdram_ctrl.v against sdram_model.v:
//   1. full-row write burst (256 words) on port B, read back on port A
//   2. byte-enable masked write burst, read back on port B
//   3. single-word accesses in several banks/rows
//   4. port A and B requesting in the same cycle (A must win, B must
//      still complete)
//   5. refresh keeps happening and never collides (model reports errors)
//
module tb_sdram_ctrl;
  reg clk = 0;
  always #7.716 clk = ~clk;  // 64.8MHz
  wire clk_sdram = ~clk;
  reg rst = 1;

  wire ready;
  reg         a_req = 0;
  reg  [20:0] a_addr = 0;
  reg  [8:0]  a_len = 0;
  wire        a_ack, a_rvalid, a_done;
  reg         b_req = 0, b_we = 0;
  reg  [20:0] b_addr = 0;
  reg  [8:0]  b_len = 0;
  reg  [31:0] b_wdata = 0;
  reg  [3:0]  b_wbe = 4'hf;
  wire        b_ack, b_wpull, b_rvalid, b_done;
  wire [31:0] rdata;

  wire [31:0] DQ;
  wire [10:0] A;
  wire [1:0]  BA;
  wire nCS, nWE, nRAS, nCAS, SCLK, CKE;
  wire [3:0] DQM;

  sdram_ctrl #(.FREQ(64_800_000), .INIT_US(2)) dut (
      .clk(clk), .clk_sdram(clk_sdram), .rst(rst), .ready(ready),
      .a_req(a_req), .a_addr(a_addr), .a_len(a_len), .a_ack(a_ack),
      .a_rvalid(a_rvalid), .a_done(a_done),
      .b_req(b_req), .b_we(b_we), .b_addr(b_addr), .b_len(b_len),
      .b_wdata(b_wdata), .b_wbe(b_wbe), .b_ack(b_ack), .b_wpull(b_wpull),
      .b_rvalid(b_rvalid), .b_done(b_done), .rdata(rdata),
      .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
      .SDRAM_CLK(SCLK), .SDRAM_CKE(CKE), .SDRAM_DQM(DQM)
  );

  sdram_model #(.CAS(2)) mem (
      .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
      .SDRAM_CLK(SCLK), .SDRAM_CKE(CKE), .SDRAM_DQM(DQM)
  );

  integer errors = 0;
  integer k;
  reg [31:0] got [0:255];
  integer ngot;

  function [31:0] pattern(input [20:0] addr, input integer salt);
    pattern = {addr[15:0] ^ salt[15:0], ~addr[15:0]} + salt;
  endfunction

  // Port B write burst; data = pattern(addr+k), byte enables from be_fn
  task b_write(input [20:0] addr, input [8:0] len, input integer salt, input [3:0] be);
    integer n;
    reg pulled;
    begin
      @(posedge clk);
      b_req <= 1; b_we <= 1; b_addr <= addr; b_len <= len;
      n = 0;
      b_wdata <= pattern(addr, salt);
      b_wbe   <= be;
      while (n < len) begin
        @(negedge clk);
        pulled = b_wpull;  // combinational: sample it before the edge that consumes the word
        @(posedge clk);
        if (b_ack) b_req <= 0;
        if (pulled) begin
          n = n + 1;
          b_wdata <= pattern(addr + n, salt);
        end
      end
      while (!b_done) @(posedge clk);
    end
  endtask

  task a_read(input [20:0] addr, input [8:0] len);
    begin
      @(posedge clk);
      a_req <= 1; a_addr <= addr; a_len <= len;
      ngot = 0;
      while (1) begin
        @(posedge clk);
        if (a_ack) a_req <= 0;
        if (a_rvalid) begin got[ngot] = rdata; ngot = ngot + 1; end
        if (a_done) disable a_read;
      end
    end
  endtask

  task b_read(input [20:0] addr, input [8:0] len);
    begin
      @(posedge clk);
      b_req <= 1; b_we <= 0; b_addr <= addr; b_len <= len;
      ngot = 0;
      while (1) begin
        @(posedge clk);
        if (b_ack) b_req <= 0;
        if (b_rvalid) begin got[ngot] = rdata; ngot = ngot + 1; end
        if (b_done) disable b_read;
      end
    end
  endtask

  task expect_n(input integer n);
    if (ngot != n) begin
      $display("FAIL: got %0d words, expected %0d", ngot, n);
      errors = errors + 1;
    end
  endtask

  reg [31:0] exp;
  integer t0;

  initial begin
    repeat (5) @(posedge clk);
    rst <= 0;
    while (!ready) @(posedge clk);

    // 1. full row
    t0 = $time;
    b_write({2'd1, 11'd5, 8'd0}, 9'd256, 7, 4'hf);
    $display("256-word write burst took %0d cycles", ($time - t0) / 15);
    t0 = $time;
    a_read({2'd1, 11'd5, 8'd0}, 9'd256);
    $display("256-word read burst took %0d cycles", ($time - t0) / 15);
    expect_n(256);
    for (k = 0; k < 256; k = k + 1)
      if (got[k] !== pattern({2'd1, 11'd5, 8'd0} + k, 7)) begin
        $display("FAIL row read k=%0d got %h exp %h", k, got[k], pattern({2'd1, 11'd5, 8'd0} + k, 7));
        errors = errors + 1;
      end

    // 2. masked overwrite of columns 10..19 with only the low half (bytes 0,1)
    b_write({2'd1, 11'd5, 8'd10}, 9'd10, 99, 4'b0011);
    b_read({2'd1, 11'd5, 8'd8}, 9'd14);
    expect_n(14);
    for (k = 0; k < 14; k = k + 1) begin
      exp = pattern({2'd1, 11'd5, 8'd8} + k, 7);
      if (k >= 2 && k < 12) exp[15:0] = pattern({2'd1, 11'd5, 8'd8} + k, 99) & 32'hffff;
      if (got[k] !== exp) begin
        $display("FAIL masked k=%0d got %h exp %h", k, got[k], exp);
        errors = errors + 1;
      end
    end

    // 3. single words in other banks
    b_write({2'd0, 11'd0, 8'd255}, 9'd1, 3, 4'hf);
    b_write({2'd3, 11'd2047, 8'd0}, 9'd1, 4, 4'hf);
    a_read({2'd0, 11'd0, 8'd255}, 9'd1);
    if (got[0] !== pattern({2'd0, 11'd0, 8'd255}, 3)) begin $display("FAIL single 0"); errors = errors + 1; end
    a_read({2'd3, 11'd2047, 8'd0}, 9'd1);
    if (got[0] !== pattern({2'd3, 11'd2047, 8'd0}, 4)) begin $display("FAIL single 1"); errors = errors + 1; end

    // 4. simultaneous requests: B write while A reads row 5
    fork
      a_read({2'd1, 11'd5, 8'd100}, 9'd20);
      b_write({2'd2, 11'd9, 8'd0}, 9'd64, 11, 4'hf);
    join
    b_read({2'd2, 11'd9, 8'd0}, 9'd64);
    expect_n(64);
    for (k = 0; k < 64; k = k + 1)
      if (got[k] !== pattern({2'd2, 11'd9, 8'd0} + k, 11)) begin
        $display("FAIL concurrent k=%0d", k); errors = errors + 1;
      end

    // 5. let refresh run for a while
    repeat (3000) @(posedge clk);
    if (mem.refs < 4) begin $display("FAIL: only %0d refreshes", mem.refs); errors = errors + 1; end

    errors = errors + mem.errors;
    if (errors == 0) $display("PASS tb_sdram_ctrl (refreshes=%0d)", mem.refs);
    else             $display("FAIL tb_sdram_ctrl: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL tb_sdram_ctrl: timeout");
    $finish;
  end
endmodule
