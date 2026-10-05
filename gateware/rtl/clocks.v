`timescale 1ns / 1ps
`default_nettype none
//
// Clock generation from the Tang Nano 20K's 27MHz oscillator:
//
//   pll_sys : 27 * 12 / 5 = 64.8MHz system clock (gowin_pll -i 27 -o 64.8
//             -d GW2AR-LV18QN88C8/I7), plus the same clock shifted by
//             180 degrees on CLKOUTP for the SDRAM chip's clock pin.
//   pll_dvi : 27 * 14 / 3 = 126MHz = 5x pixel clock (same settings as
//             Apicula's examples/DVI/pll480.v), CLKDIV /5 -> 25.2MHz.
//
// The rPLL divider fields are selectors (IDIV_SEL = divider - 1, etc.), so
// values come from Apicula's gowin_pll calculator, not hand-derived.
//
module clocks (
    input  wire clk27,
    output wire clk_sys,
    output wire clk_sdram,
    output wire sys_locked,
    output wire clk_pix,
    output wire clk_pix_x5,
    output wire pix_locked
);

`ifdef SIMULATION
  // Simulation: testbenches drive the clocks directly through this module's
  // outputs being overridden; keep a trivial pass-through so it elaborates.
  assign clk_sys    = clk27;
  assign clk_sdram  = ~clk27;
  assign sys_locked = 1'b1;
  assign clk_pix    = clk27;
  assign clk_pix_x5 = clk27;
  assign pix_locked = 1'b1;
`else
  rPLL #(
      .FCLKIN("27"),
      .DYN_IDIV_SEL("false"), .IDIV_SEL(4),
      .DYN_FBDIV_SEL("false"), .FBDIV_SEL(11),
      .DYN_ODIV_SEL("false"), .ODIV_SEL(8),
      .PSDA_SEL("1000"),          // CLKOUTP = CLKOUT + 180 degrees
      .DYN_DA_EN("false"),
      .DUTYDA_SEL("1000"),
      .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
      .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
      .CLKFB_SEL("internal"),
      .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
      .DYN_SDIV_SEL(2),
      .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
      .DEVICE("GW2AR-18C")
  ) u_pll_sys (
      .CLKOUT(clk_sys), .CLKOUTP(clk_sdram), .CLKOUTD(), .CLKOUTD3(),
      .LOCK(sys_locked),
      .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
      .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
      .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
  );

  rPLL #(
      .FCLKIN("27"),
      .DYN_IDIV_SEL("false"), .IDIV_SEL(2),
      .DYN_FBDIV_SEL("false"), .FBDIV_SEL(13),
      .DYN_ODIV_SEL("false"), .ODIV_SEL(4),
      .PSDA_SEL("0000"),
      .DYN_DA_EN("true"),
      .DUTYDA_SEL("1000"),
      .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
      .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
      .CLKFB_SEL("internal"),
      .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
      .DYN_SDIV_SEL(2),
      .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
      .DEVICE("GW2AR-18C")
  ) u_pll_dvi (
      .CLKOUT(clk_pix_x5), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
      .LOCK(pix_locked),
      .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
      .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
      .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
  );

  CLKDIV #(.DIV_MODE("5")) u_div5 (
      .HCLKIN(clk_pix_x5), .RESETN(pix_locked), .CALIB(1'b0), .CLKOUT(clk_pix)
  );
`endif

endmodule
`default_nettype wire
