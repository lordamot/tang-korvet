`timescale 1ns / 1ps
//========================================================================
// devices.v - the Корвет's device page: the chips at FB00h-FBFFh.
//
// The PLM's CSDEV opens the ИД7 decoder D23 on A5..A3 (техописание §3),
// so the 256-byte page repeats every 64 bytes and each chip has eight:
//   00h  ВИ53 timer          08h  ВВ55 #3 (the side connector)
//   10h  ВВ51 #1 (RS-232)    18h  ВГ93 floppy controller
//   20h  ВВ51 #2 (network)   28h  ВН59 interrupt controller
//   30h  ВВ55 #2             38h  ВВ55 #1
// The ВВ55s' pins are wired here as the schematic wires them and the
// devices behind them (the floppy, the ExtROM, the AY module, the mouse)
// are instantiated in top.v on the pin signals this module exports.
// Every read answers on `rdata` two clocks after the strobe (the ВГ93
// three); the CPU's device-page wait state leaves room for that.
//========================================================================
module devices (
    input             clk,
    input             reset,        // the machine's reset
    input             ce_cpu,       // 2.5 MHz enable (the floppy chip)

    // the CPU
    input             rd_stb,       // one clock, a valid
    input             wr_stb,       // one clock, a and wdata valid
    input      [5:0]  a,            // A5..A0
    input      [7:0]  wdata,
    output reg [7:0]  rdata,

    // the timer's clocks
    input             ce_2m,        // 2 MHz enable
    input             hbl_tick,     // one clock a line
    output            snd_out,      // counter 0's output, ungated

    // ВВ55 #1 (D17): A in - tape, VBL, printer, the attribute, the
    // network address; B out - the floppy; C out - the display
    input             tape_in,
    input             vbl,
    input             attr_ff,
    output     [7:0]  fdd_ctrl,
    output     [7:0]  vid_ctrl,

    // ВВ55 #2 (D16): A out - printer data; C out - tape, sound gate,
    // printer strobe, Control
    output     [7:0]  printer_data,
    output     [7:0]  ppi2_c,

    // ВВ55 #3 (D2): the side connector, pins out
    output     [7:0]  p3a_out,
    input      [7:0]  p3a_in,
    output     [7:0]  p3b_out,
    output            p3b_wr,       // one clock: port B written
    output     [7:0]  p3c_out,
    output            p3_mode2,
    input             p3_in_stb,
    input      [7:0]  p3_in_data,
    input             p3_ack,
    output            p3_ibf,
    output            p3_obf_n,

    // the ВВ51 #1's line
    input             rxd1,
    output            txd1,
    output            rts1,         // active high
    input             dsr1,         // active high: asserted

    // the floppy (fdc.v, in top.v: it owns the SD path)
    output            fdc_rd,
    output            fdc_wr,
    input      [7:0]  fdc_rdata,
    input             fdc_motor_irq,

    // the interrupt controller
    input             irq0_ext,     // the ExtROM's Control: the connector calls the
                                    // pin IRQ7, the ОПТС reads it at level 0
    output            int_out,
    input             inta_stb,
    input      [1:0]  inta_n,
    output     [7:0]  inta_data
);

wire [2:0] sel = a[5:3];
wire sel_pit  = (sel == 3'd0);
wire sel_p3   = (sel == 3'd1);
wire sel_s1   = (sel == 3'd2);
wire sel_fdc  = (sel == 3'd3);
wire sel_s2   = (sel == 3'd4);
wire sel_pic  = (sel == 3'd5);
wire sel_p2   = (sel == 3'd6);
wire sel_p1   = (sel == 3'd7);

wire [7:0] r_pit, r_p3, r_s1, r_s2, r_pic, r_p2, r_p1;

//------------------------------------------------------------------------
// The timer
//------------------------------------------------------------------------
wire [2:0] pit_out;
pit8253 pit (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_pit), .rd(rd_stb && sel_pit), .a(a[1:0]), .wdata(wdata), .rdata(r_pit),
    .ce({hbl_tick, ce_2m, ce_2m}), .gate(3'b111), .out(pit_out)
);
assign snd_out = pit_out[0];

//------------------------------------------------------------------------
// ВВ55 #1
//------------------------------------------------------------------------
wire [7:0] p1a_in = {4'b1111, attr_ff, 1'b1, vbl, tape_in};   // the network address is 15 (Emu80: WS_ADDR 0, inverted); the printer is not busy
ppi8255 ppi1 (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_p1), .rd(rd_stb && sel_p1), .a(a[1:0]), .wdata(wdata), .rdata(r_p1),
    .pa_in(p1a_in), .pa_out(), .pa_dir(),
    .pb_in(8'hFF), .pb_out(fdd_ctrl), .pb_dir(),
    .pc_in(8'hFF), .pc_out(vid_ctrl), .pc_dir_hi(), .pc_dir_lo(),
    .mode2(), .m2_in_stb(1'b0), .m2_din(8'd0), .m2_ack(1'b0), .m2_ibf(), .m2_obf_n()
);

//------------------------------------------------------------------------
// ВВ55 #2
//------------------------------------------------------------------------
ppi8255 ppi2 (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_p2), .rd(rd_stb && sel_p2), .a(a[1:0]), .wdata(wdata), .rdata(r_p2),
    .pa_in(8'hFF), .pa_out(printer_data), .pa_dir(),
    .pb_in(8'hFF), .pb_out(), .pb_dir(),
    .pc_in(8'hFF), .pc_out(ppi2_c), .pc_dir_hi(), .pc_dir_lo(),
    .mode2(), .m2_in_stb(1'b0), .m2_din(8'd0), .m2_ack(1'b0), .m2_ibf(), .m2_obf_n()
);

//------------------------------------------------------------------------
// ВВ55 #3 - the side connector
//------------------------------------------------------------------------
assign p3b_wr = wr_stb && sel_p3 && (a[1:0] == 2'd1);
ppi8255 ppi3 (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_p3), .rd(rd_stb && sel_p3), .a(a[1:0]), .wdata(wdata), .rdata(r_p3),
    .pa_in(p3a_in), .pa_out(p3a_out), .pa_dir(),
    .pb_in(8'hFF), .pb_out(p3b_out), .pb_dir(),
    .pc_in(8'hFF), .pc_out(p3c_out), .pc_dir_hi(), .pc_dir_lo(),
    .mode2(p3_mode2), .m2_in_stb(p3_in_stb), .m2_din(p3_in_data), .m2_ack(p3_ack),
    .m2_ibf(p3_ibf), .m2_obf_n(p3_obf_n)
);

//------------------------------------------------------------------------
// The serial adapters.  #1's clock is the timer's counter 1; #2's is
// the fixed 19.2 kbit/s x16, 312.5 kHz from D44 on the machine, made
// here by a divider (130 clocks: 311.5 kHz).
//------------------------------------------------------------------------
wire rxrdy1, txrdy1, rxrdy2, rts1_n;
assign rts1 = ~rts1_n;
i8251 sio1 (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_s1), .rd(rd_stb && sel_s1), .a0(a[0]), .wdata(wdata), .rdata(r_s1),
    .rxc(pit_out[1]), .txc(pit_out[1]), .rxd(rxd1), .txd(txd1),
    .dsr_n(~dsr1), .dtr_n(), .rts_n(rts1_n),
    .rxrdy(rxrdy1), .txrdy(txrdy1)
);

reg [7:0] div2 = 8'd0;
reg       clk2 = 1'b0;
always @(posedge clk) begin
    if (div2 == 8'd64) begin div2 <= 8'd0; clk2 <= ~clk2; end
    else div2 <= div2 + 8'd1;
end
i8251 sio2 (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_s2), .rd(rd_stb && sel_s2), .a0(a[0]), .wdata(wdata), .rdata(r_s2),
    .rxc(clk2), .txc(clk2), .rxd(1'b1), .txd(),
    .dsr_n(1'b1), .dtr_n(), .rts_n(),
    .rxrdy(rxrdy2), .txrdy()
);

//------------------------------------------------------------------------
// The floppy: the chip lives in top.v with the SD path
//------------------------------------------------------------------------
assign fdc_rd = rd_stb && sel_fdc;
assign fdc_wr = wr_stb && sel_fdc;

//------------------------------------------------------------------------
// The interrupt controller
//------------------------------------------------------------------------
// Level 0 is the expansion connector's - and the ExtROM's Control through
// its jumper: the ОПТС tests bit 0 of the request register after raising
// Control (korvet20.rom 04C0h-04CEh), whatever the connector's pin is
// called, and Erokhin's emulator patch raises request 0 for it.
wire [7:0] ir = {fdc_motor_irq, 1'b0, pit_out[2], ~vbl, rxrdy2, txrdy1, rxrdy1, irq0_ext};
pic8259 pic (
    .clk(clk), .reset(reset),
    .wr(wr_stb && sel_pic), .rd(rd_stb && sel_pic), .a0(a[0]), .wdata(wdata), .rdata(r_pic),
    .ir(ir), .int_out(int_out), .inta_stb(inta_stb), .inta_n(inta_n), .inta_data(inta_data)
);

//------------------------------------------------------------------------
// The answer, two clocks after the strobe (the chips register on the
// strobe); the floppy's byte is registered in fdc.v three clocks after
// the strobe and taken here the clock after that.  Taking it on the same
// clock it is registered handed the CPU the previous read's byte, and
// the ОПТС's sector loop (status, then data on DRQ) quit on the first
// data byte - the disk boots that showed BASIC were the ROM's BASIC
// after the floppy boot had failed (progress.md, 6 Sep).
//------------------------------------------------------------------------
reg [2:0] sel_r = 3'd0;
reg [2:0] rd_pipe = 3'd0;
always @(posedge clk) begin
    rd_pipe <= {rd_pipe[1:0], rd_stb};
    if (rd_stb) sel_r <= sel;
    if (rd_pipe[0]) case (sel_r)
        3'd0: rdata <= r_pit;
        3'd1: rdata <= r_p3;
        3'd2: rdata <= r_s1;
        3'd4: rdata <= r_s2;
        3'd5: rdata <= r_pic;
        3'd6: rdata <= r_p2;
        3'd7: rdata <= r_p1;
        default: ;
    endcase
    if (rd_pipe[2] && sel_r == 3'd3) rdata <= fdc_rdata;
end

endmodule
