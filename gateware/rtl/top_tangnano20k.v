`timescale 1ns / 1ps
`default_nettype none
//
// TangNanoGPU top level for the Sipeed Tang Nano 20K.
//
//   host MCU --SPI--> spi_gpu --> cmd FIFO --> gpu_exec --(port B)--+
//            <-BUSY--  (cmd FIFO almost full)                       |
//            <-MISO--  STATUS / PING / READ_DATA <-- resp FIFO      v
//                                                     sdram_ctrl --> 8MB SDRAM
//   HDMI <-- dvi_tx <-- scanout (320x240 -> 640x480) --(port A)--+
//
// LEDs (active low on the board, listed here as "on" conditions):
//   0  pixel-clock heartbeat (~1.5Hz)      3  drawing engine busy
//   1  SDRAM initialised                   4  SPI transaction in progress
//   2  error: bad opcode / FIFO overflow   5  scanout late (sticky)
//
// Buttons: S1 = reset, S2 (held) = colour bars instead of the framebuffer.
//
module top_tangnano20k #(
    parameter integer BUSY_FREE = 1024,  // BUSY asserts below this many free FIFO bytes
    parameter integer SIM_INIT_US = 200  // SDRAM power-up wait (shortened in simulation)
) (
    input  wire        clk27,
    input  wire        btn_s1,
    input  wire        btn_s2,
    output wire [5:0]  led_n,

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,

    // SPI / quad SPI: IO0 = MOSI, IO1 = MISO (bidirectional in quad mode),
    // IO2/IO3 only in quad builds (default; `define LINK_SPI_ONLY removes them)
    input  wire        spi_sck,
    input  wire        spi_mosi,
    inout  wire        spi_miso,
    input  wire        spi_cs_n,
`ifndef LINK_SPI_ONLY
    input  wire        spi_io2,
    input  wire        spi_io3,
`endif
    output wire        gpu_busy,

    // embedded SDRAM - names are fixed (placed by name by nextpnr)
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_wen_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire [3:0]  O_sdram_dqm
);

  // ---------------- clocks and resets ----------------
  wire clk, clk_sdram, sys_locked, clk_pix, clk_pix_x5, pix_locked;

  clocks u_clocks (
      .clk27(clk27),
      .clk_sys(clk), .clk_sdram(clk_sdram), .sys_locked(sys_locked),
      .clk_pix(clk_pix), .clk_pix_x5(clk_pix_x5), .pix_locked(pix_locked)
  );

  // S1 is asynchronous; synchronise it before using it as a reset request
  reg [1:0] btn1_s, btn2_s;
  always @(posedge clk) btn1_s <= {btn1_s[0], btn_s1};

  reg [7:0] rst_cnt = 8'd0;
  always @(posedge clk)
    if (btn1_s[1] || !sys_locked) rst_cnt <= 8'd0;
    else if (rst_cnt != 8'hff)    rst_cnt <= rst_cnt + 8'd1;
  wire rst = (rst_cnt != 8'hff);

  reg [7:0] rst_pix_cnt = 8'd0;
  always @(posedge clk_pix) begin
    btn2_s <= {btn2_s[0], btn_s2};
    if (!pix_locked) rst_pix_cnt <= 8'd0;
    else if (rst_pix_cnt != 8'hff) rst_pix_cnt <= rst_pix_cnt + 8'd1;
  end
  wire rst_pix = (rst_pix_cnt != 8'hff);

  // ---------------- SPI + FIFOs ----------------
  wire        soft_reset;
  wire        rst_engine = rst | soft_reset;

  wire        cmd_push, cmd_full, cmd_valid, cmd_pop;
  wire [7:0]  cmd_din, cmd_dout;
  wire [12:0] cmd_used, cmd_free;

  wire        resp_push, resp_full, resp_valid, resp_pop;
  wire [7:0]  resp_din, resp_dout;
  wire [11:0] resp_used, resp_free;

  wire        miso_o, miso_oe, overflow, bad_opcode, exec_idle, sdram_ready;
  wire        front_buf, target, late;
  reg  [15:0] frame_count;

  wire [7:0] flags = {1'b0, late, target, sdram_ready, bad_opcode, overflow,
                      front_buf, !(exec_idle && !cmd_valid)};

`ifdef LINK_SPI_ONLY
  localparam integer QUAD = 0;
  wire [3:0] spi_io = {2'b00, spi_miso, spi_mosi};
`else
  localparam integer QUAD = 1;
  wire [3:0] spi_io = {spi_io3, spi_io2, spi_miso, spi_mosi};
`endif

  spi_gpu #(.QUAD(QUAD)) u_spi (
      .clk(clk), .rst(rst),
      .sck(spi_sck), .cs_n(spi_cs_n), .io_in(spi_io),
      .miso(miso_o), .miso_oe(miso_oe),
      .cmd_push(cmd_push), .cmd_data(cmd_din), .cmd_full(cmd_full),
      .resp_valid(resp_valid), .resp_dout(resp_dout), .resp_pop(resp_pop),
      .cmd_free({3'd0, cmd_free}), .resp_used({4'd0, resp_used}),
      .flags(flags), .frame_count(frame_count),
      .soft_reset(soft_reset), .overflow(overflow)
  );

  assign spi_miso = miso_oe ? miso_o : 1'bz;
  assign gpu_busy = (cmd_free < BUSY_FREE) || rst;

  byte_fifo #(.AW(12)) u_cmd_fifo (
      .clk(clk), .rst(rst_engine),
      .push(cmd_push), .din(cmd_din), .full(cmd_full),
      .pop(cmd_pop), .dout(cmd_dout), .valid(cmd_valid),
      .used(cmd_used), .free(cmd_free)
  );

  byte_fifo #(.AW(11)) u_resp_fifo (
      .clk(clk), .rst(rst_engine),
      .push(resp_push), .din(resp_din), .full(resp_full),
      .pop(resp_pop), .dout(resp_dout), .valid(resp_valid),
      .used(resp_used), .free(resp_free)
  );

  // ---------------- drawing engine ----------------
  wire        b_req, b_we, b_ack, b_wpull, b_rvalid, b_done;
  wire [20:0] b_addr;
  wire [8:0]  b_len;
  wire [31:0] b_wdata, rdata;
  wire [3:0]  b_wbe;
  wire        show_buf, frame_start;

  gpu_exec u_exec (
      .clk(clk), .rst(rst_engine),
      .c_valid(cmd_valid), .c_data(cmd_dout), .c_pop(cmd_pop),
      .r_push(resp_push), .r_data(resp_din), .r_full(resp_full),
      .b_req(b_req), .b_we(b_we), .b_addr(b_addr), .b_len(b_len),
      .b_wdata(b_wdata), .b_wbe(b_wbe), .b_ack(b_ack), .b_wpull(b_wpull),
      .b_rvalid(b_rvalid), .rdata(rdata), .b_done(b_done),
      .frame_start(frame_start), .show_buf(show_buf), .target(target),
      .idle(exec_idle), .bad_opcode(bad_opcode)
  );

  always @(posedge clk)
    if (rst) frame_count <= 16'd0;
    else if (frame_start) frame_count <= frame_count + 16'd1;

  // ---------------- scanout + SDRAM ----------------
  wire        a_req, a_ack, a_rvalid, a_done;
  wire [20:0] a_addr;
  wire [8:0]  a_len;
  wire        de, hsync_n, vsync_n;
  wire [7:0]  r, g, b;

  scanout u_scanout (
      .clk(clk), .rst(rst),
      .show_buf(show_buf), .front_buf(front_buf), .frame_start(frame_start),
      .late(late), .clear_late(soft_reset),
      .a_req(a_req), .a_addr(a_addr), .a_len(a_len), .a_ack(a_ack),
      .a_rvalid(a_rvalid), .a_rdata(rdata), .a_done(a_done),
      .clk_pix(clk_pix), .rst_pix(rst_pix), .test_pattern(btn2_s[1]),
      .de(de), .hsync_n(hsync_n), .vsync_n(vsync_n), .r(r), .g(g), .b(b)
  );

  sdram_ctrl #(.FREQ(64_800_000), .INIT_US(SIM_INIT_US)) u_sdram (
      .clk(clk), .clk_sdram(clk_sdram), .rst(rst), .ready(sdram_ready),
      .a_req(a_req), .a_addr(a_addr), .a_len(a_len), .a_ack(a_ack),
      .a_rvalid(a_rvalid), .a_done(a_done),
      .b_req(b_req), .b_we(b_we), .b_addr(b_addr), .b_len(b_len),
      .b_wdata(b_wdata), .b_wbe(b_wbe), .b_ack(b_ack), .b_wpull(b_wpull),
      .b_rvalid(b_rvalid), .b_done(b_done),
      .rdata(rdata),
      .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba),
      .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n),
      .SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n),
      .SDRAM_CLK(O_sdram_clk), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm)
  );

  // sdram_ctrl only accepts requests once its init sequence has finished,
  // so scanout/engine requests issued earlier simply wait (the host
  // library also waits for STATUS.sdram_ready in begin()).

  dvi_tx u_dvi (
      .clk_pix(clk_pix), .clk_pix_x5(clk_pix_x5), .rst(rst_pix),
      .de(de), .hsync_n(hsync_n), .vsync_n(vsync_n), .r(r), .g(g), .b(b),
      .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
      .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
  );

  // ---------------- LEDs ----------------
  reg [23:0] heartbeat;
  always @(posedge clk_pix) heartbeat <= heartbeat + 24'd1;

  assign led_n = ~{late, !spi_cs_n, !(exec_idle && !cmd_valid),
                   bad_opcode | overflow, sdram_ready, heartbeat[23]};

endmodule
`default_nettype wire
