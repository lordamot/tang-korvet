`timescale 1ns / 1ps
//========================================================================
// video.v - the Корвет's display, and the HDMI raster it is shown on.
//
// The machine draws 512 x 256 pixels at 10 MHz, 656 pixel times a line
// (65.6 us: 82 T-states of 8 pixels), 312 lines a frame, 48.9 Hz - the
// техописание's synchroniser, MAME's numbers; Emu80 uses a 64 us line.
// Here the clock is 40.5 MHz, a pixel four clocks, a line 2624 clocks
// (164 T-states), and the frame 20.2 ms.  The picture is lines 40..295
// of the frame (Emu80's renderLine), the rest is blanking: VBL, which
// the ВВ55 #1 reads on port A bit 1 and which raises IRQ4 as it ends.
//
// A pixel is four bits from three sources read at once: the three
// bit-planes of the graphics RAM (one 32-bit SDRAM word a tile through
// the video slot of the timetable, sdram.v), and the text: a character
// from the 1 K text RAM, its glyph line from the 8 KB character
// generator, inverted by the character's attribute bit.  In the 32-
// column mode a character is doubled and only the even columns of the
// text RAM are shown (Emu80's KorvetRenderer, exactly).  Those four
// bits address the 16 x 4 colour look-up table (port FBh) and its
// entry, {I, R, G, B}, is what goes into the line buffer - so a change
// of the table shows from the next line.
//
// A tile of 8 pixels is two T-states (32 clocks).  Tile t is fetched
// during clocks 32t..32t+31 of the line and shown during the 32 after,
// so the 512 pixels sit at clocks 32..2079 and every fetch of a line is
// inside that line; the display page and the font are read at the
// fetch.  The video slot's word is asked for on phase 0 of the tile's
// first T-state (so that the request is UP on phase 1) and is back by
// phase 6; the text and font reads are BSRAM lookups a few clocks long.
//
// The HDMI side reads the line buffer back twice, so every machine line
// is two output lines of 1312 clocks (32.4 us) with 1024 active pixels
// - each machine pixel twice - which makes a 1024 x 512 picture in a
// 1312 x 624 frame at 30.9 kHz and 48.9 Hz.  Not a CEA mode; PK8000
// Nano's 50.73 Hz was taken by the sinks it met.
//
//   out_h 0..1311 : DE 0..1023, front porch 1024..1047, HSYNC 1048..1111,
//                   back porch 1112..1311 (200 clocks: hdmi_tx.v's data
//                   island wants 154 with four packets)
//   out_v 0..623  : VSYNC 8..13, DE 82..593 (the line drawn at vcnt 40
//                   is read out at vcnt 41)
//========================================================================
module video (
    input             clk,
    input      [11:0] hcnt,         // 0..2623
    input      [8:0]  vcnt,         // 0..311
    input      [3:0]  tphase,

    // the ВВ55 #1's port C, live
    input      [1:0]  disp_page,    // bits 1:0: the graphics page shown
    input             font_sel,     // bit 2
    input             wide,         // bit 3: 32 columns
    input             gzu48,        // the OSD: one graphics page only

    // the colour table, port FBh
    input             lut_we,
    input      [3:0]  lut_adr,
    input      [3:0]  lut_data,

    // the text RAM's video port (txtram.v): registered, a clock behind
    output     [9:0]  txt_adr,
    input      [7:0]  txt_sym,
    input             txt_attr,

    // the character generator (font_rom.v, a registered pROM of words)
    output     [12:0] font_adr,     // {font, symbol, line}
    input      [7:0]  font_data,    // the byte, two clocks behind

    // the SDRAM's video port
    output reg        vid_req,
    output     [20:0] vid_adr,
    input      [31:0] vid_rdata,
    input             vid_ack,

    // to the encoder, one clock a pixel
    output reg        hs,
    output reg        vs,
    output reg        de,
    output reg [7:0]  r,
    output reg [7:0]  g,
    output reg [7:0]  b,

    output            vbl,          // 1 while the picture is being drawn
    output            hbl_tick      // one clock a line, at the start of the blanking
);

//------------------------------------------------------------------------
// Where we are
//------------------------------------------------------------------------
wire        v_pic  = (vcnt >= 9'd40) && (vcnt <= 9'd295);
wire [7:0]  mline  = vcnt[7:0] - 8'd40;          // 0..255 while v_pic
wire        fetch  = v_pic && (hcnt < 12'd2048);  // tiles 0..63
wire [5:0]  tile   = hcnt[10:5];
wire [4:0]  tclk   = hcnt[4:0];                   // clock within the tile period
wire        h_pic  = (hcnt >= 12'd32) && (hcnt < 12'd2080);

assign vbl      = v_pic;
assign hbl_tick = (hcnt == 12'd2080);

//------------------------------------------------------------------------
// The colour table
//------------------------------------------------------------------------
reg [3:0] lut [0:15];
integer li;
initial for (li = 0; li < 16; li = li + 1) lut[li] = 4'd0;
always @(posedge clk) if (lut_we) lut[lut_adr] <= lut_data;

//------------------------------------------------------------------------
// The fetch
//------------------------------------------------------------------------
wire [1:0] page = gzu48 ? 2'd0 : disp_page;
assign vid_adr  = {5'b00010, page, mline, tile};           // words 20000h + {page, line, tile}
assign txt_adr  = {mline[7:4], wide ? {tile[5:1], 1'b0} : tile};

reg [7:0] f_sym  = 8'd0;
reg       f_attr = 1'b0;
reg [7:0] f_font = 8'd0;
reg [23:0] f_gzu = 24'd0;
reg        f_odd = 1'b0;

assign font_adr = {font_sel, f_sym, mline[3:0]};

// the glyph as it will be shown: inverted by the attribute, and in the
// wide mode one half of it doubled.  Combinational from registers that
// are still by clock 6, and taken by the shift register at the hand-over
// itself: a register written at clock 31 and read by the hand-over on
// the same clock handed the shift register the tile BEFORE, and the text
// sat one character right of the graphics (found 10 Sep 2026).
wire [7:0] glyph = f_font ^ {8{f_attr}};
wire [7:0] half  = f_odd ? {glyph[3:0], 4'd0} : glyph;
wire [7:0] wide8 = {half[7], half[7], half[6], half[6], half[5], half[5], half[4], half[4]};
wire [7:0] f_txt = wide ? wide8 : glyph;

always @(posedge clk) begin
    vid_req <= 1'b0;
    if (fetch) begin
        if (tclk == 5'd0)  vid_req <= 1'b1;             // up on phase 1
        if (tclk == 5'd2)  begin f_sym <= txt_sym; f_attr <= txt_attr; f_odd <= tile[0]; end
        if (tclk == 5'd6)  f_font <= font_data;         // the pROM answered
        if (vid_ack)       f_gzu  <= vid_rdata[23:0];
    end
end

//------------------------------------------------------------------------
// The render: four shift registers, one colour a pixel into the line
// buffer.  The hand-over is at the tile period's last clock; the pixel
// is four clocks and the registers shift on its last.
//------------------------------------------------------------------------
reg [7:0] s_txt = 8'd0, s_p0 = 8'd0, s_p1 = 8'd0, s_p2 = 8'd0;
reg [8:0] px = 9'd0;

always @(posedge clk) begin
    if (hcnt == 12'd31 || (h_pic && hcnt[4:0] == 5'd31)) begin
        s_txt <= f_txt; s_p0 <= f_gzu[7:0]; s_p1 <= f_gzu[15:8]; s_p2 <= f_gzu[23:16];
    end else if (h_pic && hcnt[1:0] == 2'd3) begin
        s_txt <= {s_txt[6:0], 1'b0}; s_p0 <= {s_p0[6:0], 1'b0};
        s_p1  <= {s_p1[6:0], 1'b0};  s_p2 <= {s_p2[6:0], 1'b0};
    end
    if (hcnt == 12'd31) px <= 9'd0;
    else if (h_pic && hcnt[1:0] == 2'd3) px <= px + 9'd1;
end

wire [3:0] idx = {s_txt[7], s_p2[7], s_p1[7], s_p0[7]};
wire [3:0] pix = v_pic ? lut[idx] : 4'd0;

// two lines of 512: the one being drawn and the one being shown
reg [3:0] lbuf [0:1023];
reg       wline = 1'b0;
always @(posedge clk) begin
    if (hcnt == 12'd0) wline <= vcnt[0];
    if (h_pic && hcnt[1:0] == 2'd1) lbuf[{wline, px}] <= pix;
end

//------------------------------------------------------------------------
// The output raster, two lines an input line
//------------------------------------------------------------------------
wire        second = (hcnt >= 12'd1312);
wire [10:0] out_h  = second ? hcnt[10:0] - 11'd1312 : hcnt[10:0];
wire [9:0]  out_v  = {vcnt, second};

wire de_n = (out_h < 11'd1024) && (vcnt >= 9'd41) && (vcnt <= 9'd296);
wire hs_n = (out_h >= 11'd1048) && (out_h < 11'd1112);
wire vs_n = (out_v >= 10'd8) && (out_v < 10'd14);

reg [3:0] q;
always @(posedge clk) begin
    q  <= lbuf[{~wline, out_h[9:1]}];
    hs <= hs_n;
    vs <= vs_n;
    de <= de_n;
end

// {I, R, G, B}: Emu80's palette - a lit component is C0h, or FFh with
// the intensity bit; a dark one 00h, or 40h with it
wire [7:0] on  = q[3] ? 8'hFF : 8'hC0;
wire [7:0] off = q[3] ? 8'h40 : 8'h00;
always @(*) begin
    r = q[2] ? on : off;
    g = q[1] ? on : off;
    b = q[0] ? on : off;
end

endmodule
