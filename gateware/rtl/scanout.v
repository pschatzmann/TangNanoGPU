`timescale 1ns / 1ps
`default_nettype none
//
// Background framebuffer scanout: 320x240 RGB565 framebuffer in SDRAM ->
// 640x480@60 video, each source pixel doubled horizontally and vertically.
//
// Framebuffer layout (docs/architecture.md): one SDRAM row (256 x 32-bit
// words = 512 pixels) per framebuffer line, so source line t of buffer b is
// SDRAM row (b*256 + t) and its 320 pixels are columns 0..159 - one
// row-local burst, no address multiply. Word = {pixel 2k+1, pixel 2k}.
//
// Two clock domains:
//   pixel side (clk_pix): video_timing, line-buffer read, RGB565->888.
//   sys side   (clk):     SDRAM burst fetch into the line buffer.
// Source line t is fetched into line-buffer half t[0] while line t-1 is
// on screen from the other half (two video lines = ~63us of slack). The
// pixel side requests line t with a toggle + a line number that stays
// stable until the next request, so a plain 2-FF toggle synchroniser is a
// safe crossing.
//
// The front buffer is only switched when line 0 is requested (vertical
// blanking), so SHOW never tears.
//
module scanout #(
    parameter integer FB_LINES = 240,
    parameter integer FB_WORDS = 160
) (
    // ---- sys domain ----
    input  wire        clk,
    input  wire        rst,
    input  wire        show_buf,     // requested front buffer (latched at frame start)
    output reg         front_buf,    // buffer currently on screen
    output reg         frame_start,  // 1-cycle pulse when a new frame begins scanout
    output reg         late,         // sticky: a line was requested before the previous fetch finished
    input  wire        clear_late,

    // SDRAM port A (read-only, highest priority) - see sdram_ctrl.v
    output reg         a_req,
    output wire [20:0] a_addr,
    output wire [8:0]  a_len,
    input  wire        a_ack,
    input  wire        a_rvalid,
    input  wire [31:0] a_rdata,
    input  wire        a_done,

    // ---- pixel domain ----
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire        test_pattern, // 1 = colour bars instead of the framebuffer
    output reg         de,
    output reg         hsync_n,
    output reg         vsync_n,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

  // ===================== pixel side =====================
  wire [9:0] hc, vc;
  wire       de0, hs0, vs0;

  video_timing u_timing (
      .clk(clk_pix), .rst(rst_pix),
      .hc(hc), .vc(vc), .de(de0), .hsync_n(hs0), .vsync_n(vs0)
  );

  // Line requests: at the start of video line vc (hc == 0)
  //   vc even, vc < 480: line vc/2 is starting -> prefetch line vc/2 + 1
  //   vc == 524 (last blank line): prefetch line 0 for the next frame
  reg       req_tog_pix = 1'b0;
  reg [7:0] req_line_pix = 8'd0;
  wire [8:0] next_line = {1'b0, vc[9:1]} + 9'd1;

  always @(posedge clk_pix) begin
    if (rst_pix) begin
      req_tog_pix  <= 1'b0;
      req_line_pix <= 8'd0;
    end else if (hc == 10'd0) begin
      if (vc == 10'd524) begin
        req_line_pix <= 8'd0;
        req_tog_pix  <= ~req_tog_pix;
      end else if (vc < 10'd480 && !vc[0] && next_line < FB_LINES) begin
        req_line_pix <= next_line[7:0];
        req_tog_pix  <= ~req_tog_pix;
      end
    end
  end

  // Line buffer read: half = source line's lsb = vc[1], word = hc / 4.
  wire [31:0] lb_rdata;
  wire [8:0]  lb_raddr = {vc[1], hc[9:2]};

  // Pipeline stage 1 (BRAM output valid)
  reg       de1, hs1, vs1, sel1;
  reg [9:0] hc1;
  always @(posedge clk_pix) begin
    de1  <= de0;
    hs1  <= hs0;
    vs1  <= vs0;
    sel1 <= hc[1];
    hc1  <= hc;
  end

  wire [15:0] px565 = sel1 ? lb_rdata[31:16] : lb_rdata[15:0];

  // Colour bars (white, yellow, cyan, green, magenta, red, blue, black)
  wire [2:0] bar_idx = (hc1 < 10'd80)  ? 3'd0 : (hc1 < 10'd160) ? 3'd1 :
                       (hc1 < 10'd240) ? 3'd2 : (hc1 < 10'd320) ? 3'd3 :
                       (hc1 < 10'd400) ? 3'd4 : (hc1 < 10'd480) ? 3'd5 :
                       (hc1 < 10'd560) ? 3'd6 : 3'd7;
  wire bar_r = (bar_idx == 3'd0) | (bar_idx == 3'd1) | (bar_idx == 3'd4) | (bar_idx == 3'd5);
  wire bar_g = (bar_idx == 3'd0) | (bar_idx == 3'd1) | (bar_idx == 3'd2) | (bar_idx == 3'd3);
  wire bar_b = (bar_idx == 3'd0) | (bar_idx == 3'd2) | (bar_idx == 3'd4) | (bar_idx == 3'd6);

  // Pipeline stage 2: registered RGB888 + syncs
  always @(posedge clk_pix) begin
    de      <= de1;
    hsync_n <= hs1;
    vsync_n <= vs1;
    if (!de1) begin
      r <= 8'd0; g <= 8'd0; b <= 8'd0;
    end else if (test_pattern) begin
      r <= {8{bar_r}}; g <= {8{bar_g}}; b <= {8{bar_b}};
    end else begin
      r <= {px565[15:11], px565[15:13]};
      g <= {px565[10:5],  px565[10:9]};
      b <= {px565[4:0],   px565[4:2]};
    end
  end

  // ===================== sys side =====================
  reg [2:0] tog_sync = 3'b000;
  always @(posedge clk) tog_sync <= {tog_sync[1:0], req_tog_pix};
  wire req_edge = tog_sync[2] ^ tog_sync[1];

  reg [7:0] fetch_line;
  reg       busy;        // a fetch is in flight (req pending or data streaming)
  reg [7:0] col;

  assign a_addr = {4'd0, front_buf, fetch_line, 8'd0};
  assign a_len  = FB_WORDS[8:0];

  always @(posedge clk) begin
    frame_start <= 1'b0;
    if (rst) begin
      a_req      <= 1'b0;
      busy       <= 1'b0;
      front_buf  <= 1'b0;
      late       <= 1'b0;
      fetch_line <= 8'd0;
      col        <= 8'd0;
    end else begin
      if (clear_late) late <= 1'b0;

      if (req_edge) begin
        // req_line_pix has been stable for a whole video line: safe to sample.
        fetch_line <= req_line_pix;
        if (req_line_pix == 8'd0) begin
          front_buf   <= show_buf;
          frame_start <= 1'b1;
        end
        if (busy && !clear_late) late <= 1'b1;
        a_req <= 1'b1;
        busy  <= 1'b1;
        col   <= 8'd0;
      end else begin
        if (a_ack) a_req <= 1'b0;
        if (a_rvalid) col <= col + 8'd1;
        if (a_done) busy <= 1'b0;
      end
    end
  end

  bram_sdp #(.AW(9), .DW(32)) u_lb (
      .wclk(clk), .we(a_rvalid), .waddr({fetch_line[0], col}), .wdata(a_rdata),
      .rclk(clk_pix), .raddr(lb_raddr), .rdata(lb_rdata)
  );

endmodule
`default_nettype wire
