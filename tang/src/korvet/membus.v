`timescale 1ns / 1ps
//========================================================================
// membus.v - the CPU's side of the SDRAM: what lives where, and the
// write queue that keeps the CPU from ever waiting for a write.
//
// The SDRAM (sdram.v) gives the CPU one slot in every T-state, at
// phase 9, for one 32-bit word access.  Three regions share it:
//
//   words 00000h-03FFFh  the 64 KB main RAM, four bytes a word, a byte
//                        picked by its lane (address bits 1:0)
//   words 04000h-05FFFh  a ROM image loaded from the SD card (romload.v),
//                        the same way; the built-in ОПТС is in BSRAM
//   words 20000h-2FFFFh  the graphics RAM (ГЗУ): one word an address,
//                        {8'h00, plane 2, plane 1, plane 0}, 64 K of them
//                        (the four 16 KB pages of each plane)
//
// A read is one slot and answers in the same T-state it was asked in,
// so the CPU sees no wait state - unless a write to the same word is
// still queued, in which case rd_busy holds the CPU until the queue has
// drained past it (the hazard).  A write to the main RAM is one slot
// with the lane's byte enable.  A write to the graphics RAM is what the
// Корвет's colour register makes it: a mask applied to three planes at
// once, which on a plane-per-bit memory is a read-modify-write - two
// slots here, the read then the write, with the colour register's
// value taken at the moment of the write (Emu80's
// KorvetGraphicsAdapter::writeByte, MAME's gzu_w, the same arithmetic).
// So writes are queued, four deep, and a read of anything but a queued
// word goes ahead of them.  An 8080 makes at most one memory access
// every three T-states and the queue drains one step a T-state, so it
// holds a PUSH into the graphics RAM (two writes three T-states apart)
// with room to spare; when it is full the write strobe stalls the CPU
// through wr_wait.
//
// The MCU's bytes (poke.v) join the queue as main-RAM writes; the ROM
// loader (romload.v) owns the slot outright while `hold` is up and the
// CPU is in reset.
//========================================================================
module membus (
    input             clk,
    input             reset,
    input      [3:0]  tphase,

    // the CPU, strobes at phase 9 (cpu8080.v / cpuz80.v through top.v)
    input             rd,           // a read of one of the three regions
    input      [20:0] rd_word,
    input      [1:0]  rd_lane,
    input             rd_gzu,       // the graphics RAM: answer the word, not a lane
    output reg        rd_busy,      // from the strobe until the data is here
    output reg        rd_done,      // one clock, with the data
    output reg [7:0]  rd_data,      // the lane's byte (RAM, ROM)
    output reg [23:0] rd_planes,    // the three planes (graphics RAM)

    input             wr,
    input      [20:0] wr_word,
    input      [1:0]  wr_lane,
    input      [7:0]  wr_data,
    input             wr_gzu,
    input      [7:0]  wr_ncreg,     // the colour register, for a graphics write
    output            wr_wait,      // the queue is full: hold the CPU

    // the MCU's bytes: main RAM, taken when there is room
    input             poke_stb,
    input      [15:0] poke_adr,
    input      [7:0]  poke_data,
    output            poke_room,

    // the ROM loader: a byte at a time while hold is up
    input             hold,
    input             ld_req,       // level: write ld_data to the byte ld_adr of the ROM region
    input      [14:0] ld_adr,
    input      [7:0]  ld_data,
    output reg        ld_ack,       // one clock: taken

    // sdram.v's CPU port
    output            sd_req,
    output            sd_we,
    output     [20:0] sd_adr,
    output     [31:0] sd_wdata,
    output     [3:0]  sd_wmask,
    input      [31:0] sd_rdata,
    input             sd_ack
);

//------------------------------------------------------------------------
// The queue
//------------------------------------------------------------------------
reg  [39:0] q [0:3];                // {gzu, word[20:0], lane[1:0], data[7:0], ncreg[7:0]}
reg  [2:0]  wp = 3'd0, rp = 3'd0;
wire        q_empty = (wp == rp);
wire        q_full  = (wp[1:0] == rp[1:0]) && (wp[2] != rp[2]);
wire [39:0] head    = q[rp[1:0]];
wire        h_gzu   = head[39];
wire [20:0] h_word  = head[38:18];
wire [1:0]  h_lane  = head[17:16];
wire [7:0]  h_data  = head[15:8];
wire [7:0]  h_ncreg = head[7:0];

assign wr_wait   = q_full;
assign poke_room = !q_full && !wr;      // the CPU's own write has the entry first

// a read of a word with a write still queued must wait for it: entry
// rp+k is live for k below the count of entries, wp - rp (0..4)
reg  [20:0] rd_word_r = 21'd0;
reg  [1:0]  rd_lane_r = 2'd0;
reg         rd_gzu_r  = 1'b0;
wire [20:0] rd_w_now  = rd ? rd_word : rd_word_r;
wire [2:0]  q_count   = wp - rp;
integer i;
reg  [1:0]  k;
reg         hz;
always @(*) begin
    hz = 1'b0;
    for (i = 0; i < 4; i = i + 1) begin
        k = i[1:0] - rp[1:0];
        if ({1'b0, k} < q_count && q[i][38:18] == rd_w_now) hz = 1'b1;
    end
end

//------------------------------------------------------------------------
// The read-modify-write of a graphics word
//------------------------------------------------------------------------
reg         rmw_rd   = 1'b0;        // the read step is out
reg         rmw_have = 1'b0;        // the word is in rmw_new: the write step is due
reg  [31:0] rmw_new  = 32'd0;

function [7:0] plane_wr(input [7:0] old, input [7:0] data, input [7:0] nc, input [1:0] pl);
    reg sel;
    begin
        sel = nc[1 + pl];
        if (nc[7])                       // colour mode: the bit says set or clear
            plane_wr = sel ? (old | data) : (old & ~data);
        else if (!sel)                   // plane mode: bits 3..1 EXCLUDE a plane
            plane_wr = nc[0] ? (old | data) : (old & ~data);
        else
            plane_wr = old;
    end
endfunction

//------------------------------------------------------------------------
// Who gets the slot.  Requests are combinational at phase 9 so that they
// are UP on the slot's first clock (sdram.v samples then).
//------------------------------------------------------------------------
wire slot    = (tphase == 4'd9);
wire want_rd = (rd || rd_busy) && !hz;
wire do_ld   = slot && hold && ld_req;
wire do_rd   = slot && !hold && want_rd;
wire do_wq   = slot && !hold && !want_rd && !q_empty && !rmw_rd;

assign sd_req   = do_ld || do_rd || do_wq;
assign sd_we    = do_ld || (do_wq && (!h_gzu || rmw_have));
assign sd_adr   = do_ld ? {6'd0, 2'b10, ld_adr[14:2]} : do_rd ? rd_w_now : h_word;
assign sd_wdata = do_ld ? {4{ld_data}} : (h_gzu && rmw_have) ? rmw_new : {4{h_data}};
assign sd_wmask = do_ld ? (4'b0001 << ld_adr[1:0]) :
                  (h_gzu ? 4'b0111 : (4'b0001 << h_lane));

reg ack_is_rd = 1'b0;

always @(posedge clk) begin
    rd_done <= 1'b0;
    ld_ack  <= 1'b0;
    if (reset) begin
        wp <= 3'd0; rp <= 3'd0; rd_busy <= 1'b0; rmw_rd <= 1'b0; rmw_have <= 1'b0;
        ack_is_rd <= 1'b0;
    end else begin
        // the CPU's read: remembered until served
        if (rd) begin
            rd_word_r <= rd_word; rd_lane_r <= rd_lane; rd_gzu_r <= rd_gzu;
            rd_busy   <= 1'b1;
        end
        // the CPU's write, and the MCU's, into the queue
        if (wr && !q_full) begin
            q[wp[1:0]] <= {wr_gzu, wr_word, wr_lane, wr_data, wr_ncreg};
            wp <= wp + 3'd1;
        end else if (poke_stb && poke_room) begin
            q[wp[1:0]] <= {1'b0, 7'd0, poke_adr[15:2], poke_adr[1:0], poke_data, 8'd0};
            wp <= wp + 3'd1;
        end

        if (do_ld) ld_ack <= 1'b1;
        if (do_rd) ack_is_rd <= 1'b1;
        if (do_wq) begin
            ack_is_rd <= 1'b0;
            if (!h_gzu || rmw_have) begin
                rp <= rp + 3'd1;               // the write step is out: done
                rmw_have <= 1'b0;
            end else
                rmw_rd <= 1'b1;                // the read step is out
        end

        if (sd_ack) begin
            if (ack_is_rd) begin
                rd_busy   <= 1'b0;
                rd_done   <= 1'b1;
                rd_planes <= sd_rdata[23:0];
                case (rd_lane_r)
                    2'd0: rd_data <= sd_rdata[7:0];
                    2'd1: rd_data <= sd_rdata[15:8];
                    2'd2: rd_data <= sd_rdata[23:16];
                    2'd3: rd_data <= sd_rdata[31:24];
                endcase
            end else if (rmw_rd) begin
                rmw_rd   <= 1'b0;
                rmw_have <= 1'b1;
                rmw_new  <= {8'h00,
                             plane_wr(sd_rdata[23:16], h_data, h_ncreg, 2'd2),
                             plane_wr(sd_rdata[15:8],  h_data, h_ncreg, 2'd1),
                             plane_wr(sd_rdata[7:0],   h_data, h_ncreg, 2'd0)};
            end
        end
    end
end

endmodule
