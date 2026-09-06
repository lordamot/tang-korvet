`timescale 1ns / 1ps
//========================================================================
// fdc.v - the Корвет's floppy controller: a КР1818ВГ93 at 18h-1Bh of
// the device page, four drives from .kdi images.
//
// The chip is MiSTer's wd1793.sv (MikeJ, Sorgelig) in its sector-image
// mode, as PK8000 Nano uses it: a .kdi is 80 tracks x 2 sides x 5
// sectors of 1024 bytes, track-side-sector order, 819200 bytes - the
// same geometry the Сура's .fdd has, so nothing in the core changed.
// The drive, the side and the motor come from the ВВ55 #1's port B
// (техописание §8): bits 0..3 select drive 0..3, bit 4 the side, bit 5
// starts the three-second motor one-shot whose end is IRQ7; bits 6 and
// 7 pick the clock and density on the machine and are read here for
// nothing.  One chip, four images: the drive bits pick which SD slot a
// transfer goes to, and the chip's track register is whatever the last
// seek left, which is the machine's behaviour too.
//
// The chip wants its rd/wr as levels a few of its clock enables long
// (it edge-detects them on `ce`, here the CPU's 2.5 MHz), so a one-clock
// strobe from the CPU is stretched to sixteen clocks; the data register
// advances on the FALLING edge, so the byte read is the one on the bus
// while the level is up, taken two clocks after the strobe.
//========================================================================
module fdc (
    input             clk,
    input             reset,
    input             ce,           // 2.5 MHz enable
    input             en,           // the OSD's floppy switch

    // the CPU, the four registers
    input             rd_stb,
    input             wr_stb,
    input      [1:0]  a,
    input      [7:0]  wdata,
    output reg [7:0]  rdata,        // valid three clocks after rd_stb

    // the ВВ55 #1's port B
    input      [7:0]  ctrl,

    // the images
    input      [3:0]  mounted,      // one clock each: slots 0..3
    input      [31:0] image_size,
    input      [3:0]  present,
    input      [3:0]  wprot,

    // the SD path: client 0..3 by drive
    output     [1:0]  drive,
    output            sd_rd,
    output            sd_wr,
    output     [31:0] sd_sector,
    input             sd_ack,
    input             sd_done,
    input             outen,
    input      [8:0]  outaddr,
    input      [7:0]  outbyte,
    output     [7:0]  inbyte,

    output            busy,         // for an LED
    output            motor_irq     // IRQ7: the motor is off (the one-shot's inverted output)
);

// the drive: the lowest select bit set (Emu80's setPortB), else 0
wire [1:0] drv = ctrl[0] ? 2'd0 : ctrl[1] ? 2'd1 : ctrl[2] ? 2'd2 : ctrl[3] ? 2'd3 : 2'd0;
wire       side = ctrl[4];
assign drive = drv;

//------------------------------------------------------------------------
// The motor: three seconds from the last write with bit 5 set - the
// retriggerable one-shot D5 (техописание §8).  Its inverted output is
// IRQ7: high while the one-shot is idle, so the request is the level
// "motor off" and its rising edge the time-out, which is what the ВН59
// sees on the board (pic8259.v: a request follows its line).
//------------------------------------------------------------------------
reg  [27:0] motor = 28'd0;
reg         mot_d = 1'b0;
assign motor_irq = (motor == 28'd0);
always @(posedge clk) begin
    mot_d <= ctrl[5];
    if (reset) motor <= 28'd0;
    else if (ctrl[5] && !mot_d) motor <= 28'd121500000;      // 3 s
    else if (motor != 28'd0) motor <= motor - 28'd1;
end

//------------------------------------------------------------------------
// The chip
//------------------------------------------------------------------------
reg  [1:0]  a_r = 2'd0;
reg  [7:0]  wd_din = 8'd0;
reg  [4:0]  rd_hold = 5'd0, wr_hold = 5'd0;
reg  [1:0]  rd_pipe = 2'd0;

wire [7:0] wd_dout;
wire       wd_drq, wd_intrq, wd_busy;
wire       wd_rd = (rd_hold != 5'd0);
wire       wd_wr = (wr_hold != 5'd0);
wire       wd_io = en && (wd_rd || wd_wr);

wd1793 #(.RWMODE(1), .EDSK(0)) chip (
    .clk_sys     (clk),
    .ce          (ce),
    .reset       (reset || !en),
    .io_en       (wd_io),
    .rd          (wd_rd),
    .wr          (wd_wr),
    .addr        (a_r),
    .din         (wd_din),
    .dout        (wd_dout),
    .drq         (wd_drq),
    .intrq       (wd_intrq),
    .busy        (wd_busy),
    .wp          (wprot[drv]),
    .size_code   (3'd3),           // 5 x 1024
    .layout      (1'b0),           // track, side, sector
    .side        (side),
    .ready       (present[drv]),
    .img_mounted (|mounted),
    .img_size    (image_size),
    .prepare     (),
    .sd_lba      (sd_sector),
    .sd_rd       (sd_rd),
    .sd_wr       (sd_wr),
    .sd_ack      (sd_ack),
    .sd_buff_addr(outaddr),
    .sd_buff_dout(outbyte),
    .sd_buff_din (inbyte),
    .sd_buff_wr  (outen && sd_ack),
    .input_active(1'b0),
    .input_addr  (20'd0),
    .input_data  (8'd0),
    .input_wr    (1'b0),
    .buff_addr   (),
    .buff_read   (),
    .buff_din    (8'd0)
);

assign busy = wd_busy;

always @(posedge clk) begin
    rd_pipe <= {rd_pipe[0], rd_stb && en};
    if (rd_hold != 5'd0) rd_hold <= rd_hold - 5'd1;
    if (wr_hold != 5'd0) wr_hold <= wr_hold - 5'd1;
    if (reset) begin
        rd_hold <= 5'd0; wr_hold <= 5'd0;
    end else begin
        if (rd_stb && en) begin a_r <= a; rd_hold <= 5'd16; end
        if (wr_stb && en) begin a_r <= a; wd_din <= wdata; wr_hold <= 5'd16; end
    end
    if (rd_pipe[1]) rdata <= en ? wd_dout : 8'hFF;
end

endmodule
