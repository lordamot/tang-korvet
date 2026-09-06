`timescale 1ns / 1ps
//========================================================================
// sys_pll.v - the system clock: 27 MHz in, 40.5 MHz out.
//
// Everything in this design runs on the one 40.5 MHz clock: the CPU's
// T-state is sixteen of them (2.53 MHz - the Корвет's 2.5 MHz, 1.25%
// fast), the machine's pixel is four (10.125 MHz for its 10), the HDMI
// pixel is one, and the SDRAM takes the phase-shifted copy on its own
// pad.  27 x 3 / 2 is the nearest an rPLL gets to 40: an exact 40 would
// need a 1 MHz phase detector, below the part's 3 MHz floor.  IDIV 2
// puts the phase detector at 13.5 MHz, ODIV 16 the VCO at 648 MHz,
// inside its 400-1200.  Why 40 and not PK8000 Nano's 30: the Корвет's
// 512-pixel line has to leave the chip as 1024 HDMI pixels in half a
// machine line, and 30 MHz gives 984 clocks for it.
//
// This is a hand-written instantiation of the rPLL primitive, like
// hdmi_serdes.v, and not IP Core Generator output; it is stubbed in
// simulation by sim/stubs/gowin_ip_sim.v, which quotes these ratios.
//========================================================================
module sys_pll (
    input  clkin,       // 27 MHz, pin 4
    output clkout,      // 40.5 MHz
    output clkoutp,     // 40.5 MHz, 90 degrees later, for the SDRAM pad
    output lock
);

rPLL rpll_inst (
    .CLKOUT  (clkout ),
    .LOCK    (lock   ),
    .CLKOUTP (clkoutp),
    .CLKOUTD (       ),
    .CLKOUTD3(       ),
    .RESET   (1'b0   ),
    .RESET_P (1'b0   ),
    .CLKIN   (clkin  ),
    .CLKFB   (1'b0   ),
    .FBDSEL  (6'b000000),
    .IDSEL   (6'b000000),
    .ODSEL   (6'b000000),
    .PSDA    (4'b0000),
    .DUTYDA  (4'b0000),
    .FDLY    (4'b1111)
);

defparam rpll_inst.FCLKIN           = "27";
defparam rpll_inst.DEVICE           = "GW2AR-18C";
defparam rpll_inst.DYN_IDIV_SEL     = "false";
defparam rpll_inst.IDIV_SEL         = 1;        // divide by 2
defparam rpll_inst.DYN_FBDIV_SEL    = "false";
defparam rpll_inst.FBDIV_SEL        = 2;        // multiply by 3
defparam rpll_inst.DYN_ODIV_SEL     = "false";
defparam rpll_inst.ODIV_SEL         = 16;       // VCO 648 MHz
defparam rpll_inst.PSDA_SEL         = "0100";   // clkoutp 90 degrees
defparam rpll_inst.DYN_DA_EN        = "false";
defparam rpll_inst.DUTYDA_SEL       = "1000";
defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL        = "internal";
defparam rpll_inst.CLKOUT_BYPASS    = "false";
defparam rpll_inst.CLKOUTP_BYPASS   = "false";
defparam rpll_inst.CLKOUTD_BYPASS   = "false";
defparam rpll_inst.DYN_SDIV_SEL     = 2;
defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";

endmodule
