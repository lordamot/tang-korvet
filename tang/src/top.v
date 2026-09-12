`timescale 1ns / 1ps
//========================================================================
// top.v - Korvet Nano: the ПК8020 "Корвет" on a Tang Nano 20K, with a
// BL616 (M0S Dock) beside it for USB, the SD card and the OSD.
//
// One clock.  sys_pll makes 40.5 MHz out of the board's 27, and every
// flop in the design runs on it: the CPU's T-state is sixteen of them
// (tphase 0..15, counted here), the machine's pixel is four, the HDMI
// pixel is one, and the SDRAM takes the phase-shifted copy on its pad.
// The only other clocks are the HDMI serial clock, made from this one
// inside hdmi_serdes.v, and the MCU's SPI clock, which mcu_spi.v takes
// through a handshake.  korvet.sdc names the two and the tool has the
// rest.  PK8000 Nano's method (../tang-pk8000), with this machine in it.
//
// The machine (tang/src/korvet/):
//   cpu8080.v  the КР580ВМ80А (vm80a) with the 8228's status decode, the
//              ВН59's three-byte acknowledge and the device-page wait
//   cpuz80.v   the Z80 accelerator (tv80) in its place, 2.5 or 5 MHz
//   memmap.v   the PLM D31: what each address is in each configuration
//   membus.v   the SDRAM's CPU port: the RAM, a loaded ROM, the graphics
//              RAM's three planes in one word, the write queue
//   sdram.v    the SDRAM: a fixed slot for the CPU and one for the video
//              in every T-state
//   opts_rom.v the built-in ОПТС 2.0 (24 KB) in BSRAM; romload.v puts a
//              ROM from the card into the SDRAM instead
//   txtram.v   the text RAM with its attribute bit and the flip-flop
//   video.v    the display: text, three planes and the colour table into
//              a line buffer, read out as 1024x512 at 48.9 Hz
//   ports.v    the register page (7Fh, BFh, FBh) and the keyboard
//   devices.v  the device page: ВИ53, three ВВ55, two ВВ51, ВН59, and
//              the floppy's registers
//   fdc.v      the ВГ93 (wd1793.sv) with four .kdi images on the card
//   extrom.v   the Korvet-EXTROM controller's connector side; the
//              firmware is the controller
//   ay.v       the AY module on the same connector (ym2149.sv)
//   mouse.v    a Microsoft serial mouse on the ВВ51 from the USB one
//   sd_arbiter.v  one owner at a time on sd_card.v's sector interface
//   poke.v, memcheck.v  the MCU's bytes into the RAM; the debug window
// and around it MiSTeryNano's MCU link (src/mister/), UKNC Nano's HDMI
// encoder with audio (src/hdmi/) and an I2S output (i2s_tx.v).
//========================================================================
module top(
    input         clk27,
    // buts[0] is S1 and forces a reset; buts[1] is S2, read nowhere.
    input  [ 1:0] buts,
    output [ 5:0] leds,

    output        uart_tx,        // the USB-C serial: idle
    input         uart_rx,

    output        sdclk,
    inout         sdcmd,          // mosi
    inout         sddat0,         // miso
    inout         sddat1,         // not used
    inout         sddat2,         // not used
    inout         sddat3,         // cs

    output        O_tmds_clk_p,
    output        O_tmds_clk_n,
    output  [2:0] O_tmds_data_p,
    output  [2:0] O_tmds_data_n,

    // I2S to the dock's DAC
    output        HP_BCK,
    output        HP_WS,
    output        HP_DIN,
    output        PA_EN,

    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,
    output        O_sdram_cas_n,
    output        O_sdram_ras_n,
    output        O_sdram_wen_n,
    output [ 3:0] O_sdram_dqm,
    output [10:0] O_sdram_addr,
    output [ 1:0] O_sdram_ba,
    inout  [31:0] IO_sdram_dq,

    // the MCU link, stock MiSTeryNano wiring: an external BL616 / M0S
    // Dock on 42/41/56/54/51 - 0 miso, 1 mosi, 2 csn, 3 sclk, 4 irqn
    inout  [ 4:0] m0s,

    // RECONFIG_N, pin 9: driven low by SYS command 9 to reload the FPGA
    output        reconfig_n
);

assign O_sdram_cke = 1'b1;
assign PA_EN       = 1'b1;
assign uart_tx     = 1'b1;

//------------------------------------------------------------------------
// Clock
//------------------------------------------------------------------------
wire clk;          // 40.5 MHz, everything
wire locked;

sys_pll pll (
    .clkin  (clk27      ),
    .clkout (clk        ),
    .clkoutp(O_sdram_clk),
    .lock   (locked     )
);

//------------------------------------------------------------------------
// Resets.  `init` is the SDRAM's word that the memory exists; the
// MiSTeryNano side then waits 2^23 clocks (207 ms) as upstream does, for
// the MCU to come up.  The machine itself is reset by the OSD's 'R'
// (the MCU sends 3 at power-up and 0 when it has sent its settings), by
// S1, until the memory is there, and while a ROM is being loaded.
//------------------------------------------------------------------------
wire init;
reg  [23:0] count_rst = 24'd0;
wire        n_all_rst = init & ~buts[0];
wire        por_done  = count_rst[23];
wire        mist_rst  = ~por_done;

always @(posedge clk or negedge n_all_rst)
    count_rst <= !n_all_rst ? 24'd0 : count_rst + {23'd0, !count_rst[23]};

wire [1:0] system_reset, system_volume, system_cpu;
wire       system_beeper, system_fdc, system_extrom, system_ay, system_mouse, system_gzu48;
wire [3:0] system_wprot;
wire       rd_loading;

//------------------------------------------------------------------------
// The machine's raster and the T-state phase, one counter pair.  The
// line is 2624 clocks (164 T-states), the frame 312 lines.  They run
// from PLL lock: the SDRAM's initialisation steps are taken in the video
// slot of the timetable, which is a phase of this counter.
//------------------------------------------------------------------------
reg  [11:0] hcnt   = 12'd0;
reg  [8:0]  vcnt   = 9'd0;
reg  [3:0]  tphase = 4'd0;

always @(posedge clk) begin
    if (!locked) begin
        hcnt <= 12'd0; vcnt <= 9'd0; tphase <= 4'd0;
    end else begin
        tphase <= tphase + 4'd1;
        if (hcnt == 12'd2623) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == 9'd311) ? 9'd0 : vcnt + 9'd1;
        end else
            hcnt <= hcnt + 12'd1;
    end
end

// the clock enables: the CPU rate (the floppy chip) and the timer's 2 MHz
wire ce_cpu = (tphase == 4'd0);
reg  [4:0] div20 = 5'd0;
always @(posedge clk) div20 <= (div20 == 5'd19) ? 5'd0 : div20 + 5'd1;
wire ce_2m = (div20 == 5'd0);

// vm80a takes its reset through two phase-registered stages; hold it
// well past that: 16 T-states after the request goes away.
reg  [7:0] cpu_rst_cnt = 8'hFF;
wire       cpu_rst_req = mist_rst | system_reset[0] | ~init | rd_loading;
always @(posedge clk) begin
    if (cpu_rst_req) cpu_rst_cnt <= 8'd192;
    else if (cpu_rst_cnt != 8'd0 && tphase == 4'd15) cpu_rst_cnt <= cpu_rst_cnt - 8'd1;
end
wire cpu_rst = (cpu_rst_cnt != 8'd0);

//------------------------------------------------------------------------
// The CPU: one of two, the other held in reset, one bus.
//------------------------------------------------------------------------
wire        use_z80 = (system_cpu != 2'd0);
wire [15:0] a_adr, a_now, z_adr, z_now;
wire [7:0]  a_dout, a_d_now, z_dout, z_d_now;
wire        a_m1, a_mem_rd, a_io_rd, a_mem_wr, a_io_wr, a_inta, a_inte;
wire        z_m1, z_mem_rd, z_io_rd, z_mem_wr, z_io_wr, z_inta, z_inte;
wire [1:0]  a_inta_n, z_inta_n;
wire [7:0]  cpu_din, inta_data;
wire        int_req, dev_hit, mem_wait;

cpu8080 cpu (
    .clk(clk), .reset(cpu_rst | use_z80), .tphase(tphase),
    .adr(a_adr), .dout(a_dout), .din(cpu_din), .a_now(a_now), .d_now(a_d_now),
    .cyc_m1(a_m1), .mem_rd(a_mem_rd), .io_rd(a_io_rd), .mem_wr(a_mem_wr), .io_wr(a_io_wr),
    .inta_stb(a_inta), .inta_n(a_inta_n), .inta_data(inta_data),
    .int_req(int_req), .inte(a_inte), .dev_hit(dev_hit), .mem_wait(mem_wait),
    .dbg_opcode(), .dbg_sync()
);

cpuz80 zcpu (
    .clk(clk), .reset(cpu_rst | ~use_z80), .tphase(tphase), .turbo(system_cpu[1]),
    .adr(z_adr), .dout(z_dout), .din(cpu_din), .a_now(z_now), .d_now(z_d_now),
    .cyc_m1(z_m1), .mem_rd(z_mem_rd), .io_rd(z_io_rd), .mem_wr(z_mem_wr), .io_wr(z_io_wr),
    .inta_stb(z_inta), .inta_n(z_inta_n), .inta_data(inta_data),
    .int_req(int_req), .inte(z_inte), .dev_hit(dev_hit), .mem_wait(mem_wait),
    .dbg_opcode(), .dbg_m1()
);

wire [15:0] cpu_adr   = use_z80 ? z_adr   : a_adr;
wire [15:0] cpu_a_now = use_z80 ? z_now   : a_now;
wire [7:0]  cpu_d_now = use_z80 ? z_d_now : a_d_now;
wire        cpu_m1    = use_z80 ? z_m1    : a_m1;
// the fetch flag at the strobe itself, for memcheck.v and the testbench
wire        cpu_m1_now = use_z80 ? !zcpu.m1_n : cpu.st_m1;
wire        mem_rd    = use_z80 ? z_mem_rd : a_mem_rd;
wire        io_rd     = use_z80 ? z_io_rd  : a_io_rd;
wire        mem_wr    = use_z80 ? z_mem_wr : a_mem_wr;
wire        io_wr     = use_z80 ? z_io_wr  : a_io_wr;
wire        inta_stb  = use_z80 ? z_inta   : a_inta;
wire [1:0]  inta_n    = use_z80 ? z_inta_n : a_inta_n;
wire        cpu_inte  = use_z80 ? z_inte   : a_inte;

//------------------------------------------------------------------------
// The memory map: the PLM on the live address for the read strobe,
// on the latched address for the write.
//------------------------------------------------------------------------
wire [6:2] sysreg;
wire [7:0] ncreg;
wire [7:0] z_rd, z_wr;

memmap map_rd (.a(cpu_a_now[15:8]), .sr(sysreg), .rd(1'b1), .wr(1'b0), .z(z_rd));
memmap map_wr (.a(cpu_adr[15:8]),   .sr(sysreg), .rd(1'b0), .wr(1'b1), .z(z_wr));

wire rd_rom  = !z_rd[2] || !z_rd[3] || !z_rd[0];
wire rd_kbd  = !z_rd[1];
wire rd_dev  = !z_rd[4];
wire rd_ram  = (z_rd[7:6] == 2'b00);
wire rd_gzu  = (z_rd[7:6] == 2'b01);
wire rd_txt  = (z_rd[7:6] == 2'b10);

wire wr_dev  = !z_wr[4];
wire wr_reg  = !z_wr[5];
wire wr_ram  = (z_wr[7:6] == 2'b00);
wire wr_gzu  = (z_wr[7:6] == 2'b01);
wire wr_txt  = (z_wr[7:6] == 2'b10);

assign dev_hit = rd_dev;      // the same for a write: z[4] has no strobe term

// which source the read in flight answers from
localparam [2:0] SRC_NONE = 3'd0, SRC_MEM = 3'd1, SRC_ROM = 3'd2, SRC_KBD = 3'd3,
                 SRC_DEV = 3'd4, SRC_TXT = 3'd5;
reg  [2:0] rd_src = SRC_NONE;
reg        rd_is_gzu = 1'b0;
wire       rom_loaded;
always @(posedge clk) begin
    if (mem_rd) begin
        rd_is_gzu <= rd_gzu;
        if (rd_rom)       rd_src <= rom_loaded ? SRC_MEM : SRC_ROM;
        else if (rd_dev)  rd_src <= SRC_DEV;
        else if (rd_kbd)  rd_src <= SRC_KBD;
        else if (rd_txt)  rd_src <= SRC_TXT;
        else if (rd_ram || rd_gzu) rd_src <= SRC_MEM;
        else              rd_src <= SRC_NONE;
    end
    if (io_rd) rd_src <= SRC_NONE;
end

//------------------------------------------------------------------------
// The SDRAM through membus.v
//------------------------------------------------------------------------
wire [1:0]  rw_page  = system_gzu48 ? 2'd0 : vid_ctrl[7:6];
wire [20:0] rd_word  = rd_gzu ? {5'b00010, rw_page, cpu_a_now[13:0]} :
                       rd_rom ? {6'd0, 2'b10, cpu_a_now[14:2]} : {7'd0, cpu_a_now[15:2]};
wire [20:0] wr_word  = wr_gzu ? {5'b00010, rw_page, cpu_adr[13:0]} : {7'd0, cpu_adr[15:2]};
wire        mb_rd    = mem_rd && (rd_ram || rd_gzu || (rd_rom && rom_loaded));
wire        mb_wr    = mem_wr && (wr_ram || wr_gzu);
wire        rd_busy, rd_done, wr_wait;
wire [7:0]  mb_rdata;
wire [23:0] mb_planes;
wire        poke_req, poke_room;
wire [15:0] poke_a;
wire [7:0]  poke_d;
wire        ld_req, ld_ack;
wire [14:0] ld_adr;
wire [7:0]  ld_data;
wire        sd_req, sd_we, sd_ack;
wire [20:0] sd_adr;
wire [31:0] sd_wdata, sd_rdata;
wire [3:0]  sd_wmask;

membus mb (
    .clk(clk), .reset(mist_rst), .tphase(tphase),
    .rd(mb_rd), .rd_word(rd_word), .rd_lane(cpu_a_now[1:0]), .rd_gzu(rd_gzu),
    .rd_busy(rd_busy), .rd_done(rd_done), .rd_data(mb_rdata), .rd_planes(mb_planes),
    .wr(mb_wr), .wr_word(wr_word), .wr_lane(cpu_adr[1:0]), .wr_data(cpu_d_now),
    .wr_gzu(wr_gzu), .wr_ncreg(ncreg), .wr_wait(wr_wait),
    .poke_stb(poke_req), .poke_adr(poke_a), .poke_data(poke_d), .poke_room(poke_room),
    .hold(rd_loading), .ld_req(ld_req), .ld_adr(ld_adr), .ld_data(ld_data), .ld_ack(ld_ack),
    .sd_req(sd_req), .sd_we(sd_we), .sd_adr(sd_adr), .sd_wdata(sd_wdata), .sd_wmask(sd_wmask),
    .sd_rdata(sd_rdata), .sd_ack(sd_ack)
);
assign mem_wait = rd_busy | wr_wait;

wire        vid_req, vid_ack;
wire [20:0] vid_adr;
wire [31:0] vid_rdata;
wire        bist_done, bist_fail, cap_late;

sdram mem (
    .clk(clk), .lock(locked), .init(init), .tphase(tphase),
    .cpu_req(sd_req), .cpu_we(sd_we), .cpu_adr(sd_adr), .cpu_wdata(sd_wdata), .cpu_wmask(sd_wmask),
    .cpu_rdata(sd_rdata), .cpu_ack(sd_ack),
    .vid_req(vid_req), .vid_adr(vid_adr), .vid_rdata(vid_rdata), .vid_ack(vid_ack),
    .bist_done(bist_done), .bist_fail(bist_fail), .cap_late(cap_late),
    .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba), .SDRAM_DQ(IO_sdram_dq),
    .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n),
    .SDRAM_nWE(O_sdram_wen_n), .SDRAM_DQM(O_sdram_dqm)
);

// the graphics RAM's read: what the two PLMs D88/D101 make of the three
// planes and the colour register (техописание §7, Emu80's readByte)
wire [7:0] gz_p0 = mb_planes[7:0], gz_p1 = mb_planes[15:8], gz_p2 = mb_planes[23:16];
wire [7:0] gzu_rd = ncreg[7] ?
    ((ncreg[4] ? ~gz_p0 : gz_p0) | (ncreg[5] ? ~gz_p1 : gz_p1) | (ncreg[6] ? ~gz_p2 : gz_p2)) :
    ((ncreg[4] ? gz_p0 : 8'd0) | (ncreg[5] ? gz_p1 : 8'd0) | (ncreg[6] ? gz_p2 : 8'd0));

// the built-in ROM: a registered pROM addressed by the latched address
wire [15:0] rom_word;
opts_rom rom (.dout(rom_word), .clk(clk), .ce(1'b1), .reset(1'b0), .ad(cpu_adr[14:1]));
wire [7:0]  rom_rdata = cpu_adr[0] ? rom_word[15:8] : rom_word[7:0];

wire [7:0] kbd_data, dev_rdata, txt_rdata;
assign cpu_din = (rd_src == SRC_MEM) ? (rd_is_gzu ? gzu_rd : mb_rdata) :
                 (rd_src == SRC_ROM) ? rom_rdata :
                 (rd_src == SRC_KBD) ? kbd_data  :
                 (rd_src == SRC_DEV) ? dev_rdata :
                 (rd_src == SRC_TXT) ? txt_rdata : 8'hFF;

//------------------------------------------------------------------------
// The register page and the keyboard
//------------------------------------------------------------------------
wire       lut_we;
wire [3:0] lut_adr, lut_data;
wire [7:0] kbd_byte;
wire       kbd_stb;

ports regs (
    .clk(clk), .reset(cpu_rst),
    .reg_wr(mem_wr && wr_reg), .a(cpu_adr[7:0]), .wdata(cpu_d_now),
    .sysreg(sysreg), .ncreg(ncreg), .lut_we(lut_we), .lut_adr(lut_adr), .lut_data(lut_data),
    .kbd_rd(mem_rd && rd_kbd), .kbd_a(cpu_a_now[8:0]), .kbd_data(kbd_data),
    .kbd_byte(kbd_byte), .kbd_stb(kbd_stb)
);

//------------------------------------------------------------------------
// The text RAM and the display
//------------------------------------------------------------------------
wire [7:0] vid_ctrl, fdd_ctrl, ppi2_c;
wire       attr_ff;
wire [9:0] txt_vadr;
wire [7:0] txt_vsym;
wire       txt_vattr;

txtram txt (
    .clk(clk),
    .cpu_adr(mem_wr ? cpu_adr[9:0] : cpu_a_now[9:0]),
    .cpu_rd(mem_rd && rd_txt), .cpu_wr(mem_wr && wr_txt), .cpu_wdata(cpu_d_now),
    .attr_mode(vid_ctrl[5:4]), .cpu_rdata(txt_rdata), .attr_ff(attr_ff),
    .vid_adr(txt_vadr), .vid_sym(txt_vsym), .vid_attr(txt_vattr)
);

wire [12:0] font_adr;
wire [15:0] font_word;
reg         font_lo = 1'b0;
always @(posedge clk) font_lo <= font_adr[0];
font_rom font (.dout(font_word), .clk(clk), .ce(1'b1), .reset(1'b0), .ad(font_adr[12:1]));
wire [7:0]  font_data = font_lo ? font_word[15:8] : font_word[7:0];

wire        hsync, vsync, visible, vbl, hbl_tick;
wire [7:0]  red, green, blue;

video vid (
    .clk(clk), .hcnt(hcnt), .vcnt(vcnt), .tphase(tphase),
    .disp_page(vid_ctrl[1:0]), .font_sel(vid_ctrl[2]), .wide(vid_ctrl[3]), .gzu48(system_gzu48),
    .lut_we(lut_we), .lut_adr(lut_adr), .lut_data(lut_data),
    .txt_adr(txt_vadr), .txt_sym(txt_vsym), .txt_attr(txt_vattr),
    .font_adr(font_adr), .font_data(font_data),
    .vid_req(vid_req), .vid_adr(vid_adr), .vid_rdata(vid_rdata), .vid_ack(vid_ack),
    .hs(hsync), .vs(vsync), .de(visible), .r(red), .g(green), .b(blue),
    .vbl(vbl), .hbl_tick(hbl_tick)
);

//------------------------------------------------------------------------
// The device page
//------------------------------------------------------------------------
wire        snd_out, fdc_rd, fdc_wr, fdc_motor_irq;
wire [7:0]  fdc_rdata, printer_data;
wire [7:0]  p3a_out, p3a_in, p3b_out, p3c_out;
wire        p3b_wr, p3_mode2, p3_in_stb, p3_ack, p3_ibf, p3_obf_n;
wire [7:0]  p3_in_data;
wire        rxd1, txd1, rts1;
wire        control = ppi2_c[7];

devices dev (
    .clk(clk), .reset(cpu_rst), .ce_cpu(ce_cpu),
    .rd_stb(mem_rd && rd_dev), .wr_stb(mem_wr && wr_dev),
    .a(mem_wr ? cpu_adr[5:0] : cpu_a_now[5:0]), .wdata(cpu_d_now), .rdata(dev_rdata),
    .ce_2m(ce_2m), .hbl_tick(hbl_tick), .snd_out(snd_out),
    .tape_in(1'b0), .vbl(vbl), .attr_ff(attr_ff), .fdd_ctrl(fdd_ctrl), .vid_ctrl(vid_ctrl),
    .printer_data(printer_data), .ppi2_c(ppi2_c),
    .p3a_out(p3a_out), .p3a_in(p3a_in), .p3b_out(p3b_out), .p3b_wr(p3b_wr), .p3c_out(p3c_out),
    .p3_mode2(p3_mode2), .p3_in_stb(p3_in_stb), .p3_in_data(p3_in_data), .p3_ack(p3_ack),
    .p3_ibf(p3_ibf), .p3_obf_n(p3_obf_n),
    .rxd1(rxd1), .txd1(txd1), .rts1(rts1), .dsr1(system_mouse),
    .fdc_rd(fdc_rd), .fdc_wr(fdc_wr), .fdc_rdata(fdc_rdata), .fdc_motor_irq(fdc_motor_irq),
    .irq0_ext(system_extrom && control),
    .int_out(int_req), .inta_stb(inta_stb), .inta_n(inta_n), .inta_data(inta_data)
);

//------------------------------------------------------------------------
// The MCU link (MiSTeryNano): SPI in, four targets out.
//------------------------------------------------------------------------
wire        mcu_sys_strobe, mcu_hid_strobe, mcu_osd_strobe, mcu_sdc_strobe;
wire        mcu_start;
wire  [7:0] mcu_sys_din, mcu_hid_din, mcu_sdc_din;
wire  [7:0] mcu_osd_din = 8'h55;
wire  [7:0] mcu_dout;
wire        hid_int, sdc_int, xr_irq;
wire  [7:0] int_ack;

wire        spi_io_dout;
wire        int_out_n;

assign m0s[4:0] = { int_out_n, 3'bzzz, spi_io_dout };

wire spi_io_din = m0s[1];
wire spi_io_ss  = m0s[2];
wire spi_io_clk = m0s[3];

mcu_spi msp1 (
    .clk(clk), .reset(mist_rst),
    .spi_io_ss(spi_io_ss), .spi_io_clk(spi_io_clk), .spi_io_din(spi_io_din), .spi_io_dout(spi_io_dout),
    .mcu_sys_strobe(mcu_sys_strobe), .mcu_hid_strobe(mcu_hid_strobe),
    .mcu_osd_strobe(mcu_osd_strobe), .mcu_sdc_strobe(mcu_sdc_strobe),
    .mcu_start(mcu_start),
    .mcu_sys_din(mcu_sys_din), .mcu_hid_din(mcu_hid_din), .mcu_osd_din(mcu_osd_din), .mcu_sdc_din(mcu_sdc_din),
    .mcu_dout(mcu_dout)
);

wire        poke_stb;
wire [15:0] poke_adr;
wire [7:0]  poke_data;
wire        xr_rd, xr_wr, xr_flush, xr_rom_wr;
wire [7:0]  xr_rdata, xr_wdata, xr_rom_adr, xr_rx_count, xr_tx_free;
wire        xr_ctrl_fell;
wire [255:0] dbg_bus;

wire sys_reconfig;   // SYS command 9: reload the FPGA (see the MultiBoot block below)
sysctrl sctl1 (
    .clk(clk), .reset(mist_rst),
    .data_in_strobe(mcu_sys_strobe), .data_in_start(mcu_start), .data_in(mcu_dout), .data_out(mcu_sys_din),
    .int_out_n(int_out_n),
    .int_in({3'b000, xr_irq, sdc_int, 1'b0, hid_int, 1'b0}),
    .int_ack(int_ack),
    .buttons(2'b00), .leds(), .color(),
    .system_reset(system_reset), .system_volume(system_volume), .system_beeper(system_beeper),
    .system_cpu(system_cpu), .system_fdc(system_fdc), .system_extrom(system_extrom),
    .system_ay(system_ay), .system_mouse(system_mouse), .system_gzu48(system_gzu48),
    .system_wprot(system_wprot),
    .poke_stb(poke_stb), .poke_adr(poke_adr), .poke_data(poke_data),
    .dbg(dbg_bus),
    .xr_rd(xr_rd), .xr_rdata(xr_rdata), .xr_wr(xr_wr), .xr_wdata(xr_wdata), .xr_flush(xr_flush),
    .xr_rom_wr(xr_rom_wr), .xr_rom_adr(xr_rom_adr),
    .xr_rx_count(xr_rx_count), .xr_tx_free(xr_tx_free),
    .xr_flags({4'd0, xr_ctrl_fell, control, p3_mode2, system_extrom}),
    .reconfig(sys_reconfig)
);

//------------------------------------------------------------------------
// MultiBoot (tang-ultima): the MCU's SYS command 9 (sysctrl.v) pulses
// RECONFIG_N - pin 9, a GPIO output here (-use_reconfign_as_gpio) - and
// the FPGA reloads the image whose SPI flash address this bitstream's
// header names (Gowin MultiBoot, UG290 7.5.4; gowin_tcl.py's
// --multiboot-addr).  A standalone build names 0, which is itself.  The
// pin must read high from configuration on, so the counter starts at 0
// and the pin is low only while it counts down - 256 clocks, far over
// the 25 ns the FPGA asks for.  Nothing of the running design survives.
//------------------------------------------------------------------------
reg [7:0] reconfig_cnt = 8'd0;
always @(posedge clk) begin
    if(sys_reconfig)            reconfig_cnt <= 8'hff;
    else if(reconfig_cnt != 0)  reconfig_cnt <= reconfig_cnt - 8'd1;
end
assign reconfig_n = (reconfig_cnt == 8'd0);

poke pk (
    .clk(clk), .reset(mist_rst),
    .stb(poke_stb), .adr(poke_adr), .data(poke_data),
    .room(poke_room), .req(poke_req), .req_adr(poke_a), .req_data(poke_d), .pending()
);

memcheck mchk (
    .clk(clk),
    .wr_stb(mem_wr && wr_ram), .wr_adr(cpu_adr), .wr_data(cpu_d_now),
    .rd_stb(mem_rd && rd_ram), .rd_adr(cpu_a_now), .rd_done(rd_done), .rd_data(mb_rdata),
    .cpu_rst(cpu_rst), .cyc_m1(cpu_m1_now),
    .reg_wr(mem_wr && wr_reg), .reg_adr(cpu_adr[7:0]), .reg_data(cpu_d_now),
    .por_done(por_done), .init(init), .bist_done(bist_done), .bist_fail(bist_fail), .cap_late(cap_late),
    .dbg(dbg_bus)
);

wire [7:0] joystick0, joystick1;
wire       mouse_tgl;
wire [7:0] mouse_dx, mouse_dy;
wire [5:0] mouse_bits;

hid hd1 (
    .clk(clk), .reset(mist_rst),
    .data_in_strobe(mcu_hid_strobe), .data_in_start(mcu_start), .data_in(mcu_dout), .data_out(mcu_hid_din),
    .db9_port(6'd0), .irq(hid_int), .iack(int_ack[1]),
    .mouse(mouse_bits), .keyboard(kbd_byte), .keyboard_stb(kbd_stb),
    .joystick0(joystick0), .joystick1(joystick1),
    .mouse_rep_tgl(mouse_tgl), .mouse_rep_dx(mouse_dx), .mouse_rep_dy(mouse_dy)
);

// the serial mouse on the ВВ51 #1
mouse ms (
    .clk(clk), .reset(cpu_rst), .en(system_mouse),
    .rep_tgl(mouse_tgl), .rep_dx(mouse_dx), .rep_dy(mouse_dy), .btns(mouse_bits[5:4]),
    .rts(rts1), .rxd(rxd1)
);

//------------------------------------------------------------------------
// The side connector: the ExtROM controller and the AY module
//------------------------------------------------------------------------
wire [7:0] xr_pa_in, ay_pa_in;
wire       xr_active = system_extrom && control;

extrom xr (
    .clk(clk), .reset(mist_rst), .en(system_extrom),
    .control(control), .mode2(p3_mode2), .pb_out(p3b_out), .pc_out(p3c_out),
    .pa_in(xr_pa_in), .pa_out(p3a_out), .obf_n(p3_obf_n), .ack(p3_ack),
    .in_stb(p3_in_stb), .in_data(p3_in_data), .ibf(p3_ibf),
    .mcu_rd(xr_rd), .mcu_rdata(xr_rdata), .mcu_wr(xr_wr), .mcu_wdata(xr_wdata),
    .mcu_flush(xr_flush), .mcu_rom_wr(xr_rom_wr), .mcu_rom_adr(xr_rom_adr),
    .rx_count(xr_rx_count), .tx_free(xr_tx_free), .ctrl_fell(xr_ctrl_fell), .irq(xr_irq)
);

wire [9:0] ay_sample;
ay snd (
    .clk(clk), .reset(cpu_rst), .en(system_ay),
    .pa_out(p3a_out), .pa_in(ay_pa_in), .pb_out(p3b_out), .pb_wr(p3b_wr),
    .sample(ay_sample)
);

assign p3a_in = (xr_active && !p3_mode2) ? xr_pa_in : (system_ay ? ay_pa_in : 8'hFF);

//------------------------------------------------------------------------
// The SD card: the MCU's file system, and the five image slots through
// the arbiter - four floppies and the ROM.
//------------------------------------------------------------------------
wire [31:0] sd_img_size;
wire [ 4:0] sd_img_mounted;
wire [ 4:0] sd_rstart, sd_wstart;
wire [31:0] sd_rsector;
wire [ 7:0] sd_inbyte, sd_outbyte;
wire        sd_rbusy, sd_rdone, sd_outen;
wire [ 8:0] sd_outaddr;

sd_card #(.CLK_DIV(3'd1)) sd_card (
    .rstn(por_done), .clk(clk), .sdclk(sdclk), .sdcmd(sdcmd),
    .sddat({sddat3, sddat2, sddat1, sddat0}),
    .data_strobe(mcu_sdc_strobe), .data_start(mcu_start), .data_in(mcu_dout), .data_out(mcu_sdc_din),
    .image_size(sd_img_size), .image_mounted(sd_img_mounted),
    .irq(sdc_int), .iack(int_ack[3]),
    .rstart(sd_rstart), .wstart(sd_wstart), .rsector(sd_rsector),
    .rbusy(sd_rbusy), .rdone(sd_rdone), .inbyte(sd_inbyte),
    .outen(sd_outen), .outaddr(sd_outaddr), .outbyte(sd_outbyte)
);

reg [4:0] mounted = 5'd0;
integer   mi;
always @(posedge clk)
    for (mi = 0; mi < 5; mi = mi + 1)
        if (sd_img_mounted[mi]) mounted[mi] <= |sd_img_size;

wire [4:0]   c_rd, c_wr, c_ack, c_done, c_outen;
wire [159:0] c_sector;
wire [39:0]  c_inbyte;

sd_arbiter sdarb (
    .clk(clk), .reset(mist_rst),
    .c_rd(c_rd), .c_wr(c_wr), .c_sector(c_sector), .c_inbyte(c_inbyte),
    .c_ack(c_ack), .c_done(c_done), .c_outen(c_outen),
    .rstart(sd_rstart), .wstart(sd_wstart), .rsector(sd_rsector), .inbyte(sd_inbyte),
    .rbusy(sd_rbusy), .rdone(sd_rdone), .outen(sd_outen)
);

// slots 0..3: the floppies, one controller, the drive picks the slot
wire [1:0]  fdc_drive;
wire        fdc_sd_rd, fdc_sd_wr, fdc_busy;
wire [31:0] fdc_sector;
wire [7:0]  fdc_inbyte;
genvar gi;
generate for (gi = 0; gi < 4; gi = gi + 1) begin : fl
    assign c_rd[gi] = fdc_sd_rd && (fdc_drive == gi);
    assign c_wr[gi] = fdc_sd_wr && (fdc_drive == gi);
    assign c_sector[gi*32 +: 32] = fdc_sector;
    assign c_inbyte[gi*8 +: 8]   = fdc_inbyte;
end endgenerate
wire fdc_ack   = c_ack[{1'b0, fdc_drive}];
wire fdc_done  = c_done[{1'b0, fdc_drive}];
wire fdc_outen = c_outen[{1'b0, fdc_drive}];

fdc fd (
    .clk(clk), .reset(cpu_rst), .ce(ce_cpu), .en(system_fdc),
    .rd_stb(fdc_rd), .wr_stb(fdc_wr), .a(mem_wr ? cpu_adr[1:0] : cpu_a_now[1:0]),
    .wdata(cpu_d_now), .rdata(fdc_rdata),
    .ctrl(fdd_ctrl),
    .mounted(sd_img_mounted[3:0]), .image_size(sd_img_size), .present(mounted[3:0]), .wprot(system_wprot),
    .drive(fdc_drive), .sd_rd(fdc_sd_rd), .sd_wr(fdc_sd_wr), .sd_sector(fdc_sector),
    .sd_ack(fdc_ack), .sd_done(fdc_done), .outen(fdc_outen), .outaddr(sd_outaddr), .outbyte(sd_outbyte),
    .inbyte(fdc_inbyte), .busy(fdc_busy), .motor_irq(fdc_motor_irq)
);

// slot 4: the ROM, copied into the SDRAM at mount
wire        rl_rd;
wire [31:0] rl_sector;
assign c_rd[4] = rl_rd;
assign c_wr[4] = 1'b0;
assign c_sector[159:128] = rl_sector;
assign c_inbyte[39:32]   = 8'h00;

romload rl (
    .clk(clk), .reset(mist_rst),
    .mounted(sd_img_mounted[4]), .image_size(sd_img_size),
    .sd_rd(rl_rd), .sd_sector(rl_sector), .sd_ack(c_ack[4]), .sd_done(c_done[4]),
    .outen(c_outen[4]), .outaddr(sd_outaddr), .outbyte(sd_outbyte),
    .loading(rd_loading), .ld_req(ld_req), .ld_adr(ld_adr), .ld_data(ld_data), .ld_ack(ld_ack),
    .loaded(rom_loaded), .size()
);

//------------------------------------------------------------------------
// The OSD over the picture, then the encoder.
//------------------------------------------------------------------------
wire [5:0] r_out, g_out, b_out;

osd_u8g2 osd1 (
    .clk(clk), .pclk(clk), .reset(mist_rst),
    .data_in_strobe(mcu_osd_strobe), .data_in_start(mcu_start), .data_in(mcu_dout),
    .hs(hsync), .vs(vsync),
    .r_in(red[7:2]), .g_in(green[7:2]), .b_in(blue[7:2]),
    .r_out(r_out), .g_out(g_out), .b_out(b_out)
);

reg        I_rgb_vs = 1'b0, I_rgb_hs = 1'b0, I_rgb_de = 1'b0;
reg  [7:0] I_rgb_r = 8'd0, I_rgb_g = 8'd0, I_rgb_b = 8'd0;

always @(posedge clk) begin
    I_rgb_vs <= vsync;
    I_rgb_hs <= hsync;
    I_rgb_de <= visible;
    I_rgb_r  <= {r_out, 2'd0};
    I_rgb_g  <= {g_out, 2'd0};
    I_rgb_b  <= {b_out, 2'd0};
end

wire [9:0]  tmds_ch0, tmds_ch1, tmds_ch2;
wire [15:0] audio_l, audio_r;

hdmi_tx hdmi1 (
    .I_rst_n(1'b1), .I_rgb_clk(clk),
    .I_rgb_vs(I_rgb_vs), .I_rgb_hs(I_rgb_hs), .I_rgb_de(I_rgb_de),
    .I_rgb_r(I_rgb_r), .I_rgb_g(I_rgb_g), .I_rgb_b(I_rgb_b),
    .I_audio_l(audio_l), .I_audio_r(audio_r),
    .O_tmds_ch0(tmds_ch0), .O_tmds_ch1(tmds_ch1), .O_tmds_ch2(tmds_ch2),
    .O_audio_ovf(), .O_audio_dropc(), .O_audio_pktc()
);

hdmi_serdes hdmi_ser (
    .clk_pixel(clk), .ref_locked(locked),
    .tmds_ch0(tmds_ch0), .tmds_ch1(tmds_ch1), .tmds_ch2(tmds_ch2),
    .O_tmds_clk_p(O_tmds_clk_p), .O_tmds_clk_n(O_tmds_clk_n),
    .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n)
);

//------------------------------------------------------------------------
// Sound.  The piezo is the timer's counter 0 gated by the ВВ55 #2's port
// C bit 3; the tape output (bits 1:0) is a two-bit DAC some software
// plays through; the AY module's three channels.  One unipolar sum -
// the beeper at a quarter of full scale, the tape output at an
// eighth, the AY at up to 12240 - and the OSD's volume divides it down.
//------------------------------------------------------------------------
wire        beeper = snd_out & ppi2_c[3];
wire [1:0]  tape_o = ppi2_c[1:0];
wire [15:0] mix = {2'd0, beeper & system_beeper, 13'd0}
                + {3'd0, tape_o[0] & ~tape_o[1], 12'd0}
                + {2'd0, ay_sample, 4'd0};

reg [15:0] volume = 16'd0;
always @(posedge clk)
    case (system_volume)
        2'b00: volume <= 16'd0;
        2'b01: volume <= mix >> 2;
        2'b10: volume <= mix >> 1;
        2'b11: volume <= mix;
    endcase

assign audio_l = volume;
assign audio_r = volume;

i2s_tx i2s (
    .clk(clk), .reset(mist_rst),
    .sample_l(volume), .sample_r(volume),
    .bck(HP_BCK), .ws(HP_WS), .din(HP_DIN)
);

//------------------------------------------------------------------------
// LEDs, active low on the board: lit is the signal true.
//------------------------------------------------------------------------
assign leds[0] = ~por_done;
assign leds[1] = ~beeper;
assign leds[2] = ~(xr_active | cap_late);
assign leds[3] = ~(fdc_busy | sd_rbusy | bist_fail);
assign leds[4] = ~cpu_rst;
assign leds[5] = ~init;

endmodule
