`timescale 1ns / 1ps
//========================================================================
// cpuz80.v - the Z80 accelerator: a Z80 in the ВМ80's socket.
//
// The Корвет community's accelerator board (a Z80 on a card in the test
// connector, 2.5 MHz or 5 MHz on a "Турбо" switch, infosource/links.txt)
// runs the machine's software as it is: the ОПТС and CP/M are 8080 code
// and the Z80 executes it, faster per instruction and twice as fast
// again in turbo.  This is that, with tv80 (Guy Hutchison's Verilog of
// Daniel Wallner's T80, MIT) clocked by an enable at 2.53 MHz or 5.06
// MHz - phase 0 of the T-state, and phase 8 as well in turbo.  The bus
// is presented to top.v exactly as cpu8080.v presents the ВМ80's: a
// read strobe at phase 9 with the address, a write strobe with the
// data, the three acknowledge cycles of the ВН59's CALL, the device
// page's wait state, and the memory queue's wait.
//
// What the Z80 does that the ВМ80 does not, and how it is handled:
//  * its interrupt is IM 0, the bus instruction, and for a three-byte
//    CALL the real Z80 reads the two operands with further acknowledge
//    cycles.  tv80 reads them from memory at PC and would increment PC
//    for them; one line of tv80_core.v is changed so that PC stands
//    still during the interrupt instruction (marked "Korvet Nano"), and
//    this wrapper answers those two reads from the controller instead
//    of memory - inta_n 1 and 2, as cpu8080.v numbers them;
//  * it samples WAIT at the end of T2, one enable after the request
//    leaves; a read served in its own slot is back four clocks before
//    that in either speed, so the common case has no wait.
//
// tv80's own bus outputs (tv80s.v's registered rd_n/wr_n/mreq_n/iorq_n,
// with WR/ from T2 - its T2Write = 1 - so that a write, like a read,
// waits in T2 for the strobe) are reproduced here on the enable, so
// that this file and cpu8080.v are the only two the rest of the design
// knows about.
//========================================================================
module cpuz80 (
    input             clk,
    input             reset,        // active high
    input      [3:0]  tphase,
    input             turbo,        // 5 MHz

    output reg [15:0] adr,
    output reg [7:0]  dout,
    input      [7:0]  din,
    output     [15:0] a_now,
    output     [7:0]  d_now,
    output reg        cyc_m1,
    output            mem_rd,
    output            io_rd,
    output            mem_wr,
    output            io_wr,
    output            inta_stb,
    output reg [1:0]  inta_n,
    input      [7:0]  inta_data,

    input             int_req,
    output            inte,

    input             dev_hit,
    input             mem_wait,

    output     [7:0]  dbg_opcode,
    output            dbg_m1
);

wire cen = (tphase == 4'd0) || (turbo && tphase == 4'd8);

wire        m1_n, iorq, no_read, write, intcycle_n;
wire [15:0] A;
wire [7:0]  core_dout;
wire [6:0]  mcycle, tstate;
reg  [7:0]  di_reg = 8'd0;
reg         wait_n = 1'b1;

// the byte the core reads: the controller's in an acknowledge cycle
wire        in_inta = !intcycle_n;
wire [7:0]  di_now  = in_inta ? inta_data : din;

tv80_core #(.Mode(0), .IOWait(1)) core (
    .cen       (cen        ),
    .m1_n      (m1_n       ),
    .iorq      (iorq       ),
    .no_read   (no_read    ),
    .write     (write      ),
    .rfsh_n    (           ),
    .halt_n    (           ),
    .wait_n    (wait_n     ),
    .int_n     (~int_req   ),
    .nmi_n     (1'b1       ),
    .reset_n   (~reset     ),
    .busrq_n   (1'b1       ),
    .busak_n   (           ),
    .clk       (clk        ),
    .IntE      (inte       ),
    .stop      (           ),
    .A         (A          ),
    .dinst     (di_now     ),
    .di        (di_reg     ),
    .dout      (core_dout  ),
    .mc        (mcycle     ),
    .ts        (tstate     ),
    .intcycle_n(intcycle_n )
);

assign a_now  = A;
assign d_now  = core_dout;
assign dbg_m1 = !m1_n;

//------------------------------------------------------------------------
// tv80s.v's bus, on the enable (T2Write = 1: WR/ from T2, see below)
//------------------------------------------------------------------------
reg rd_n = 1'b1, wr_n = 1'b1, mreq_n = 1'b1, iorq_n = 1'b1;

always @(posedge clk) begin
    if (reset) begin
        rd_n <= 1'b1; wr_n <= 1'b1; mreq_n <= 1'b1; iorq_n <= 1'b1; di_reg <= 8'd0;
    end else if (cen) begin
        rd_n <= 1'b1; wr_n <= 1'b1; mreq_n <= 1'b1; iorq_n <= 1'b1;
        // `adr` is latched HERE, with the request, so that it is
        // standing when the phase-9 strobe goes out (top.v reads the
        // write's address from `adr`, not from the bus: the 8080 wrapper
        // latches it at SYNC, a T-state before WR/).
        if (mcycle[0]) begin
            // M1: an opcode fetch (MREQ), or the acknowledge of the
            // ВН59's first byte (IORQ, the M1 pin being low).  The
            // real Z80 has RD/ high in the acknowledge and only IORQ/;
            // here rd_n LOW in both, because it is what makes the
            // strobe below go out, and the acknowledge must be strobed
            // like the two operand reads or the controller's three
            // bytes come one cycle late (a CALL to {low byte, CDh}:
            // found in simulation, 6 Sep 2026).
            if (tstate[1] || (tstate[2] && !wait_n)) begin
                rd_n   <= 1'b0;
                mreq_n <= ~intcycle_n;
                iorq_n <= intcycle_n;
                adr    <= A;
            end
        end else begin
            if ((tstate[1] || (tstate[2] && !wait_n)) && !no_read && !write) begin
                rd_n   <= 1'b0;
                iorq_n <= ~iorq;
                mreq_n <= iorq;
                adr    <= A;
            end
            // WR/ in T2, tv80s.v's T2Write = 1 form, NOT its default T3:
            // in turbo a T-state is eight clocks and T3 alone may not
            // contain phase 9, so the write waits in T2 like a read does
            // until the strobe has gone out (`served`, below).  The core
            // has `dout` valid from T2 (tv80_core.v: set at T1).
            if ((tstate[1] || (tstate[2] && !wait_n)) && write) begin
                wr_n   <= 1'b0;
                iorq_n <= ~iorq;
                mreq_n <= iorq;
                adr    <= A;
            end
        end
        if (tstate[2] && wait_n && !write && !no_read)
            di_reg <= di_now;
    end
end

//------------------------------------------------------------------------
// The strobes: one per bus cycle, at phase 9, the first after the core
// asserted its request; a memory read during the interrupt instruction
// is an acknowledge byte.
//------------------------------------------------------------------------
reg rd_seen = 1'b0, wr_seen = 1'b0;
wire rd_active = !rd_n && (!mreq_n || !iorq_n);
wire wr_active = !wr_n && (!mreq_n || !iorq_n);
wire rd_now = (tphase == 4'd9) && rd_active && !rd_seen;
wire wr_now = (tphase == 4'd9) && wr_active && !wr_seen;

wire is_inta_m1 = !m1_n && !iorq_n;             // the first byte
wire is_inta_op = in_inta && m1_n && !mreq_n;    // the operands

assign mem_rd   = rd_now && !mreq_n && iorq_n && !in_inta;
assign io_rd    = rd_now && !iorq_n && !is_inta_m1;
assign mem_wr   = wr_now && !mreq_n;
assign io_wr    = wr_now && !iorq_n;
assign inta_stb = rd_now && (is_inta_m1 || is_inta_op);

always @(posedge clk) begin
    if (reset) begin
        rd_seen <= 1'b0; wr_seen <= 1'b0; inta_n <= 2'd0; cyc_m1 <= 1'b0;
    end else begin
        if (rd_now) begin rd_seen <= 1'b1; cyc_m1 <= !m1_n; end
        if (!rd_active) rd_seen <= 1'b0;
        if (wr_now) begin wr_seen <= 1'b1; dout <= core_dout; end
        if (!wr_active) wr_seen <= 1'b0;
        if (inta_stb) begin
            if (is_inta_m1) inta_n <= 2'd1;
            else            inta_n <= (inta_n == 2'd2) ? 2'd0 : inta_n + 2'd1;
        end
    end
end

//------------------------------------------------------------------------
// WAIT: a read or a write is not served until phase 9 comes round, and
// in turbo the enable that samples WAIT can come first (T2 ends at
// phase 8 when T1 began at phase 0) - so WAIT is held from the request
// until the strobe has gone out and the memory has answered; that costs
// a cycle that starts at phase 0 one wait state in turbo and none
// otherwise.
// Then the device page's one wait state (set at the strobe, cleared at
// the enable that sampled it), and the memory queue's.
//------------------------------------------------------------------------
reg dev_wait = 1'b0;
always @(posedge clk) begin
    if (reset)                            dev_wait <= 1'b0;
    else if ((rd_now || wr_now) && dev_hit) dev_wait <= 1'b1;
    else if (cen)                         dev_wait <= 1'b0;
end
// the strobe went out three clocks ago at least: the ROM, the devices
// and the text RAM have answered by then, the SDRAM says so itself
wire      bus_active = rd_active || wr_active;
reg [1:0] served = 2'd0;
always @(posedge clk) begin
    if (reset || !bus_active) served <= 2'd0;
    else if (rd_now || wr_now) served <= 2'd1;
    else if (served != 2'd0 && served != 2'd3) served <= served + 2'd1;
end
always @(*) wait_n = !(dev_wait || mem_wait || (bus_active && served != 2'd3));

reg [7:0] opcode = 8'd0;
always @(posedge clk) if (cen && mcycle[0] && tstate[2] && wait_n) opcode <= di_now;
assign dbg_opcode = opcode;

endmodule
