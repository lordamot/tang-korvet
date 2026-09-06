`timescale 1ns / 1ps
//========================================================================
// txtram.v - the text RAM (АЦЗУ): 1 K x 9, a character and its attribute.
//
// The ninth bit is the attribute - inversion - and the machine writes it
// through the inversion flip-flop D75 the ВВ55 #1's port C drives: bits
// 5:4 of that port are INVON/INVOFF, active low, so 01 (INVOFF active)
// clears the bit as a character is written, 10 sets it, 11 leaves the
// flip-flop free to hold what the last READ of the text RAM latched
// into it, and 00 is the forbidden state, which Emu80 takes as "leave
// the stored bit alone" and so does this.  The flip-flop's state is
// port A bit 3 (`attr_ff`), for a program that wants to know.
//
// A write therefore reads the stored attribute first, which makes it two
// clocks long here; the CPU's own read is registered a clock; the
// display reads through the second port.  One array of 9 bits, written
// on one port and read on both (never both on the same clock at the
// CPU's port: its strobes are T-states apart).
//========================================================================
module txtram (
    input             clk,

    // the CPU
    input      [9:0]  cpu_adr,
    input             cpu_rd,       // one clock; cpu_rdata a clock later
    input             cpu_wr,       // one clock, with the data
    input      [7:0]  cpu_wdata,
    input      [1:0]  attr_mode,    // port C bits 5:4
    output reg [7:0]  cpu_rdata,
    output reg        attr_ff,

    // the display
    input      [9:0]  vid_adr,
    output reg [7:0]  vid_sym,
    output reg        vid_attr
);

reg [8:0] mem [0:1023];
integer i;
initial for (i = 0; i < 1024; i = i + 1) mem[i] = 9'd0;

reg [8:0]  q_a = 9'd0;
reg        rd_d = 1'b0;
reg [1:0]  wr_pipe = 2'd0;
reg [9:0]  w_adr = 10'd0;
reg [7:0]  w_data = 8'd0;
reg [1:0]  w_mode = 2'd0;

wire       new_attr = (w_mode == 2'd1) ? 1'b1 :
                      (w_mode == 2'd2) ? 1'b0 :
                      (w_mode == 2'd3) ? attr_ff : q_a[8];

// port A: the CPU's read, and the read-then-write of a store
always @(posedge clk) begin
    rd_d    <= cpu_rd;
    wr_pipe <= {wr_pipe[0], cpu_wr};
    if (cpu_wr) begin w_adr <= cpu_adr; w_data <= cpu_wdata; w_mode <= attr_mode; end

    if (wr_pipe[1])
        mem[w_adr] <= {new_attr, w_data};
    else if (cpu_rd || cpu_wr)
        q_a <= mem[cpu_adr];

    if (rd_d) begin
        cpu_rdata <= q_a[7:0];
        attr_ff   <= q_a[8];
    end
    // a forced flip-flop reads back what it is forced to
    if (attr_mode == 2'd1) attr_ff <= 1'b1;
    if (attr_mode == 2'd2) attr_ff <= 1'b0;
end

// port B: the display
always @(posedge clk) begin
    {vid_attr, vid_sym} <= mem[vid_adr];
end

endmodule
