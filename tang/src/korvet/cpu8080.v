`timescale 1ns / 1ps
//========================================================================
// cpu8080.v - the КР580ВМ80А and its bus, as the Корвет sees them.
//
// The core is vm80a (tang/src/korvet/vm80a.v, 1801BM1, CC-BY 3.0): a
// gate-level replica of the real die that runs on a fast clock with the
// two 8080 clock phases fed in as one-clock enables.  Here the system
// clock is 40.5 MHz and a T-state is sixteen of them, so F1 is the
// enable at phase 0 and F2 the one at phase 8 - 2.53 MHz, the machine's
// 2.5.  Everything else on the board counts the same phase (`tphase`,
// made in top.v), which is what lets the SDRAM give the CPU a fixed slot
// in every T-state (membus.v, sdram.v).  PK8000 Nano's wrapper, with
// the Корвет's three differences:
//
//  * the machine has no I/O instructions in use - its devices are in the
//    memory map - and every access to the device page costs one wait
//    state, inserted by the board itself (D24: 1READY = CSDEV | WAIT,
//    техописание §3).  `dev_hit` at the strobe says the cycle is one of
//    those, and READY is held off for the one F2 sample of T2;
//  * the interrupt is the КР580ВН59's three-byte CALL: the first cycle
//    of it is M1 with the INTA status bit and the next two are reads of
//    the controller too - the two M8 cycles of the техописание.  The
//    board does not trust the status bit for those: its flip-flop D15
//    is set by the first acknowledge and cleared by the first write
//    cycle (the CALL's push), and INTA is DBIN while it is set.  vm80a
//    shows why: its INTA flag drops when the INT pin drops, which the
//    ВН59 does at the first acknowledge.  So `int_ff` here is D15, and
//    every read while it is up is an acknowledge; `inta_stb` with
//    `inta_n` counts them and `inta_data` is what the controller says;
//  * a read the memory has not answered by T2's sample, or a write the
//    queue has no room for, holds READY through `mem_wait` (membus.v: a
//    read of a word with a write still queued, a full queue).  On the
//    machine itself neither happens; here they are rare and exact.
//
// One request pulse per machine cycle for the memory system: `mem_rd`
// at phase 9 of the T-state SYNC is seen in (address valid on a_now),
// `mem_wr` at the first phase 9 after WR/ falls (data valid on d_now,
// address in adr).  IN and OUT cycles exist (io_rd, io_wr) and top.v
// answers them with 0FFh.
//========================================================================
module cpu8080 (
    input             clk,
    input             reset,        // active high; hold it a few T-states
    input      [3:0]  tphase,       // 0..15, the T-state phase (top.v)

    // the bus, one request a machine cycle
    output reg [15:0] adr,          // valid from mem_rd / mem_wr to the next
    output reg [7:0]  dout,         // write data, valid with mem_wr
    input      [7:0]  din,          // read data: valid by phase 13 of T1 for a slot read
    output     [15:0] a_now,        // the core's address bus as it stands
    output     [7:0]  d_now,        // the core's data bus as it stands
    output reg        cyc_m1,       // the cycle is an opcode fetch
    output            mem_rd,       // phase 9 of the SYNC T-state: a memory read
    output            io_rd,
    output            mem_wr,       // phase 9 after WR/ fell: write d_now to adr
    output            io_wr,
    output            inta_stb,     // an acknowledge cycle has started (three a CALL)
    output reg [1:0]  inta_n,       // which of the three: 0 the opcode, 1 low, 2 high
    input      [7:0]  inta_data,    // the controller's byte for it

    // interrupt
    input             int_req,
    output            inte,

    // waits
    input             dev_hit,      // at the strobe: this cycle is the device page
    input             mem_wait,     // level: the memory is not ready for this cycle

    // for the testbench
    output     [7:0]  dbg_opcode,
    output            dbg_sync
);

wire f1 = (tphase == 4'd0);
wire f2 = (tphase == 4'd8);

wire [15:0] pin_a;
wire [7:0]  pin_dout;
wire        pin_sync, pin_dbin, pin_wr_n, pin_inte, pin_wait;
wire        pin_ready;
reg  [7:0]  pin_din;

vm80a_core core (
    .pin_clk   (clk      ),
    .pin_f1    (f1       ),
    .pin_f2    (f2       ),
    .pin_reset (reset    ),
    .pin_a     (pin_a    ),
    .pin_dout  (pin_dout ),
    .pin_din   (pin_din  ),
    .pin_aena  (         ),
    .pin_dena  (         ),
    .pin_hold  (1'b0     ),
    .pin_hlda  (         ),
    .pin_ready (pin_ready),
    .pin_wait  (pin_wait ),
    .pin_int   (int_req  ),
    .pin_inte  (pin_inte ),
    .pin_sync  (pin_sync ),
    .pin_dbin  (pin_dbin ),
    .pin_wr_n  (pin_wr_n )
);

assign inte     = pin_inte;
assign a_now    = pin_a;
assign d_now    = pin_dout;
assign dbg_sync = pin_sync;

//------------------------------------------------------------------------
// The status byte: vm80a raises SYNC and puts the status on its data
// bus on the same F2 edge, so both are there at phase 9 of that T-state.
//   D0 INTA  D1 WO/  D2 STACK  D3 HLTA  D4 OUT  D5 M1  D6 INP  D7 MEMR
//------------------------------------------------------------------------
wire cyc_start = (tphase == 4'd9) && pin_sync;

wire st_inta = pin_dout[0];
wire st_wo_n = pin_dout[1];
wire st_out  = pin_dout[4];
wire st_m1   = pin_dout[5];
wire st_inp  = pin_dout[6];

reg  cyc_wr   = 1'b0;
reg  cyc_io   = 1'b0;
reg  cyc_inta = 1'b0;
reg  wr_done  = 1'b0;
reg  dev_wait = 1'b0;
reg  int_ff   = 1'b0;               // D15: an interrupt's CALL is being read

// the cycle is an acknowledge: the M1 that says so, or any read while
// the flip-flop is up (the CALL's two operands)
wire   ack_cycle = st_inta || (int_ff && st_wo_n);

always @(posedge clk) begin
    if (cyc_start) begin
        adr      <= pin_a;
        cyc_io   <= st_inp | st_out;
        cyc_m1   <= st_m1;
        cyc_inta <= ack_cycle;
        cyc_wr   <= ~st_wo_n;
        wr_done  <= 1'b0;
    end
    if (wr_stb) begin
        wr_done <= 1'b1;
        dout    <= pin_dout;
    end
    if (reset)                            int_ff <= 1'b0;
    else if (cyc_start && st_inta && st_m1) int_ff <= 1'b1;
    else if (wr_stb)                      int_ff <= 1'b0;
end

wire   rd_stb   = cyc_start && st_wo_n && !ack_cycle;
wire   wr_stb   = (tphase == 4'd9) && cyc_wr && !pin_wr_n && !wr_done && !pin_sync;
assign mem_rd   = rd_stb && !(st_inp | st_out);
assign io_rd    = rd_stb &&  st_inp;
assign mem_wr   = wr_stb && !cyc_io;
assign io_wr    = wr_stb &&  cyc_io;
assign inta_stb = cyc_start && ack_cycle;

// the three acknowledge cycles of one CALL: the count restarts at the
// first (M1 with INTA) and after the third
always @(posedge clk) begin
    if (reset) inta_n <= 2'd0;
    else if (inta_stb) begin
        if (st_inta && st_m1) inta_n <= 2'd1;
        else                  inta_n <= (inta_n == 2'd2) ? 2'd0 : inta_n + 2'd1;
    end
end

// The bus the core reads: the controller's byte in an acknowledge cycle,
// the memory system's otherwise.
always @(*) pin_din = cyc_inta ? inta_data : din;

//------------------------------------------------------------------------
// READY.  The device-page wait is one TW: set at the strobe, seen at
// T2's F2 sample, cleared the clock after it.  mem_wait is the memory
// queue's; it is a level and lasts as long as it needs to.
//------------------------------------------------------------------------
always @(posedge clk) begin
    if (reset)                      dev_wait <= 1'b0;
    else if (cyc_start && dev_hit)  dev_wait <= 1'b1;
    else if (tphase == 4'd9)        dev_wait <= 1'b0;   // the T-state after the sample
end

assign pin_ready = !dev_wait && !mem_wait;

//------------------------------------------------------------------------
// The opcode, for the testbench: din is settled by phase 13 of the
// T-state after the request
//------------------------------------------------------------------------
reg [7:0] opcode = 8'h00;
reg       m1_pending = 1'b0;
always @(posedge clk) begin
    if (cyc_start && st_m1) m1_pending <= 1'b1;
    if (m1_pending && tphase == 4'd15 && !mem_wait) begin
        opcode     <= pin_din;
        m1_pending <= 1'b0;
    end
end
assign dbg_opcode = opcode;

endmodule
