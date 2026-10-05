`timescale 1ns / 1ps
`default_nettype none
//
// Single-clock byte FIFO on block RAM with a first-word-fall-through
// output: `dout` is valid whenever `valid` is high, and `pop` consumes it.
// Sustains one push and one pop per clock.
//
// The entry currently presented on dout still occupies its RAM slot (the
// read pointer has already moved past it), so one slot is held in reserve
// and `full` asserts at DEPTH-1 stored entries.
//
module byte_fifo #(
    parameter integer AW = 12          // depth = 2**AW bytes
) (
    input  wire        clk,
    input  wire        rst,             // synchronous flush
    input  wire        push,
    input  wire [7:0]  din,
    output wire        full,
    input  wire        pop,
    output wire [7:0]  dout,
    output reg         valid,
    output wire [AW:0] used,            // entries stored, including dout
    output wire [AW:0] free
);

  localparam integer DEPTH = 1 << AW;

  reg  [AW:0] wptr, rptr;
  wire [AW:0] stored = wptr - rptr;    // not yet fetched into dout
  wire        has_more = (wptr != rptr);
  wire        fetch = has_more && (!valid || pop);

  assign full = (stored >= DEPTH - 1);
  assign used = stored + {{AW{1'b0}}, valid};
  assign free = (DEPTH[AW:0] - 1'b1) - stored;

  // Re-read the presented entry while not fetching, so the RAM's output
  // register keeps showing it.
  wire [AW-1:0] raddr = fetch ? rptr[AW-1:0] : (rptr[AW-1:0] - 1'b1);

  bram_sdp #(.AW(AW), .DW(8)) u_mem (
      .wclk(clk), .we(push && !full), .waddr(wptr[AW-1:0]), .wdata(din),
      .rclk(clk), .raddr(raddr), .rdata(dout)
  );

  always @(posedge clk) begin
    if (rst) begin
      wptr  <= {(AW+1){1'b0}};
      rptr  <= {(AW+1){1'b0}};
      valid <= 1'b0;
    end else begin
      if (push && !full) wptr <= wptr + 1'b1;
      if (fetch) begin
        rptr  <= rptr + 1'b1;
        valid <= 1'b1;
      end else if (pop) begin
        valid <= 1'b0;
      end
    end
  end

endmodule
`default_nettype wire
