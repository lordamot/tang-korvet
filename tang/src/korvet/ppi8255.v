`timescale 1ns / 1ps
//========================================================================
// ppi8255.v - a КР580ВВ55А, as far as the Корвет uses one.
//
// Three of them: #1 (D17) drives the display and the floppy and reads
// the tape, VBL and the attribute flip-flop; #2 (D16) drives the printer,
// the sound gate, the tape output and the Control line of the side
// connector; #3 (D2) IS the side connector, where the ExtROM controller
// and the AY module hang.  All three are mode 0 - a byte a port, in or
// out by the control word - and #3 is put into mode 2 by the ExtROM's
// loader: port A a bidirectional bus with the STB/IBF and ACK/OBF
// handshake on port C's upper bits.  Mode 1 is not implemented (nothing
// here uses it) and is taken as mode 0.
//
// Pins: `pX_in` is what the world drives, `pX_out` the output latch,
// `pX_dir` 1 for output - the world decides what an output pin reads
// back (an output port reads its latch, as the chip does).  In mode 2
// the device side is a handshake: `m2_in_stb` latches `m2_din` and
// raises IBF, `m2_ack` says the device took the output latch and clears
// OBF; the CPU's read of port A clears IBF, its write sets OBF.  Port
// C's upper half then reads {OBF/, INTE1, IBF, INTE2}: 1 in bit 7 is
// "output buffer empty", 1 in bit 5 is "input buffer full" - the two
// bits the loader polls.
//
// A mode word clears every output latch (the ОПТС writes one first),
// which is why Control and the sound gate start at 0.
//========================================================================
module ppi8255 (
    input             clk,
    input             reset,

    input             wr,           // one clock
    input             rd,           // one clock; rdata a clock later
    input      [1:0]  a,
    input      [7:0]  wdata,
    output reg [7:0]  rdata,

    input      [7:0]  pa_in,
    output reg [7:0]  pa_out,
    output            pa_dir,
    input      [7:0]  pb_in,
    output reg [7:0]  pb_out,
    output            pb_dir,
    input      [7:0]  pc_in,
    output reg [7:0]  pc_out,
    output            pc_dir_hi,
    output            pc_dir_lo,

    output            mode2,        // port A is in mode 2
    input             m2_in_stb,
    input      [7:0]  m2_din,
    input             m2_ack,
    output reg        m2_ibf,
    output reg        m2_obf_n     // 0 = the output latch holds a byte
);

reg [7:0] ctrl = 8'h9B;             // after reset: all ports input, mode 0
reg [7:0] m2_inlatch = 8'd0;

assign mode2     = ctrl[6];
assign pa_dir    = mode2 ? 1'b0 : ~ctrl[4];
assign pb_dir    = ~ctrl[1];
assign pc_dir_hi = ~ctrl[3];
assign pc_dir_lo = ~ctrl[0];

wire [7:0] pa_rd = mode2 ? m2_inlatch : (pa_dir ? pa_out : pa_in);
wire [7:0] pb_rd = pb_dir ? pb_out : pb_in;
wire [3:0] pc_hi = mode2 ? {m2_obf_n, 1'b1, m2_ibf, 1'b1} :
                   (pc_dir_hi ? pc_out[7:4] : pc_in[7:4]);
wire [3:0] pc_lo = pc_dir_lo ? pc_out[3:0] : pc_in[3:0];

always @(posedge clk) begin
    if (reset) begin
        ctrl <= 8'h9B; pa_out <= 8'd0; pb_out <= 8'd0; pc_out <= 8'd0;
        m2_ibf <= 1'b0; m2_obf_n <= 1'b1;
    end else begin
        if (m2_in_stb) begin m2_inlatch <= m2_din; m2_ibf <= 1'b1; end
        if (m2_ack)    m2_obf_n <= 1'b1;
        if (wr) case (a)
            2'd0: begin pa_out <= wdata; if (mode2) m2_obf_n <= 1'b0; end
            2'd1: pb_out <= wdata;
            2'd2: pc_out <= wdata;
            2'd3: if (wdata[7]) begin
                      ctrl <= wdata; pa_out <= 8'd0; pb_out <= 8'd0; pc_out <= 8'd0;
                      m2_ibf <= 1'b0; m2_obf_n <= 1'b1;
                  end else
                      pc_out[wdata[3:1]] <= wdata[0];
        endcase
        if (rd) begin
            case (a)
                2'd0: begin rdata <= pa_rd; if (mode2) m2_ibf <= 1'b0; end
                2'd1: rdata <= pb_rd;
                2'd2: rdata <= {pc_hi, pc_lo};
                2'd3: rdata <= 8'hFF;
            endcase
        end
    end
end

endmodule
