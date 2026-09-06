`timescale 1ns / 1ps
//========================================================================
// extrom.v - the Korvet-EXTROM disk controller, from the connector in.
//
// The ExtROM (forth32's, the sibling repository korvet-extrom-forth32)
// is an ATmega on the side connector - the ВВ55 #3 - that boots the
// machine from an SD card: when the ОПТС raises Control (the ВВ55 #2's
// port C bit 7) and sees it come back on the ВН59 through the jumper, it
// reads an external ROM through port A with ports B and C as the
// address - the 256-byte loader of phase 1 - and jumps to it; the
// loader puts port A into mode 2 and from then on everything is a
// handshake over that port: the loader asks for the phase-2 loader by
// number, gets it byte by byte and runs it; the system's driver then
// sends five-byte commands and moves 128-byte sectors (api_v2.pdf).
//
// Here the connector's side is this module and the controller's brain
// is the BL616 firmware (mnano/extrom.c), which has the card's file
// system.  Two FIFOs stand between: bytes the machine writes to port A
// go into `rx` and the MCU reads them out through sysctrl.v's CMD 8
// (an interrupt says there are some); bytes the MCU writes into `tx`
// are handed to port A one at a time by the mode-2 strobe as fast as
// the machine takes them.  The phase-1 ROM is 256 bytes the MCU loads
// at start (STAGE1.ROM from the card's extrom folder, or its built-in
// copy) into a small RAM here, and a read of port A while Control is up
// and port A is still in mode 0 answers from it at the address on
// ports C and B - which is how the ОПТС reads a cartridge.  The ВН59's
// level 0 is Control while the switch is on (top.v), as the jumper
// makes it: the pin is called IRQ7, the ОПТС tests bit 0 (devices.v).
//
// Control falling is what the real controller takes as a machine reset
// (it has no reset line: hardware.pdf §8.3); it is latched here for the
// MCU, which restarts its side.  A program that drops Control for its
// own reasons breaks the ExtROM on the machine too.
//========================================================================
module extrom (
    input             clk,
    input             reset,        // mist_rst
    input             en,           // the OSD's switch

    // the ВВ55 #3 (ppi8255.v), device side
    input             control,      // the ВВ55 #2's port C bit 7
    input             mode2,        // port A is in mode 2
    input      [7:0]  pb_out,       // the ROM address, low
    input      [7:0]  pc_out,       // the ROM address, high
    output     [7:0]  pa_in,        // the ROM's byte, when it is asked
    input      [7:0]  pa_out,       // the machine's byte to the controller
    input             obf_n,        // 0: pa_out holds a new byte
    output reg        ack,          // one clock: taken
    output reg        in_stb,       // one clock: present in_data
    output     [7:0]  in_data,
    input             ibf,          // 1: the last byte has not been read yet

    // the MCU (sysctrl.v CMD 8)
    input             mcu_rd,       // one clock: pop a byte of rx onto mcu_rdata
    output     [7:0]  mcu_rdata,
    input             mcu_wr,       // one clock: push mcu_wdata into tx
    input      [7:0]  mcu_wdata,
    input             mcu_flush,    // one clock: both FIFOs emptied
    input             mcu_rom_wr,   // one clock: stage-1 byte at mcu_rom_adr
    input      [7:0]  mcu_rom_adr,
    output     [7:0]  rx_count,     // bytes waiting for the MCU
    output     [7:0]  tx_free,      // room in tx, capped at 255
    output reg        ctrl_fell,    // Control went down (cleared by mcu_flush)
    output            irq           // to the MCU: rx has bytes, or Control fell
);

//------------------------------------------------------------------------
// The phase-1 ROM
//------------------------------------------------------------------------
reg [7:0] rom [0:255];
integer i;
initial for (i = 0; i < 256; i = i + 1) rom[i] = 8'hFF;
always @(posedge clk) if (mcu_rom_wr) rom[mcu_rom_adr] <= mcu_wdata;

wire active = en && control;
reg  [7:0] rom_q = 8'hFF;
always @(posedge clk) rom_q <= rom[pb_out];
assign pa_in = (active && !mode2 && pc_out == 8'd0) ? rom_q : 8'hFF;

//------------------------------------------------------------------------
// The FIFOs: 1 K each, in one BSRAM's worth
//------------------------------------------------------------------------
reg [7:0] rx [0:1023];
reg [7:0] tx [0:1023];
reg [10:0] rx_wp = 11'd0, rx_rp = 11'd0, tx_wp = 11'd0, tx_rp = 11'd0;
wire [10:0] rx_n = rx_wp - rx_rp;
wire [10:0] tx_n = tx_wp - tx_rp;
wire        rx_full = rx_n[10];
wire        tx_empty = (tx_n == 11'd0);
wire        tx_full  = tx_n[10];
wire [10:0] tx_room  = 11'd1024 - tx_n;

assign rx_count = rx_n[10] ? 8'hFF : (rx_n[9:8] != 2'd0 ? 8'hFF : rx_n[7:0]);
assign tx_free  = (tx_room > 11'd255) ? 8'hFF : tx_room[7:0];

reg [7:0] rx_q = 8'd0, tx_q = 8'd0;
assign mcu_rdata = rx_q;
assign in_data   = tx_q;

// the machine's bytes in: OBF/ low means a byte in the output latch;
// one acknowledge per byte, and the ВВ55 raises OBF/ the clock after
reg acked = 1'b0;
always @(posedge clk) begin
    ack <= 1'b0;
    if (obf_n) acked <= 1'b0;
    if (reset || mcu_flush) begin
        rx_wp <= 11'd0; acked <= 1'b0;
    end else if (active && mode2 && !obf_n && !acked && !rx_full) begin
        rx[rx_wp[9:0]] <= pa_out;
        rx_wp <= rx_wp + 11'd1;
        ack   <= 1'b1;
        acked <= 1'b1;
    end
end

// the MCU reads rx
always @(posedge clk) begin
    if (reset || mcu_flush) rx_rp <= 11'd0;
    else if (mcu_rd && rx_n != 11'd0) begin
        rx_rp <= rx_rp + 11'd1;
    end
    rx_q <= rx[rx_rp[9:0]];
end

// the MCU writes tx, the machine takes it through the strobe
reg [1:0] stb_wait = 2'd0;
always @(posedge clk) begin
    in_stb <= 1'b0;
    if (reset || mcu_flush) begin
        tx_wp <= 11'd0; tx_rp <= 11'd0; stb_wait <= 2'd0;
    end else begin
        if (mcu_wr && !tx_full) begin
            tx[tx_wp[9:0]] <= mcu_wdata;
            tx_wp <= tx_wp + 11'd1;
        end
        // present the next byte when the input latch is free; a clock
        // for the read of the RAM and a clock for the ВВ55 to raise IBF
        if (stb_wait != 2'd0) stb_wait <= stb_wait - 2'd1;
        else if (active && mode2 && !ibf && !tx_empty && !in_stb) begin
            in_stb   <= 1'b1;
            tx_rp    <= tx_rp + 11'd1;
            stb_wait <= 2'd2;
        end
    end
    tx_q <= tx[tx_rp[9:0]];
end

//------------------------------------------------------------------------
// Control falling, for the MCU
//------------------------------------------------------------------------
reg ctrl_d = 1'b0;
always @(posedge clk) begin
    ctrl_d <= control;
    if (reset || mcu_flush) ctrl_fell <= 1'b0;
    else if (en && !control && ctrl_d) ctrl_fell <= 1'b1;
end

assign irq = en && ((rx_n != 11'd0) || ctrl_fell);

endmodule
