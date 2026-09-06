`timescale 1ns / 1ps
//========================================================================
// memcheck.v - a shadow of F000h-FFFFh, and what the CPU is doing.
//
// PK8000 Nano's instrument for a board nobody can watch, kept as it is:
// every CPU write into the main RAM's top 4 KB is copied into a 4 K x 9
// BSRAM (the byte and a "written" bit); every read from there is
// compared with the copy when the byte comes back, and the first and
// the last mismatch are kept with the address, both values and the
// address of the last opcode fetch before them.  Beside that, counts:
// reads checked, writes shadowed, CPU resets, opcode fetches at 0000h
// (the ROM restarting) with the fetch before the last one, and the last
// write to the register page.  32 bytes on `dbg`, read by the MCU
// through sysctrl.v's CMD 7 and shown on the OSD's "Debug" page.  On the
// Корвет the top of the RAM is the ОПТС's stack and variables in every
// configuration that has RAM there, so a memory that lies shows up here
// first.
//
// Nothing here touches the machine.  The BSRAM is written on one clock
// and read on another (the strobes never coincide with a read's
// completion), the only kind of inferred RAM Gowin's place-and-route
// accepts (CLAUDE.md, PA2122).
//========================================================================
module memcheck (
    input             clk,

    // the main RAM's byte traffic, as top.v strobes it
    input             wr_stb,       // a CPU write to the main RAM
    input      [15:0] wr_adr,
    input      [7:0]  wr_data,
    input             rd_stb,       // a CPU read of the main RAM
    input      [15:0] rd_adr,
    input             rd_done,      // membus.v: the byte is in rd_data
    input      [7:0]  rd_data,

    // the CPU
    input             cpu_rst,
    input             cyc_m1,       // with rd_stb: an opcode fetch
    input             reg_wr,       // a write to the register page
    input      [7:0]  reg_adr,
    input      [7:0]  reg_data,

    // the memory's own verdicts, for the flags byte
    input             por_done,
    input             init,
    input             bist_done,
    input             bist_fail,
    input             cap_late,

    output    [255:0] dbg
);

wire wr_hit = wr_stb && (wr_adr[15:12] == 4'hF);
wire rd_hit = rd_stb && (rd_adr[15:12] == 4'hF);

reg  [8:0]  shadow [0:4095];
reg  [8:0]  shadow_q = 9'd0;
reg         chk_pend = 1'b0;
reg  [11:0] chk_adr  = 12'd0;

always @(posedge clk)
    if (wr_hit) shadow[wr_adr[11:0]] <= {1'b1, wr_data};

always @(posedge clk)
    if (rd_hit) shadow_q <= shadow[rd_adr[11:0]];

reg  [7:0]  err_cnt   = 8'd0;
reg  [15:0] first_adr = 16'd0, last_adr = 16'd0;
reg  [7:0]  first_exp = 8'd0,  first_got = 8'd0, last_exp = 8'd0, last_got = 8'd0;
reg  [15:0] first_pc  = 16'd0, last_pc  = 16'd0;
reg  [15:0] chk_cnt   = 16'd0, wr_cnt   = 16'd0;
reg  [7:0]  rst_cnt   = 8'd0,  pc0_cnt  = 8'd0;
reg  [15:0] pc_last   = 16'd0, pc_prev  = 16'd0, pc_prev0 = 16'd0;
reg  [7:0]  m1_cnt    = 8'd0;
reg  [7:0]  out_port  = 8'd0,  out_data = 8'd0;
reg         cpu_rst_d = 1'b0;

always @(posedge clk) begin
    cpu_rst_d <= cpu_rst;
    if (wr_hit && wr_cnt != 16'hFFFF) wr_cnt <= wr_cnt + 16'd1;

    if (rd_hit) begin
        chk_pend <= 1'b1;
        chk_adr  <= rd_adr[11:0];
    end
    if (chk_pend && rd_done) begin
        chk_pend <= 1'b0;
        if (shadow_q[8]) begin
            if (chk_cnt != 16'hFFFF) chk_cnt <= chk_cnt + 16'd1;
            if (shadow_q[7:0] != rd_data) begin
                if (err_cnt != 8'hFF) err_cnt <= err_cnt + 8'd1;
                if (err_cnt == 8'd0) begin
                    first_adr <= {4'hF, chk_adr};
                    first_exp <= shadow_q[7:0];
                    first_got <= rd_data;
                    first_pc  <= pc_last;
                end
                last_adr <= {4'hF, chk_adr};
                last_exp <= shadow_q[7:0];
                last_got <= rd_data;
                last_pc  <= pc_last;
            end
        end
    end

    if (rd_stb && cyc_m1 && !cpu_rst) begin
        m1_cnt  <= m1_cnt + 8'd1;
        pc_prev <= pc_last;
        pc_last <= rd_adr;
        if (rd_adr == 16'h0000) begin
            if (pc0_cnt != 8'hFF) pc0_cnt <= pc0_cnt + 8'd1;
            pc_prev0 <= pc_last;
        end
    end

    if (cpu_rst && !cpu_rst_d && rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 8'd1;

    if (reg_wr) begin
        out_port <= reg_adr;
        out_data <= reg_data;
    end
end

assign dbg = {
    8'd0, 8'd0, 8'd0, 8'd0,                      // 31..28
    m1_cnt,                                      // 27
    pc_last,                                     // 26,25
    out_data, out_port,                          // 24,23
    wr_cnt,                                      // 22,21
    chk_cnt,                                     // 20,19
    pc_prev0,                                    // 18,17
    pc0_cnt, rst_cnt,                            // 16,15
    last_pc,                                     // 14,13
    last_got, last_exp,                          // 12,11
    last_adr,                                    // 10,9
    first_pc,                                    // 8,7
    first_got, first_exp,                        // 6,5
    first_adr,                                   // 4,3
    err_cnt,                                     // 2
    8'd0,                                        // 1 (spare)
    {por_done, init, cpu_rst, bist_done, bist_fail, cap_late, 2'b00}   // 0
};

endmodule
