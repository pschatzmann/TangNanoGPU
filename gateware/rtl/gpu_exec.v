`timescale 1ns / 1ps
`default_nettype none
//
// TangNanoGPU drawing engine: parses the command stream from the command
// FIFO (docs/protocol.md) and renders into the SDRAM framebuffer through
// sdram_ctrl.v's port B.
//
// Everything is reduced to two SDRAM primitives on one framebuffer line
// (= one SDRAM row, see scanout.v):
//
//   span write (SW): words x0/2 .. x1/2 of a row as one write burst. The
//       data is either a constant colour or the "span buffer" (pixels
//       staged at their destination x, each with a valid flag), and every
//       word gets byte enables from the [x0, x1] range and the valid flags
//       - so partial words, colour-keyed sprites and text masks need no
//       read-modify-write.
//   span read (SR): a row-local read burst into the "read buffer", indexed
//       by SDRAM column, for COPY_RECT and READ_RECT.
//
// The rasterisers (fill, Bresenham line, midpoint circle) reproduce the
// integer algorithms of TinyGPU's SurfaceBase.h exactly, so the FPGA's
// output is pixel-identical to a software Surface<RGB565> (verified by
// the golden-model test, see tools/golden/).
//
// Coordinates are signed 16-bit on the wire, widened to 18 bits here;
// clipping is done once per span/pixel against the clip rect, which is
// always kept inside the 320x240 framebuffer, so nothing is ever written
// outside the current target.
//
module gpu_exec #(
    parameter integer FB_W = 320,
    parameter integer FB_H = 240
) (
    input  wire        clk,
    input  wire        rst,

    // command FIFO (first-word-fall-through)
    input  wire        c_valid,
    input  wire [7:0]  c_data,
    output wire        c_pop,

    // response FIFO
    output reg         r_push,
    output reg  [7:0]  r_data,
    input  wire        r_full,

    // SDRAM port B
    output reg         b_req,
    output reg         b_we,
    output reg  [20:0] b_addr,
    output reg  [8:0]  b_len,
    output wire [31:0] b_wdata,
    output wire [3:0]  b_wbe,
    input  wire        b_ack,
    input  wire        b_wpull,
    input  wire        b_rvalid,
    input  wire [31:0] rdata,
    input  wire        b_done,

    // display
    input  wire        frame_start,
    output reg         show_buf,
    output reg         target,

    output wire        idle,
    output reg         bad_opcode     // sticky
);

  // ------------------------------------------------------------------
  // Opcodes and header lengths
  // ------------------------------------------------------------------
  localparam [7:0] OP_SET_TARGET = 8'h10, OP_SHOW = 8'h11, OP_WAIT_VSYNC = 8'h12,
                   OP_SET_CLIP = 8'h13, OP_FILL_RECT = 8'h20, OP_LINE = 8'h21,
                   OP_PIXELS = 8'h22, OP_CIRCLE = 8'h23, OP_WRITE_RECT = 8'h30,
                   OP_UPLOAD = 8'h31, OP_COPY_RECT = 8'h32, OP_MASK = 8'h40,
                   OP_READ_RECT = 8'h50, OP_YUV_MBS = 8'h34;

  function [4:0] hdr_len(input [7:0] op);
    case (op)
      OP_SET_TARGET: hdr_len = 5'd1;
      OP_SHOW:       hdr_len = 5'd1;
      OP_WAIT_VSYNC: hdr_len = 5'd0;
      OP_SET_CLIP:   hdr_len = 5'd8;
      OP_FILL_RECT:  hdr_len = 5'd10;
      OP_LINE:       hdr_len = 5'd10;
      OP_PIXELS:     hdr_len = 5'd2;
      OP_CIRCLE:     hdr_len = 5'd9;
      OP_WRITE_RECT: hdr_len = 5'd11;
      OP_UPLOAD:     hdr_len = 5'd6;
      OP_COPY_RECT:  hdr_len = 5'd17;
      OP_MASK:       hdr_len = 5'd13;
      OP_READ_RECT:  hdr_len = 5'd8;
      OP_YUV_MBS:    hdr_len = 5'd2;
      default:       hdr_len = 5'd31;   // unknown
    endcase
  endfunction

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  localparam [5:0]
    S_IDLE = 6'd0, S_HDR = 6'd1, S_DISPATCH = 6'd2,
    S_SW_START = 6'd3, S_SW_WAIT = 6'd4, S_SR_START = 6'd5, S_SR_WAIT = 6'd6,
    S_GET = 6'd7,
    S_FILL_ROW = 6'd8,
    S_LINE_PLOT = 6'd9, S_LINE_STEP = 6'd10,
    S_PIX_NEXT = 6'd11, S_PIX_PLOT = 6'd12,
    S_CIRC_LOOP = 6'd13, S_CIRC_PT = 6'd14, S_CIRC_SPAN = 6'd15, S_CIRC_STEP = 6'd16,
    S_WR_ROW = 6'd17, S_WR_HI = 6'd18, S_WR_LO = 6'd19, S_WR_FLUSH = 6'd20,
    S_CP_ROW = 6'd21, S_CP_STAGE = 6'd22, S_CP_FLUSH = 6'd23,
    S_MK_ROW = 6'd24, S_MK_PIX = 6'd25, S_MK_FLUSH = 6'd26,
    S_RR_ROW = 6'd27, S_RR_ADDR = 6'd28, S_RR_WAIT = 6'd29, S_RR_HI = 6'd30, S_RR_LO = 6'd31,
    S_VSYNC = 6'd32, S_PLOT = 6'd33, S_HSPAN = 6'd34,
    S_YM_NEXT = 6'd35, S_YM_START = 6'd36, S_YM_C = 6'd37, S_YM_ROW = 6'd38,
    S_YM_PIX = 6'd39, S_YM_DRAIN = 6'd40;

  reg [5:0] state, ret, ret2;

  reg [7:0] op;
  reg [4:0] hlen, hi_idx;
  reg [7:0] h [0:16];

  // header field helpers (ints little-endian, colours high byte first)
  wire signed [17:0] h_s16_0  = {{2{h[1][7]}},  h[1],  h[0]};
  wire signed [17:0] h_s16_2  = {{2{h[3][7]}},  h[3],  h[2]};
  wire signed [17:0] h_s16_4  = {{2{h[5][7]}},  h[5],  h[4]};
  wire signed [17:0] h_s16_6  = {{2{h[7][7]}},  h[7],  h[6]};
  wire signed [17:0] h_s16_10 = {{2{h[11][7]}}, h[11], h[10]};
  wire signed [17:0] h_s16_12 = {{2{h[13][7]}}, h[13], h[12]};
  wire        [15:0] h_u16_0  = {h[1],  h[0]};
  wire        [15:0] h_u16_2  = {h[3],  h[2]};
  wire        [15:0] h_u16_4  = {h[5],  h[4]};
  wire        [15:0] h_u16_6  = {h[7],  h[6]};
  wire        [15:0] h_u16_8  = {h[9],  h[8]};

  // ------------------------------------------------------------------
  // Clip rect (inclusive, always inside the framebuffer). Empty when
  // clx0 > clx1 or cly0 > cly1.
  // ------------------------------------------------------------------
  reg signed [17:0] clx0, clx1, cly0, cly1;

  function signed [17:0] smax(input signed [17:0] a, input signed [17:0] b);
    smax = (a > b) ? a : b;
  endfunction
  function signed [17:0] smin(input signed [17:0] a, input signed [17:0] b);
    smin = (a < b) ? a : b;
  endfunction

  // ------------------------------------------------------------------
  // Command FIFO consumption: only S_HDR, S_GET and the payload states pop
  // ------------------------------------------------------------------
  reg pop_r;
  assign c_pop = pop_r;

  // ------------------------------------------------------------------
  // Span buffer (staged pixels at their destination x) + valid flags
  // ------------------------------------------------------------------
  reg        st_we;
  reg [8:0]  st_x;
  reg [15:0] st_pix;
  reg        st_valid;

  reg  [7:0] widx;                       // span writer: word being presented
  wire [7:0] sp_raddr = widx + {7'd0, b_wpull};
  wire [15:0] sp_e_q, sp_o_q;

  bram_sdp #(.AW(8), .DW(16)) u_span_e (
      .wclk(clk), .we(st_we && !st_x[0]), .waddr(st_x[8:1]), .wdata(st_pix),
      .rclk(clk), .raddr(sp_raddr), .rdata(sp_e_q));
  bram_sdp #(.AW(8), .DW(16)) u_span_o (
      .wclk(clk), .we(st_we && st_x[0]), .waddr(st_x[8:1]), .wdata(st_pix),
      .rclk(clk), .raddr(sp_raddr), .rdata(sp_o_q));

  reg vf_e [0:255];
  reg vf_o [0:255];
  reg vf_e_q, vf_o_q;
  always @(posedge clk) begin
    if (st_we && !st_x[0]) vf_e[st_x[8:1]] <= st_valid;
    if (st_we &&  st_x[0]) vf_o[st_x[8:1]] <= st_valid;
    vf_e_q <= vf_e[sp_raddr];
    vf_o_q <= vf_o[sp_raddr];
  end

  // ------------------------------------------------------------------
  // Span writer
  // ------------------------------------------------------------------
  reg [12:0] sw_row;
  reg [8:0]  sw_x0, sw_x1;
  reg        sw_const;
  reg [15:0] sw_color;

  wire [8:0] pe = {widx, 1'b0};
  wire [8:0] po = {widx, 1'b1};
  wire in_e = (pe >= sw_x0) && (pe <= sw_x1);
  wire in_o = (po >= sw_x0) && (po <= sw_x1);
  wire en_e = in_e && (sw_const || vf_e_q);
  wire en_o = in_o && (sw_const || vf_o_q);
  assign b_wbe   = {en_o, en_o, en_e, en_e};
  assign b_wdata = sw_const ? {sw_color, sw_color} : {sp_o_q, sp_e_q};

  // ------------------------------------------------------------------
  // Read buffer (span reader target), indexed by SDRAM column
  // ------------------------------------------------------------------
  reg  [7:0]  ridx;
  reg  [7:0]  rb_raddr;
  wire [31:0] rb_q;
  bram_sdp #(.AW(8), .DW(32)) u_rbuf (
      .wclk(clk), .we(b_rvalid), .waddr(ridx), .wdata(rdata),
      .rclk(clk), .raddr(rb_raddr), .rdata(rb_q));

  // ------------------------------------------------------------------
  // Working registers
  // ------------------------------------------------------------------
  reg signed [17:0] xs, xe, ys, ye;      // clipped destination rect (inclusive)
  reg signed [17:0] cx, cy;              // generic x/y cursor
  reg signed [17:0] px, py;              // pixel to plot (S_PLOT)
  reg signed [17:0] sxa, sxb, sy_;       // span to draw (S_HSPAN)
  reg signed [17:0] rx0, ry0;            // command origin
  reg        [15:0] rw, rh;              // command size
  reg        [15:0] j;                   // row counter
  reg        [15:0] i;                   // pixel counter
  reg        [15:0] col;                 // colour
  reg        [15:0] key, bg;
  reg               key_en, two_bpp, upload, bottom_up, row_vis;
  reg        [12:0] up_row;              // UPLOAD / COPY source base row
  reg        [15:0] src_x, src_y;
  reg        [7:0]  pix_hi;
  reg        [7:0]  mbits;
  reg        [3:0]  mcnt;
  reg        [15:0] npix;
  reg        [4:0]  get_n, get_i;

  // line
  reg signed [17:0] lx1, ly1, ldx, ldy;
  reg signed [19:0] lerr;
  reg               lsx, lsy;            // 1 = step negative

  // circle
  reg signed [17:0] ox, oy;
  reg signed [19:0] dec;
  reg        [2:0]  k;
  reg               fill;

  wire [12:0] tgt_row = {4'd0, target, 8'd0};

  // Effective clip for PIXELS and flagged WRITE_RECT rows: TinyGPU's
  // setPixel() is not clipped by the clip rect, only by the surface bounds.
  reg noclip;
  wire signed [17:0] ex0 = noclip ? 18'sd0 : clx0;
  wire signed [17:0] ex1 = noclip ? FB_W - 1 : clx1;
  wire signed [17:0] ey0 = noclip ? 18'sd0 : cly0;
  wire signed [17:0] ey1 = noclip ? FB_H - 1 : cly1;

  // Bresenham set-up and step terms (TinyGPU SurfaceBase::drawLine):
  // dx = |x1 - x0|, dy = -|y1 - y0|, err = dx + dy
  wire signed [17:0] l_dx  = (h_s16_4 > h_s16_0) ? (h_s16_4 - h_s16_0) : (h_s16_0 - h_s16_4);
  wire signed [17:0] l_ndy = (h_s16_6 > h_s16_2) ? (h_s16_2 - h_s16_6) : (h_s16_6 - h_s16_2);
  wire signed [19:0] e2 = lerr <<< 1;
  // ($signed: a concatenation is unsigned and would make the compare unsigned)
  wire signed [19:0] ldx_w = $signed({{2{ldx[17]}}, ldx});
  wire signed [19:0] ldy_w = $signed({{2{ldy[17]}}, ldy});
  wire step_x = (e2 >= ldy_w);
  wire step_y = (e2 <= ldx_w);

  assign idle = (state == S_IDLE) && !c_valid;

  // SW / SR helpers
  task start_sw(input [12:0] row, input [8:0] x0, input [8:0] x1,
                input cst, input [15:0] color, input [5:0] ret_state);
    begin
      sw_row   <= row;
      sw_x0    <= x0;
      sw_x1    <= x1;
      sw_const <= cst;
      sw_color <= color;
      ret      <= ret_state;
      state    <= S_SW_START;
    end
  endtask

  task start_sr(input [12:0] row, input [8:0] x0, input [8:0] x1, input [5:0] ret_state);
    begin
      b_addr <= {row, x0[8:1]};
      b_len  <= {1'b0, x1[8:1]} - {1'b0, x0[8:1]} + 9'd1;
      ridx   <= x0[8:1];
      ret    <= ret_state;
      state  <= S_SR_START;
    end
  endtask

  // plot (px, py) with colour col, then continue at ret_state
  task plot(input signed [17:0] x, input signed [17:0] y, input [5:0] ret_state);
    begin
      px    <= x;
      py    <= y;
      ret2  <= ret_state;
      noclip <= 1'b0;
      state <= S_PLOT;
    end
  endtask

  // horizontal span xa..xb at y with colour col (TinyGPU
  // drawHorizontalLineClipped), then continue at ret_state
  task hspan(input signed [17:0] xa, input signed [17:0] xb, input signed [17:0] y,
             input [5:0] ret_state);
    begin
      sxa   <= xa;
      sxb   <= xb;
      sy_   <= y;
      ret2  <= ret_state;
      state <= S_HSPAN;
    end
  endtask

  // circle point / span k for the current (ox, oy)
  reg signed [17:0] cpx, cpy, cxa, cxb;
  always @(*) begin
    cpx = 18'sd0; cpy = 18'sd0; cxa = 18'sd0; cxb = 18'sd0;
    case (k)
      3'd0: begin cpx = cx + ox; cpy = cy + oy; end
      3'd1: begin cpx = cx + oy; cpy = cy + ox; end
      3'd2: begin cpx = cx - oy; cpy = cy + ox; end
      3'd3: begin cpx = cx - ox; cpy = cy + oy; end
      3'd4: begin cpx = cx - ox; cpy = cy - oy; end
      3'd5: begin cpx = cx - oy; cpy = cy - ox; end
      3'd6: begin cpx = cx + oy; cpy = cy - ox; end
      default: begin cpx = cx + ox; cpy = cy - oy; end
    endcase
    case (k[1:0])
      2'd0: begin cxa = cx - ox; cxb = cx + ox; end
      2'd1: begin cxa = cx - ox; cxb = cx + ox; end
      2'd2: begin cxa = cx - oy; cxb = cx + oy; end
      default: begin cxa = cx - oy; cxb = cx + oy; end
    endcase
  end
  wire signed [17:0] cspan_y = (k[1:0] == 2'd0) ? cy + oy :
                               (k[1:0] == 2'd1) ? cy - oy :
                               (k[1:0] == 2'd2) ? cy + ox : cy - ox;

  // COPY_RECT source pixel index for destination x = cx, and the
  // staging pipeline registers (see S_CP_STAGE)
  wire [17:0] cp_q = cx - rx0 + {2'b0, src_x};
  reg         cp_v1, cp_v2;
  reg  [17:0] cp_x1, cp_x2, cp_q1, cp_q2;

  // ------------------------------------------------------------------
  // YUV_MBS: chroma buffer + BT.601 converter
  //
  // One macroblock = 16x16 luma + 8x8 Cb + 8x8 Cr (I420). Payload order
  // per macroblock: x:i16 y:i16, Cb[64], Cr[64], Y[256] (row-major), so
  // the chroma is in place before the luma rows stream through.
  //
  // Conversion: ITU-R BT.601 limited range, the integer formula TinyH264
  // (decoder/h264_rgb.h yuvToRgb8) and most embedded decoders use:
  //   c = Y-16, d = Cb-128, e = Cr-128
  //   R = clip((298c + 409e + 128) >> 8)
  //   G = clip((298c - 100d - 208e + 128) >> 8)
  //   B = clip((298c + 516d + 128) >> 8)
  // The constant products are written as shift-and-add (no multipliers),
  // in two register stages; output packs to RGB565 like TinyH264's
  // toRGB565(): {R[7:3], G[7:2], B[7:3]}.
  // ------------------------------------------------------------------
  reg  [7:0] cbuf [0:127];               // [0..63] Cb, [64..127] Cr, 8x8 each
  reg  [6:0] cidx;
  reg  [7:0] ym_y;                       // luma byte entering the pipeline
  reg        ym_v0, ym_vis0;
  reg  [8:0] ym_x0;
  reg  [2:0] ym_crow, ym_ccol;           // chroma row/column of that pixel
  wire [7:0] ym_cb = cbuf[{1'b0, ym_crow, ym_ccol}];
  wire [7:0] ym_cr = cbuf[{1'b1, ym_crow, ym_ccol}];

  wire signed [9:0] yuv_c = $signed({2'b00, ym_y})  - 10'sd16;
  wire signed [9:0] yuv_d = $signed({2'b00, ym_cb}) - 10'sd128;
  wire signed [9:0] yuv_e = $signed({2'b00, ym_cr}) - 10'sd128;
  function signed [19:0] sx20(input signed [9:0] v);
    sx20 = {{10{v[9]}}, v};
  endfunction
  // 298 = 256+32+8+2, 409 = 256+128+16+8+1, 100 = 64+32+4,
  // 208 = 128+64+16, 516 = 512+4
  wire signed [19:0] c298 = (sx20(yuv_c) <<< 8) + (sx20(yuv_c) <<< 5) + (sx20(yuv_c) <<< 3) + (sx20(yuv_c) <<< 1);
  wire signed [19:0] e409 = (sx20(yuv_e) <<< 8) + (sx20(yuv_e) <<< 7) + (sx20(yuv_e) <<< 4) + (sx20(yuv_e) <<< 3) + sx20(yuv_e);
  wire signed [19:0] d100 = (sx20(yuv_d) <<< 6) + (sx20(yuv_d) <<< 5) + (sx20(yuv_d) <<< 2);
  wire signed [19:0] e208 = (sx20(yuv_e) <<< 7) + (sx20(yuv_e) <<< 6) + (sx20(yuv_e) <<< 4);
  wire signed [19:0] d516 = (sx20(yuv_d) <<< 9) + (sx20(yuv_d) <<< 2);

  reg signed [19:0] p_c, p_e409, p_d100, p_e208, p_d516;
  reg               ym_v1, ym_vis1;
  reg  [8:0]        ym_x1;

  wire signed [19:0] r_s = (p_c + p_e409 + 20'sd128) >>> 8;
  wire signed [19:0] g_s = (p_c - p_d100 - p_e208 + 20'sd128) >>> 8;
  wire signed [19:0] b_s = (p_c + p_d516 + 20'sd128) >>> 8;
  function [7:0] clip8(input signed [19:0] v);
    clip8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
  endfunction
  wire [7:0] r8 = clip8(r_s), g8 = clip8(g_s), b8 = clip8(b_s);

  reg        ym_v2;
  reg [8:0]  ym_x2;
  reg [15:0] ym_rgb;

  always @(posedge clk) begin
    // stage 1: constant products
    p_c    <= c298;
    p_e409 <= e409;
    p_d100 <= d100;
    p_e208 <= e208;
    p_d516 <= d516;
    ym_v1   <= ym_v0;
    ym_vis1 <= ym_vis0;
    ym_x1   <= ym_x0;
    // stage 2: sums, clipping, RGB565 packing
    ym_v2  <= ym_v1 && ym_vis1;
    ym_x2  <= ym_x1;
    ym_rgb <= {r8[7:3], g8[7:2], b8[7:3]};
  end

  reg [15:0] ym_n;    // macroblocks left
  reg [1:0]  ym_wait;

  // ------------------------------------------------------------------
  // Main FSM
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    pop_r  <= 1'b0;
    r_push <= 1'b0;
    st_we  <= 1'b0;
    ym_v0  <= 1'b0;

    if (rst) begin
      state      <= S_IDLE;
      b_req      <= 1'b0;
      b_we       <= 1'b0;
      target     <= 1'b0;
      show_buf   <= 1'b0;
      bad_opcode <= 1'b0;
      clx0 <= 18'sd0;  clx1 <= FB_W - 1;
      cly0 <= 18'sd0;  cly1 <= FB_H - 1;
      widx <= 8'd0;
      ridx <= 8'd0;
      noclip <= 1'b0;
    end else begin
      // YUV converter output -> span buffer (see YUV_MBS above)
      if (ym_v2) begin
        st_we    <= 1'b1;
        st_x     <= ym_x2;
        st_pix   <= ym_rgb;
        st_valid <= 1'b1;
      end
      case (state)

        // ---------------- parsing ----------------
        S_IDLE: begin
          if (c_valid && !pop_r) begin
            op     <= c_data;
            hlen   <= hdr_len(c_data);
            hi_idx <= 5'd0;
            pop_r  <= 1'b1;
            if (hdr_len(c_data) == 5'd31) begin
              bad_opcode <= 1'b1;            // desynchronised: host must RESET
            end else if (hdr_len(c_data) == 5'd0) begin
              state <= S_DISPATCH;
            end else begin
              state <= S_HDR;
            end
          end
        end

        S_HDR: begin
          if (c_valid && !pop_r) begin
            h[hi_idx] <= c_data;
            pop_r     <= 1'b1;
            hi_idx    <= hi_idx + 5'd1;
            if (hi_idx == hlen - 5'd1) state <= S_DISPATCH;
          end
        end

        // read get_n more bytes into h[get_i...], then go to ret
        S_GET: begin
          if (get_n == 5'd0) begin
            state <= ret;
          end else if (c_valid && !pop_r) begin
            h[get_i] <= c_data;
            pop_r    <= 1'b1;
            get_i    <= get_i + 5'd1;
            get_n    <= get_n - 5'd1;
          end
        end

        S_DISPATCH: begin
          case (op)
            OP_SET_TARGET: begin target <= h[0][0]; state <= S_IDLE; end
            OP_SHOW:       begin show_buf <= h[0][0]; state <= S_IDLE; end
            OP_WAIT_VSYNC: state <= S_VSYNC;

            OP_SET_CLIP: begin
              if (h_u16_4 == 16'd0 || h_u16_6 == 16'd0) begin
                clx0 <= 18'sd1; clx1 <= 18'sd0;
                cly0 <= 18'sd1; cly1 <= 18'sd0;
              end else begin
                clx0 <= smax(h_s16_0, 18'sd0);
                clx1 <= smin(h_s16_0 + $signed({2'b0, h_u16_4}) - 18'sd1, FB_W - 1);
                cly0 <= smax(h_s16_2, 18'sd0);
                cly1 <= smin(h_s16_2 + $signed({2'b0, h_u16_6}) - 18'sd1, FB_H - 1);
              end
              state <= S_IDLE;
            end

            OP_FILL_RECT: begin
              col <= {h[8], h[9]};
              xs  <= smax(h_s16_0, clx0);
              xe  <= smin(h_s16_0 + $signed({2'b0, h_u16_4}) - 18'sd1, clx1);
              ys  <= smax(h_s16_2, cly0);
              ye  <= smin(h_s16_2 + $signed({2'b0, h_u16_6}) - 18'sd1, cly1);
              cy  <= smax(h_s16_2, cly0);
              state <= (h_u16_4 == 16'd0 || h_u16_6 == 16'd0) ? S_IDLE : S_FILL_ROW;
            end

            OP_LINE: begin
              col  <= {h[8], h[9]};
              cx   <= h_s16_0;
              cy   <= h_s16_2;
              lx1  <= h_s16_4;
              ly1  <= h_s16_6;
              ldx  <= l_dx;
              ldy  <= l_ndy;
              lsx  <= !(h_s16_0 < h_s16_4);
              lsy  <= !(h_s16_2 < h_s16_6);
              lerr <= {{2{l_dx[17]}}, l_dx} + {{2{l_ndy[17]}}, l_ndy};
              state <= S_LINE_PLOT;
            end

            OP_PIXELS: begin
              npix  <= h_u16_0;
              state <= S_PIX_NEXT;
            end

            OP_CIRCLE: begin
              cx   <= h_s16_0;
              cy   <= h_s16_2;
              col  <= {h[6], h[7]};
              fill <= h[8][0];
              ox   <= $signed({2'b0, h_u16_4});
              oy   <= 18'sd0;
              dec  <= 20'sd1 - $signed({4'b0, h_u16_4});
              state <= S_CIRC_LOOP;
            end

            OP_WRITE_RECT, OP_UPLOAD: begin
              upload <= (op == OP_UPLOAD);
              if (op == OP_UPLOAD) begin
                up_row <= h_u16_0[12:0];
                rw     <= h_u16_2;
                rh     <= h_u16_4;
                rx0    <= 18'sd0;
                ry0    <= 18'sd0;
                key_en <= 1'b0;
                xs     <= 18'sd0;
                xe     <= $signed({2'b0, h_u16_2}) - 18'sd1;
              end else begin
                rx0    <= h_s16_0;
                ry0    <= h_s16_2;
                rw     <= h_u16_4;
                rh     <= h_u16_6;
                key_en <= h[8][0];
                key    <= {h[9], h[10]};
                noclip <= h[8][1];    // flags bit 1: screen bounds only (setPixel runs)
                xs     <= smax(h_s16_0, h[8][1] ? 18'sd0 : clx0);
                xe     <= smin(h_s16_0 + $signed({2'b0, h_u16_4}) - 18'sd1,
                               h[8][1] ? FB_W - 1 : clx1);
              end
              j <= 16'd0;
              if ((op == OP_UPLOAD) ? (h_u16_2 == 16'd0 || h_u16_4 == 16'd0)
                                    : (h_u16_4 == 16'd0 || h_u16_6 == 16'd0))
                state <= S_IDLE;
              else
                state <= S_WR_ROW;
            end

            OP_COPY_RECT: begin
              up_row <= h_u16_0[12:0];
              src_x  <= h_u16_2;
              src_y  <= h_u16_4;
              rw     <= h_u16_6;
              rh     <= h_u16_8;
              rx0    <= h_s16_10;
              ry0    <= h_s16_12;
              key_en <= h[14][0];
              key    <= {h[15], h[16]};
              xs     <= smax(h_s16_10, clx0);
              xe     <= smin(h_s16_10 + $signed({2'b0, h_u16_6}) - 18'sd1, clx1);
              // rows are each read completely before being written, so only
              // the vertical direction matters for overlapping copies
              bottom_up <= ($signed({5'b0, tgt_row}) + h_s16_12) >
                           ($signed({5'b0, h_u16_0[12:0]}) + $signed({2'b0, h_u16_4}));
              j <= 16'd0;
              state <= (h_u16_6 == 16'd0 || h_u16_8 == 16'd0) ? S_IDLE : S_CP_ROW;
            end

            OP_MASK: begin
              rx0     <= h_s16_0;
              ry0     <= h_s16_2;
              rw      <= h_u16_4;
              rh      <= h_u16_6;
              two_bpp <= h[8][0];
              col     <= {h[9], h[10]};
              bg      <= {h[11], h[12]};
              xs      <= smax(h_s16_0, clx0);
              xe      <= smin(h_s16_0 + $signed({2'b0, h_u16_4}) - 18'sd1, clx1);
              j       <= 16'd0;
              state   <= (h_u16_4 == 16'd0 || h_u16_6 == 16'd0) ? S_IDLE : S_MK_ROW;
            end

            OP_YUV_MBS: begin
              ym_n  <= h_u16_0;
              state <= S_YM_NEXT;
            end

            OP_READ_RECT: begin
              rx0 <= $signed({2'b0, h_u16_0});
              ry0 <= $signed({2'b0, h_u16_2});
              rw  <= h_u16_4;
              rh  <= h_u16_6;
              j   <= 16'd0;
              state <= (h_u16_4 == 16'd0 || h_u16_6 == 16'd0) ? S_IDLE : S_RR_ROW;
            end

            default: state <= S_IDLE;
          endcase
        end

        // ---------------- subroutines ----------------
        S_SW_START: begin
          b_req  <= 1'b1;
          b_we   <= 1'b1;
          b_addr <= {sw_row, sw_x0[8:1]};
          b_len  <= {1'b0, sw_x1[8:1]} - {1'b0, sw_x0[8:1]} + 9'd1;
          widx   <= sw_x0[8:1];
          state  <= S_SW_WAIT;
        end
        S_SW_WAIT: begin
          if (b_ack) b_req <= 1'b0;
          if (b_wpull) widx <= widx + 8'd1;
          if (b_done) state <= ret;
        end

        S_SR_START: begin
          b_req <= 1'b1;
          b_we  <= 1'b0;
          state <= S_SR_WAIT;
        end
        S_SR_WAIT: begin
          if (b_ack) b_req <= 1'b0;
          if (b_rvalid) ridx <= ridx + 8'd1;
          if (b_done) state <= ret;
        end

        // clipped single pixel (px, py) in colour col
        // (PIXELS ignores the clip rect, like TinyGPU's setPixel())
        S_PLOT: begin
          if (px >= ex0 && px <= ex1 && py >= ey0 && py <= ey1)
            start_sw(tgt_row | {5'd0, py[7:0]}, px[8:0], px[8:0], 1'b1, col, ret2);
          else
            state <= ret2;
        end

        // clipped horizontal span sxa..sxb at sy_ in colour col
        S_HSPAN: begin
          if (sy_ >= cly0 && sy_ <= cly1 && smax(sxa, clx0) <= smin(sxb, clx1))
            start_sw(tgt_row | {5'd0, sy_[7:0]}, smax(sxa, clx0), smin(sxb, clx1), 1'b1, col, ret2);
          else
            state <= ret2;
        end

        // ---------------- FILL_RECT ----------------
        S_FILL_ROW: begin
          if (xs > xe || cy > ye) state <= S_IDLE;
          else begin
            cy <= cy + 18'sd1;
            start_sw(tgt_row | {5'd0, cy[7:0]}, xs[8:0], xe[8:0], 1'b1, col, S_FILL_ROW);
          end
        end

        // ---------------- LINE (TinyGPU Bresenham) ----------------
        S_LINE_PLOT: plot(cx, cy, S_LINE_STEP);
        S_LINE_STEP: begin
          if (cx == lx1 && cy == ly1) state <= S_IDLE;
          else begin
            lerr <= lerr + (step_x ? ldy_w : 20'sd0) + (step_y ? ldx_w : 20'sd0);
            if (step_x) cx <= lsx ? cx - 18'sd1 : cx + 18'sd1;
            if (step_y) cy <= lsy ? cy - 18'sd1 : cy + 18'sd1;
            state <= S_LINE_PLOT;
          end
        end

        // ---------------- PIXELS ----------------
        S_PIX_NEXT: begin
          if (npix == 16'd0) state <= S_IDLE;
          else begin
            npix  <= npix - 16'd1;
            get_i <= 5'd2;
            get_n <= 5'd6;
            ret   <= S_PIX_PLOT;
            state <= S_GET;
          end
        end
        S_PIX_PLOT: begin
          col <= {h[6], h[7]};
          plot({{2{h[3][7]}}, h[3], h[2]}, {{2{h[5][7]}}, h[5], h[4]}, S_PIX_NEXT);
          noclip <= 1'b1;
        end

        // ---------------- CIRCLE (TinyGPU midpoint) ----------------
        S_CIRC_LOOP: begin
          k <= 3'd0;
          if (ox < oy) state <= S_IDLE;
          else state <= fill ? S_CIRC_SPAN : S_CIRC_PT;
        end
        S_CIRC_PT: begin
          k <= k + 3'd1;
          plot(cpx, cpy, (k == 3'd7) ? S_CIRC_STEP : S_CIRC_PT);
        end
        S_CIRC_SPAN: begin
          k <= k + 3'd1;
          hspan(cxa, cxb, cspan_y, (k == 3'd3) ? S_CIRC_STEP : S_CIRC_SPAN);
        end
        S_CIRC_STEP: begin
          // ++oy; if (d <= 0) d += 2*oy + 1; else { --ox; d += 2*(oy - ox) + 1; }
          oy <= oy + 18'sd1;
          if (dec <= 20'sd0) begin
            dec <= dec + {{2{1'b0}}, (oy + 18'sd1)} * 2 + 20'sd1;
          end else begin
            ox  <= ox - 18'sd1;
            dec <= dec + ({{2{1'b0}}, (oy + 18'sd1)} - {{2{ox[17]}}, (ox - 18'sd1)}) * 2 + 20'sd1;
          end
          state <= S_CIRC_LOOP;
        end

        // ---------------- WRITE_RECT / UPLOAD ----------------
        S_WR_ROW: begin
          if (j == rh) state <= S_IDLE;
          else begin
            cy <= ry0 + $signed({2'b0, j});
            row_vis <= upload ? 1'b1
                     : ((ry0 + $signed({2'b0, j})) >= ey0 && (ry0 + $signed({2'b0, j})) <= ey1 && xs <= xe);
            i     <= 16'd0;
            cx    <= rx0;
            state <= S_WR_HI;
          end
        end
        S_WR_HI: begin
          if (i == rw) state <= S_WR_FLUSH;
          else if (c_valid && !pop_r) begin
            pix_hi <= c_data;
            pop_r  <= 1'b1;
            state  <= S_WR_LO;
          end
        end
        S_WR_LO: begin
          if (c_valid && !pop_r) begin
            pop_r <= 1'b1;
            if (row_vis && cx >= xs && cx <= xe) begin
              st_we    <= 1'b1;
              st_x     <= cx[8:0];
              st_pix   <= {pix_hi, c_data};
              st_valid <= !(key_en && {pix_hi, c_data} == key);
            end
            cx    <= cx + 18'sd1;
            i     <= i + 16'd1;
            state <= S_WR_HI;
          end
        end
        S_WR_FLUSH: begin
          j <= j + 16'd1;
          if (row_vis)
            start_sw(upload ? (up_row + j[12:0]) : (tgt_row | {5'd0, cy[7:0]}),
                     xs[8:0], xe[8:0], 1'b0, 16'd0, S_WR_ROW);
          else
            state <= S_WR_ROW;
        end

        // ---------------- COPY_RECT ----------------
        S_CP_ROW: begin
          if (j == rh) state <= S_IDLE;
          else begin
            // row index, honouring the copy direction
            cy <= ry0 + $signed({2'b0, (bottom_up ? (rh - 16'd1 - j) : j)});
            if ((ry0 + $signed({2'b0, (bottom_up ? (rh - 16'd1 - j) : j)})) >= cly0 &&
                (ry0 + $signed({2'b0, (bottom_up ? (rh - 16'd1 - j) : j)})) <= cly1 && xs <= xe) begin
              cx <= xs;
              // source pixels (xs - dx + sx) .. (xe - dx + sx)
              start_sr(up_row + src_y[12:0] + (bottom_up ? (rh[12:0] - 13'd1 - j[12:0]) : j[12:0]),
                       xs[8:0] - rx0[8:0] + src_x[8:0], xe[8:0] - rx0[8:0] + src_x[8:0], S_CP_STAGE);
              cp_v1 <= 1'b0;
              cp_v2 <= 1'b0;
            end else begin
              j <= j + 16'd1;
            end
          end
        end
        S_CP_STAGE: begin
          // 3-stage pipeline per pixel: (1) read-buffer address for
          // destination x = cx, (2) block RAM read, (3) stage the pixel.
          // cp_v1/cp_v2 mark which stages hold a pixel.
          if (cp_v2) begin
            st_we    <= 1'b1;
            st_x     <= cp_x2[8:0];
            st_pix   <= cp_q2[0] ? rb_q[31:16] : rb_q[15:0];
            st_valid <= !(key_en && (cp_q2[0] ? rb_q[31:16] : rb_q[15:0]) == key);
          end
          cp_v2 <= cp_v1;
          cp_x2 <= cp_x1;
          cp_q2 <= cp_q1;
          if (cx <= xe) begin
            rb_raddr <= cp_q[8:1];
            cp_x1    <= cx;
            cp_q1    <= cp_q;
            cp_v1    <= 1'b1;
            cx       <= cx + 18'sd1;
          end else begin
            cp_v1 <= 1'b0;
            if (!cp_v1 && !cp_v2) state <= S_CP_FLUSH;
          end
        end
        S_CP_FLUSH: begin
          j <= j + 16'd1;
          start_sw(tgt_row | {5'd0, cy[7:0]}, xs[8:0], xe[8:0], 1'b0, 16'd0, S_CP_ROW);
        end

        // ---------------- MASK (text / 1-2bpp bitmaps) ----------------
        S_MK_ROW: begin
          if (j == rh) state <= S_IDLE;
          else begin
            cy <= ry0 + $signed({2'b0, j});
            row_vis <= (ry0 + $signed({2'b0, j})) >= cly0 && (ry0 + $signed({2'b0, j})) <= cly1 && xs <= xe;
            i     <= 16'd0;
            cx    <= rx0;
            mcnt  <= 4'd0;
            state <= S_MK_PIX;
          end
        end
        S_MK_PIX: begin
          if (i == rw) state <= S_MK_FLUSH;
          else if (mcnt == 4'd0) begin
            if (c_valid && !pop_r) begin
              mbits <= c_data;
              mcnt  <= 4'd8;
              pop_r <= 1'b1;
            end
          end else begin
            if (row_vis && cx >= xs && cx <= xe) begin
              st_we <= 1'b1;
              st_x  <= cx[8:0];
              if (two_bpp) begin
                st_pix   <= (mbits[7:6] == 2'b10) ? bg : col;
                st_valid <= (mbits[7:6] == 2'b01) || (mbits[7:6] == 2'b10);
              end else begin
                st_pix   <= col;
                st_valid <= mbits[7];
              end
            end
            mbits <= two_bpp ? {mbits[5:0], 2'b00} : {mbits[6:0], 1'b0};
            mcnt  <= two_bpp ? mcnt - 4'd2 : mcnt - 4'd1;
            cx    <= cx + 18'sd1;
            i     <= i + 16'd1;
          end
        end
        S_MK_FLUSH: begin
          j <= j + 16'd1;
          if (row_vis)
            start_sw(tgt_row | {5'd0, cy[7:0]}, xs[8:0], xe[8:0], 1'b0, 16'd0, S_MK_ROW);
          else
            state <= S_MK_ROW;
        end

        // ---------------- READ_RECT ----------------
        S_RR_ROW: begin
          if (j == rh) state <= S_IDLE;
          else begin
            cy <= ry0 + $signed({2'b0, j});
            cx <= rx0;
            i  <= 16'd0;
            start_sr(tgt_row | {5'd0, ry0[7:0] + j[7:0]}, rx0[8:0],
                     rx0[8:0] + rw[8:0] - 9'd1, S_RR_ADDR);
          end
        end
        S_RR_ADDR: begin
          if (i == rw) begin
            j     <= j + 16'd1;
            state <= S_RR_ROW;
          end else begin
            rb_raddr <= cx[8:1];
            state    <= S_RR_WAIT;
          end
        end
        S_RR_WAIT: state <= S_RR_HI;   // read-buffer latency
        S_RR_HI: begin
          if (!r_full && !r_push) begin
            r_push <= 1'b1;
            r_data <= cx[0] ? rb_q[31:24] : rb_q[15:8];
            state  <= S_RR_LO;
          end
        end
        S_RR_LO: begin
          if (!r_full && !r_push) begin
            r_push <= 1'b1;
            r_data <= cx[0] ? rb_q[23:16] : rb_q[7:0];
            cx     <= cx + 18'sd1;
            i      <= i + 16'd1;
            state  <= S_RR_ADDR;
          end
        end

        // ---------------- YUV_MBS (video macroblocks) ----------------
        S_YM_NEXT: begin
          if (ym_n == 16'd0) state <= S_IDLE;
          else begin
            ym_n  <= ym_n - 16'd1;
            get_i <= 5'd2;
            get_n <= 5'd4;
            ret   <= S_YM_START;
            state <= S_GET;
          end
        end
        S_YM_START: begin
          rx0   <= {{2{h[3][7]}}, h[3], h[2]};
          ry0   <= {{2{h[5][7]}}, h[5], h[4]};
          xs    <= smax({{2{h[3][7]}}, h[3], h[2]}, clx0);
          xe    <= smin({{2{h[3][7]}}, h[3], h[2]} + 18'sd15, clx1);
          cidx  <= 7'd0;
          j     <= 16'd0;
          state <= S_YM_C;
        end
        S_YM_C: begin
          if (c_valid && !pop_r) begin
            cbuf[cidx] <= c_data;
            pop_r      <= 1'b1;
            cidx       <= cidx + 7'd1;
            if (cidx == 7'd127) state <= S_YM_ROW;
          end
        end
        S_YM_ROW: begin
          if (j == 16'd16) state <= S_YM_NEXT;
          else begin
            cy <= ry0 + $signed({2'b0, j});
            row_vis <= (ry0 + $signed({2'b0, j})) >= cly0 && (ry0 + $signed({2'b0, j})) <= cly1 && xs <= xe;
            i     <= 16'd0;
            cx    <= rx0;
            state <= S_YM_PIX;
          end
        end
        S_YM_PIX: begin
          if (i == 16'd16) begin
            ym_wait <= 2'd3;
            state   <= S_YM_DRAIN;
          end else if (c_valid && !pop_r) begin
            pop_r   <= 1'b1;
            ym_y    <= c_data;
            ym_v0   <= 1'b1;
            ym_vis0 <= row_vis && cx >= xs && cx <= xe;
            ym_x0   <= cx[8:0];
            ym_crow <= j[3:1];
            ym_ccol <= i[3:1];
            cx      <= cx + 18'sd1;
            i       <= i + 16'd1;
          end
        end
        S_YM_DRAIN: begin
          // let the last pixels leave the converter pipeline
          if (ym_wait != 2'd0) ym_wait <= ym_wait - 2'd1;
          else begin
            j <= j + 16'd1;
            if (row_vis)
              start_sw(tgt_row | {5'd0, cy[7:0]}, xs[8:0], xe[8:0], 1'b0, 16'd0, S_YM_ROW);
            else
              state <= S_YM_ROW;
          end
        end

        // ---------------- WAIT_VSYNC ----------------
        S_VSYNC: if (frame_start) state <= S_IDLE;

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
