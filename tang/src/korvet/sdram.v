`timescale 1ns / 1ps
//========================================================================
// sdram.v - the Корвет's memories, in the Tang Nano 20K's SDRAM.
//
// One clock, 40.5 MHz, and a fixed timetable.  A T-state of the CPU is
// sixteen clocks (tphase 0..15, from top.v) and it is cut into two
// eight-clock slots: phases 1-8 belong to the video controller and to
// refresh, phases 9-16 (9..15 and 0) to the CPU.  Each slot is one
// complete random access - ACTIVE, READ or WRITE with auto-precharge,
// data - and the slots never overlap, so neither side ever waits for
// the other and there is no arbiter to get wrong.  PK8000 Nano's
// controller (sdram.v there), with the word made 32 bits wide and the
// slot two clocks longer.
//
//   slot clock  0: ACTIVE     (row)             if a request is up
//               1: READ/WRITE (column, A10=1)   write data driven now
//               2: -                            write data held
//               3: read data captured
//               4: (the late capture)
//               5..7: -
//
// Why clock 3: the chip is clocked by the PLL's copy 90 degrees behind
// ours, so it takes the READ a quarter period after we put it out (in
// clock 2) and, with CAS latency 2, has the word on the bus from tAC
// after its next edge - half way into our clock 3 - until tOH after the
// one following, a third into our clock 4.  The edge ending clock 3 is
// inside that window with margin both ways; at 40.5 MHz the margin on
// the early side is 12 ns where PK8000 Nano had 21.  The self-test
// below moves the capture to clock 4 if the board says so.
//
// The word is 32 bits - the whole width the package wires - because the
// Корвет's graphics memory is three planes and the display wants all
// three bytes of a pixel column at once: one word is {8'h00, plane 2,
// plane 1, plane 0} for one address, so a tile is one video slot and a
// CPU access to the graphics RAM is one read or one read-modify-write.
// The main RAM keeps four bytes a word, picked by the DQM lanes on a
// write and by a mux on a read.  Word address a[20:0]: [20:19] the
// bank, [18:8] the row, [7:0] the column (2M x 32, 4 banks of 2048 rows
// of 256).  Who lives where is membus.v's business.
//
// Initialisation and the self-test are PK8000 Nano's (that file's
// header has the story of the A10 bit and of the capture clock): 65536
// clocks of NOP after PLL lock, the JEDEC steps one a slot; then, with
// the CPU still in reset, four words written through the CPU slot and
// read back in the same order; if they do not come back the capture
// moves to slot clock 4 and the test runs again; a second failure
// raises bist_fail.  Both are on the LEDs.
//========================================================================
module sdram (
    input             clk,
    input             lock,         // the PLL has locked
    output            init,         // the memory is initialised

    input      [3:0]  tphase,

    // CPU port: cpu_req is a one-clock pulse at tphase 9 (membus.v)
    input             cpu_req,
    input             cpu_we,
    input      [20:0] cpu_adr,      // word address
    input      [31:0] cpu_wdata,
    input      [3:0]  cpu_wmask,    // byte lanes written (1 = write)
    output reg [31:0] cpu_rdata,
    output reg        cpu_ack,      // one clock, with cpu_rdata

    // video port: vid_req is a one-clock pulse at tphase 1
    input             vid_req,
    input      [20:0] vid_adr,
    output reg [31:0] vid_rdata,
    output reg        vid_ack,      // one clock, with vid_rdata

    // the self-test's verdict (see the header)
    output reg        bist_done,
    output reg        bist_fail,
    output reg        cap_late,     // reads captured on slot clock 4, not 3

    // the chip
    output reg [10:0] SDRAM_A,
    output reg [1:0]  SDRAM_BA,
    inout      [31:0] SDRAM_DQ,
    output            SDRAM_nCS,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nWE,
    output reg [3:0]  SDRAM_DQM
);

localparam [3:0] CMD_INHIBIT      = 4'b1111;
localparam [3:0] CMD_NOP          = 4'b0111;
localparam [3:0] CMD_ACTIVE       = 4'b0011;
localparam [3:0] CMD_READ         = 4'b0101;
localparam [3:0] CMD_WRITE        = 4'b0100;
localparam [3:0] CMD_PRECHARGE    = 4'b0010;
localparam [3:0] CMD_AUTO_REFRESH = 4'b0001;
localparam [3:0] CMD_LOAD_MODE    = 4'b0000;

// Mode register: CAS latency 2, burst length 1, sequential, single writes.
localparam [10:0] MODE = 11'b0_1_00_010_0_000;

reg  [3:0] cmd = CMD_INHIBIT;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

reg  [31:0] dq_out = 32'd0;
reg         dq_oe  = 1'b0;
assign SDRAM_DQ = dq_oe ? dq_out : 32'hZZZZZZZZ;

// The slot clock: 0..7 inside the video slot (phases 1..8) and inside
// the CPU slot (phases 9..15, 0).
wire       cpu_slot = (tphase >= 4'd9) || (tphase == 4'd0);
wire [2:0] sc = (tphase == 4'd0) ? 3'd7 :
                (tphase >= 4'd9) ? tphase[2:0] + 3'd7 : tphase[2:0] - 3'd1;

//------------------------------------------------------------------------
// Power-up
//------------------------------------------------------------------------
reg  [15:0] settle   = 16'd0;
reg  [4:0]  istep    = 5'd0;      // 0 = done
reg         started  = 1'b0;
assign init = started && (istep == 5'd0);

//------------------------------------------------------------------------
// Refresh: 4096 rows in 64 ms is one every 15.6 us, 632 clocks; every
// 600 here, kept as a count of those due so a run of busy video slots
// catches up afterwards.
//------------------------------------------------------------------------
reg  [9:0] ref_cnt = 10'd0;
reg  [2:0] ref_due = 3'd0;

//------------------------------------------------------------------------
// The self-test: eight accesses through the CPU slot, one a T-state,
// advanced at phase 1 when the read data of the T-state before is in
// cpu_rdata whichever clock captured it.  Four words at the top of the
// main RAM's region (membus.v: words 3FFCh..3FFFh), all four lanes.
//------------------------------------------------------------------------
reg         bist_run  = 1'b0;
reg         bist_rd   = 1'b0;     // 0 the write pass, 1 the read pass
reg  [1:0]  bist_i    = 2'd0;
reg         bist_bad  = 1'b0;
wire        bist_req  = bist_run;
wire [20:0] bist_adr  = {7'd0, 12'h3FF, bist_i};
reg  [31:0] bist_pat;
always @(*) case (bist_i)
    2'd0: bist_pat = 32'h55AA_1234;
    2'd1: bist_pat = 32'hAA55_5678;
    2'd2: bist_pat = 32'h5A5A_9ABC;
    2'd3: bist_pat = 32'hA5A5_DEF0;
endcase

//------------------------------------------------------------------------
// The cycle in flight
//------------------------------------------------------------------------
reg         act      = 1'b0;
reg         act_we   = 1'b0;
reg         act_vid  = 1'b0;
reg  [20:0] act_adr  = 21'd0;
reg  [31:0] act_data = 32'd0;
reg  [3:0]  act_mask = 4'd0;

always @(posedge clk) begin
    cmd       <= CMD_NOP;
    dq_oe     <= 1'b0;
    vid_ack   <= 1'b0;
    cpu_ack   <= 1'b0;
    SDRAM_DQM <= 4'b1111;

    if (!lock) begin
        settle  <= 16'd0;
        istep   <= 5'd31;
        started <= 1'b0;
        cmd     <= CMD_INHIBIT;
        ref_due <= 3'd0;
        ref_cnt <= 10'd0;
        bist_run  <= 1'b0;  bist_rd  <= 1'b0; bist_i   <= 2'd0; bist_bad <= 1'b0;
        bist_done <= 1'b0;  bist_fail <= 1'b0; cap_late <= 1'b0;
    end else if (!started) begin
        if (&settle) begin started <= 1'b1; istep <= 5'd31; end
        else settle <= settle + 16'd1;
        SDRAM_A  <= 11'd0;
        SDRAM_BA <= 2'd0;
    end else if (istep != 5'd0) begin
        // one step a slot, on the slot's first clock
        if (sc == 3'd0 && !cpu_slot) begin
            istep <= istep - 5'd1;
            case (istep)
                5'd20: begin cmd <= CMD_PRECHARGE;    SDRAM_A <= 11'b100_0000_0000; end
                5'd16: cmd <= CMD_AUTO_REFRESH;
                5'd12: cmd <= CMD_AUTO_REFRESH;
                5'd8:  begin cmd <= CMD_LOAD_MODE;    SDRAM_A <= MODE; end
                default: ;
            endcase
        end
    end else begin
        //----------------------------------------------------------------
        // Running.
        //----------------------------------------------------------------
        if (!bist_done && !bist_run && tphase == 4'd1) bist_run <= 1'b1;
        if (bist_run && tphase == 4'd1) begin
            if (bist_rd && cpu_rdata != bist_pat) bist_bad <= 1'b1;
            bist_i <= bist_i + 2'd1;
            if (bist_i == 2'd3) begin
                if (!bist_rd)
                    bist_rd <= 1'b1;
                else begin
                    bist_rd <= 1'b0;
                    bist_bad <= 1'b0;
                    if (!(bist_bad || cpu_rdata != bist_pat)) begin
                        bist_run <= 1'b0; bist_done <= 1'b1;
                    end else if (!cap_late) begin
                        cap_late <= 1'b1;
                    end else begin
                        bist_run <= 1'b0; bist_done <= 1'b1;
                        bist_fail <= 1'b1; cap_late <= 1'b0;
                    end
                end
            end
        end

        if (ref_cnt == 10'd599) begin
            ref_cnt <= 10'd0;
            if (ref_due != 3'd7) ref_due <= ref_due + 3'd1;
        end else
            ref_cnt <= ref_cnt + 10'd1;

        case (sc)
        3'd0: begin
            act <= 1'b0;
            if (cpu_slot && cpu_req) begin
                act      <= 1'b1;
                act_we   <= cpu_we;
                act_vid  <= 1'b0;
                act_adr  <= cpu_adr;
                act_data <= cpu_wdata;
                act_mask <= cpu_wmask;
                cmd      <= CMD_ACTIVE;
                SDRAM_BA <= cpu_adr[20:19];
                SDRAM_A  <= cpu_adr[18:8];
            end else if (cpu_slot && bist_req) begin
                act      <= 1'b1;
                act_we   <= ~bist_rd;
                act_vid  <= 1'b0;
                act_adr  <= bist_adr;
                act_data <= bist_pat;
                act_mask <= 4'b1111;
                cmd      <= CMD_ACTIVE;
                SDRAM_BA <= bist_adr[20:19];
                SDRAM_A  <= bist_adr[18:8];
            end else if (!cpu_slot && vid_req) begin
                act      <= 1'b1;
                act_we   <= 1'b0;
                act_vid  <= 1'b1;
                act_adr  <= vid_adr;
                cmd      <= CMD_ACTIVE;
                SDRAM_BA <= vid_adr[20:19];
                SDRAM_A  <= vid_adr[18:8];
            end else if (!cpu_slot && ref_due != 3'd0) begin
                cmd     <= CMD_AUTO_REFRESH;
                ref_due <= ref_due - 3'd1;
            end
        end
        3'd1: if (act) begin
            // column with auto-precharge: A10 SET, written at its own
            // position (PK8000 Nano's lesson); the lanes by DQM
            SDRAM_A  <= {1'b1, 2'b00, act_adr[7:0]};
            SDRAM_BA <= act_adr[20:19];
            if (act_we) begin
                cmd       <= CMD_WRITE;
                dq_out    <= act_data;
                dq_oe     <= 1'b1;
                SDRAM_DQM <= ~act_mask;
            end else begin
                cmd       <= CMD_READ;
                SDRAM_DQM <= 4'b0000;
            end
        end
        3'd2: if (act && act_we) dq_oe <= 1'b1;
        3'd3: if (act && !act_we && !cap_late) begin
            if (act_vid) begin vid_rdata <= SDRAM_DQ; vid_ack <= 1'b1; end
            else         begin cpu_rdata <= SDRAM_DQ; cpu_ack <= 1'b1; end
        end
        3'd4: if (act && !act_we && cap_late) begin
            if (act_vid) begin vid_rdata <= SDRAM_DQ; vid_ack <= 1'b1; end
            else         begin cpu_rdata <= SDRAM_DQ; cpu_ack <= 1'b1; end
        end
        default: ;
        endcase
    end
end

endmodule
