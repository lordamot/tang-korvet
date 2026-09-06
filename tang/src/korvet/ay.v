`timescale 1ns / 1ps
//========================================================================
// ay.v - the AY-3-8910 module on the side connector.
//
// The community's sound module for the Корвет sits on the ВВ55 #3 the
// way Emu80's korvet.conf has it (KorvetPpiPsgAdapter, CFG_PPI3 = AY):
// port A is the chip's data bus, port B bit 7 is BDIR and bit 6 BC1,
// and a write to port B with either of them set is the bus cycle -
// BDIR BC1 = 1 1 a register select, 1 0 a write, 0 1 a read, the data
// taken from port A's output latch or handed to port A's input.  The
// chip runs at 1.75 MHz, as Emu80 has it.  It shares the connector with
// the ExtROM controller, which uses port A in mode 2 and port C's upper
// half and never touches port B's top bits; both can be on.
//
// The chip is ym2149.sv (MikeJ / Sorgelig) with its clock enable made by
// a phase accumulator: 7/162 of 40.5 MHz is 1.75 MHz.  The three
// channels are summed here.
//========================================================================
module ay (
    input             clk,
    input             reset,
    input             en,           // the OSD's switch

    input      [7:0]  pa_out,       // the ВВ55 #3's port A output latch
    output     [7:0]  pa_in,        // what port A reads when the chip drives it
    input      [7:0]  pb_out,
    input             pb_wr,        // one clock: port B was written

    output     [9:0]  sample        // the three channels summed, 0..765
);

wire bdir = pb_out[7];
wire bc1  = pb_out[6];

// one bus cycle per write with a strobe up (Emu80's edge on either)
reg  strobe = 1'b0;
reg  cyc = 1'b0;
reg  cyc_bdir = 1'b0, cyc_bc1 = 1'b0;
always @(posedge clk) begin
    cyc <= 1'b0;
    if (reset) strobe <= 1'b0;
    else if (pb_wr) begin
        if (!strobe && (bdir || bc1)) begin
            strobe <= 1'b1; cyc <= 1'b1; cyc_bdir <= bdir; cyc_bc1 <= bc1;
        end else if (!(bdir || bc1))
            strobe <= 1'b0;
    end
end

reg [7:0] acc = 8'd0;
wire [8:0] acc_n = {1'b0, acc} + 9'd7;
wire ce = (acc_n >= 9'd162);
always @(posedge clk) acc <= ce ? acc_n[7:0] - 8'd162 : acc_n[7:0];

wire [7:0] do_, ca, cb, cc;

YM2149 chip (
    .CLK      (clk),
    .CE       (ce),
    .RESET    (reset | ~en),
    .BDIR     (cyc & cyc_bdir),
    .BC       (cyc & cyc_bc1),
    .DI       (pa_out),
    .DO       (do_),
    .CHANNEL_A(ca),
    .CHANNEL_B(cb),
    .CHANNEL_C(cc),
    .SEL      (1'b0),
    .MODE     (1'b1),
    .ACTIVE   (),
    .IOA_in   (8'd0),
    .IOA_out  (),
    .IOB_in   (8'd0),
    .IOB_out  ()
);

// a read cycle leaves the register on port A's input
reg [7:0] rd_latch = 8'hFF;
reg       rd_d = 1'b0;
always @(posedge clk) begin
    rd_d <= cyc && !cyc_bdir && cyc_bc1;
    if (rd_d) rd_latch <= do_;
end
assign pa_in  = en ? rd_latch : 8'hFF;
assign sample = en ? ({2'd0, ca} + {2'd0, cb} + {2'd0, cc}) : 10'd0;

endmodule
