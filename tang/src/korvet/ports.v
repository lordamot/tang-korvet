`timescale 1ns / 1ps
//========================================================================
// ports.v - the register page and the keyboard.
//
// The register page (FA00h-FAFFh in most configurations, 3A00h and
// BF00h and FF00h in others: memmap.v) is three write-only registers
// picked by a LOW address bit, since only the top byte of the address
// reaches the PLM: A7 low is the system register (7Fh - the memory
// configuration, bits 6..2), A6 low the colour register (BFh - the
// graphics RAM's write mask and read compare, membus.v), A2 low the
// colour table (FBh - low nibble the entry, high nibble {I, R, G, B},
// video.v).  MAME's sysreg_w decodes them the same way; a write to a
// byte with more than one of those bits low hits more than one
// register.  Reads of the page are the RAM under it (the PLM again).
//
// The keyboard (F800h-F9FFh) is the техописание's: address bits A7..A0
// each select a row of the main 8 x 8 matrix and a read is the OR of
// the selected rows, a pressed key a 1; with A8 set, A2..A0 select the
// three rows of the second field (the cursor and function keys).  The
// rows and columns are Emu80's KorvetKeyboard tables; the MCU sends a
// key as row*8 + column + 1 (1..64 the main field, 65..88 the second)
// with bit 7 for a release, and the matrix lives here.
//========================================================================
module ports (
    input             clk,
    input             reset,

    // the register page
    input             reg_wr,       // one clock: a write to the page, a and wdata valid
    input      [7:0]  a,
    input      [7:0]  wdata,
    output reg [6:2]  sysreg,
    output reg [7:0]  ncreg,
    output reg        lut_we,
    output reg [3:0]  lut_adr,
    output reg [3:0]  lut_data,

    // the keyboard
    input             kbd_rd,       // one clock: kbd_data a clock later
    input      [8:0]  kbd_a,
    output reg [7:0]  kbd_data,
    input      [7:0]  kbd_byte,
    input             kbd_stb
);

always @(posedge clk) begin
    lut_we <= 1'b0;
    if (reset) begin
        sysreg <= 5'd0; ncreg <= 8'd0;
    end else if (reg_wr) begin
        if (!a[7]) sysreg <= wdata[6:2];
        if (!a[6]) ncreg  <= wdata;
        if (!a[2]) begin lut_we <= 1'b1; lut_adr <= wdata[3:0]; lut_data <= wdata[7:4]; end
    end
end

reg [7:0] keys1 [0:7];
reg [7:0] keys2 [0:2];
integer ki;
initial begin
    for (ki = 0; ki < 8; ki = ki + 1) keys1[ki] = 8'd0;
    for (ki = 0; ki < 3; ki = ki + 1) keys2[ki] = 8'd0;
end

wire [6:0] code = kbd_byte[6:0] - 7'd1;      // 0..87
wire       ext  = (kbd_byte[6:0] > 7'd64);
wire [6:0] code2 = kbd_byte[6:0] - 7'd65;
wire [2:0] row1 = code[5:3];
wire [1:0] row2 = code2[4:3];
wire [2:0] col  = ext ? code2[2:0] : code[2:0];

always @(posedge clk) begin
    if (reset) begin
        for (ki = 0; ki < 8; ki = ki + 1) keys1[ki] <= 8'd0;
        for (ki = 0; ki < 3; ki = ki + 1) keys2[ki] <= 8'd0;
    end else if (kbd_stb && kbd_byte[6:0] != 7'd0) begin
        if (!ext)                keys1[row1][col] <= ~kbd_byte[7];
        else if (row2 < 2'd3)    keys2[row2][col] <= ~kbd_byte[7];
    end
end

reg [7:0] acc;
always @(*) begin
    acc = 8'd0;
    if (!kbd_a[8]) begin
        for (ki = 0; ki < 8; ki = ki + 1) if (kbd_a[ki]) acc = acc | keys1[ki];
    end else begin
        for (ki = 0; ki < 3; ki = ki + 1) if (kbd_a[ki]) acc = acc | keys2[ki];
    end
end
always @(posedge clk) if (kbd_rd) kbd_data <= acc;

endmodule
