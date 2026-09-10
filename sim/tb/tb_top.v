//========================================================================
// Top-level testbench: the whole machine, with the SDRAM modelled and a
// minimal stand-in for the BL616 - including the ExtROM controller's
// brain, when asked for.
//========================================================================
// Plusargs:
//   +VCD          dump sim/out/tb_top.vcd (large)
//   +VIDEO_PPM    write each decoded frame as a .ppm
//   +RUN_MS=<n>   how long to run, in simulated milliseconds (default 40)
//   +NOFASTBOOT   do not shortcut the 207 ms power-on reset counter
//   +CPUTRACE     every opcode fetch: address and opcode
//   +IOTRACE      every access to the device and register pages
//   +KBDTRACE     every read of the keyboard page while tracing, and every key from the MCU
//   +ZTRACE       the Z80 wrapper's bus at every enable and every phase 9
//   +TRACE_INT=<n> trace (as above) from the n-th interrupt taken, 1 ms, then stop
//   +MEMTRACE     every request on the SDRAM's CPU port
//   +TRACE_MS=<n> hold the traces off until n ms
//   +SPITRACE     every byte the MCU stand-in gets into sysctrl
//   +PPM_MAX=<n>  cap how many .ppm frames are written (default 4)
//   +PPM_EVERY=<n>  write every n-th frame only (default 1)
//   +PPM_FROM=<n> skip the frames before n ms
//   +NOMEMCHECK   turn off the read-after-write check on the SDRAM port
//   +HDMIDBG      print every data island packet the decoder sees
//   +CPU=<n>      the OSD's CPU switch: 0 ВМ80 (default), 1 Z80, 2 Z80 5 MHz
//   +NOFDC        the floppy controller off ('f' 0)
//   +AY           the AY module on ('y' 1)
//   +GZU48        one graphics page ('m' 1)
//   +TYPE_STR=<text>  type the text ('_' for a space) and Enter at +TYPE_MS=<n> (default 2500)
//   +GZUPAT=<ms>      at n ms a ruler into the graphics RAM: plane 0 edges of every tile, tiles 0,8,.. solid in planes 1-2
//   +KDIA= +KDIB= +KDIC= +KDID= +OPTS=<file>   images (sim/stubs/sd_card_sim.v)
//   +SDFAST       the card answers in microseconds, not a millisecond
//   +EXTROM       the ExtROM controller on ('x' 1), with the stand-in
//                 below as its brain: +STAGE1=<file> (default
//                 tang/rom/stage1.rom), +STAGE2=<file>, +XA= +XB= +XC=
//                 +XD=<kdi> the images it serves, +XTRACE its commands
//   +TEXTDUMP     print the text RAM as a screen at the end
//   +RAMDUMP      write the SDRAM's words to sim/out/ram.hex at the end
//
// Every delay in milliseconds is `ms * 64'd1000000`: a 32-bit product
// wraps past 4294 ms.
//
// The SPI master, the HDMI decoder and the .ppm writer are UKNC Nano's
// and PK8000 Nano's, the checks around them are this machine's.
//========================================================================
`timescale 1ns / 1ps

module tb_top;

    //--------------------------------------------------------------------
    // Clock and board inputs
    //--------------------------------------------------------------------
    reg clk27 = 1'b0;
    always #18.518 clk27 = ~clk27;      // 27 MHz

    reg  [1:0] buts = 2'b00;
    wire [5:0] leds;

    wire uart_tx;
    reg  uart_rx = 1'b1;

    wire sdclk;
    wire sdcmd, sddat0, sddat1, sddat2, sddat3;
    pullup (sdcmd); pullup (sddat0); pullup (sddat1);
    pullup (sddat2); pullup (sddat3);

    wire       O_tmds_clk_p, O_tmds_clk_n;
    wire [2:0] O_tmds_data_p, O_tmds_data_n;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n;
    wire        O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n;
    wire [3:0]  O_sdram_dqm;
    wire [10:0] O_sdram_addr;
    wire [1:0]  O_sdram_ba;
    wire [31:0] IO_sdram_dq;

    reg  spi_io_ss  = 1'b1;
    reg  spi_io_clk = 1'b0;
    reg  spi_io_din = 1'b0;

    wire [4:0] m0s;
    assign m0s[1] = spi_io_din ;
    assign m0s[2] = spi_io_ss  ;
    assign m0s[3] = spi_io_clk ;
    wire spi_io_dout = m0s[0];
    wire mcu_intn    = m0s[4];

    //--------------------------------------------------------------------
    // The design
    //--------------------------------------------------------------------
    top uut (
        .clk27(clk27), .buts(buts), .leds(leds),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .sdclk(sdclk), .sdcmd(sdcmd),
        .sddat0(sddat0), .sddat1(sddat1), .sddat2(sddat2), .sddat3(sddat3),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .O_sdram_clk(O_sdram_clk),     .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n),   .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm),     .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba),       .IO_sdram_dq(IO_sdram_dq),
        .m0s(m0s)
    );

    //--------------------------------------------------------------------
    // Memory.  sdram.v uses single-word reads (BL1), CAS 2, 32 bits.
    //--------------------------------------------------------------------
    sdram_model #(.BURST(1)) ram (
        .clk(O_sdram_clk), .cke(O_sdram_cke),
        .cs_n(O_sdram_cs_n), .ras_n(O_sdram_ras_n),
        .cas_n(O_sdram_cas_n), .we_n(O_sdram_wen_n),
        .ba(O_sdram_ba), .a(O_sdram_addr),
        .dqm(O_sdram_dqm), .dq(IO_sdram_dq)
    );

    //--------------------------------------------------------------------
    // A minimal BL616: SPI master, mode 1, MSB first.
    //--------------------------------------------------------------------
    localparam SPI_HALF = 25;           // ns; 20 MHz like the real firmware
    localparam SPI_HOLD = 5;

    reg [7:0] spi_rx;

    task spi_byte(input [7:0] tx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_io_din  = tx[b];
                #SPI_HALF spi_io_clk = 1'b1;
                #SPI_HALF spi_io_clk = 1'b0;
                #SPI_HOLD;
                spi_rx = {spi_rx[6:0], spi_io_dout};
            end
            #(SPI_HALF * 20);
        end
    endtask

    task spi_begin; begin spi_io_ss = 1'b0; #SPI_HALF; end endtask
    task spi_end;   begin #SPI_HALF spi_io_ss = 1'b1; #(SPI_HALF*4); end endtask

    // SYS command 4: set a configuration value
    task sys_set_val(input [7:0] id, input [7:0] val);
        begin
            spi_begin;
            spi_byte(8'd0);     // target SYS
            spi_byte(8'd4);     // command "set value"
            spi_byte(id);
            spi_byte(val);
            spi_end;
        end
    endtask

    // HID command 1: one keyboard byte, as usb_host.c's kbd_tx sends it
    task hid_key(input [7:0] code);
        begin
            spi_begin;
            spi_byte(8'd1);     // target HID
            spi_byte(8'd1);     // keyboard
            spi_byte(code);
            spi_end;
        end
    endtask

    // HID command 2: a mouse report
    task hid_mouse(input [7:0] btns, input [7:0] dx, input [7:0] dy);
        begin
            spi_begin;
            spi_byte(8'd1);
            spi_byte(8'd2);
            spi_byte(btns);
            spi_byte(dx);
            spi_byte(dy);
            spi_end;
        end
    endtask

    // press and release a matrix key: the code as ports.v takes it.
    // The ОПТС scans the keyboard in its frame interrupt, so a key is
    // held for three frames.
    localparam KEY_HOLD = 70000000;   // 70 ms
    task key(input [7:0] code);
        begin
            hid_key(code);
            #KEY_HOLD;
            hid_key(8'h80 | code);
            #KEY_HOLD;
        end
    endtask

    // the main matrix (Emu80's KorvetKeyboard): code = row*8 + col + 1
    function [7:0] kcode(input [2:0] row, input [2:0] col);
        kcode = {2'd0, row, col} + 8'd1;
    endfunction
    localparam [7:0] K_SHIFT = 8'd57;   // row 7 col 0
    localparam [7:0] K_ENTER = 8'd49;   // row 6 col 0
    localparam [7:0] K_SPACE = 8'd56;   // row 6 col 7

    task shift_down; begin hid_key(K_SHIFT); #KEY_HOLD; end endtask
    task shift_up;   begin hid_key(8'h80 | K_SHIFT); #KEY_HOLD; end endtask

    // A character on the Корвет's keyboard: @ABCDEFG / HIJKLMNO / PQRSTUVW
    // / XYZ[\]^_ / 01234567 / 89:;,-./ unshifted, the symbols above the
    // digits with Shift.  Letters go in as their key; what case the ОПТС
    // makes of them is its business (CP/M does not mind).
    task type_char(input [7:0] ch);
        reg [2:0] row, col; reg sh, ok;
        begin
            ok = 1'b1; sh = 1'b0; row = 3'd0; col = 3'd0;
            if (ch >= "a" && ch <= "z") ch = ch - 8'h20;
            if (ch >= "@" && ch <= "_") begin
                ch = ch - "@";
                row = ch[5:3]; col = ch[2:0];
            end
            else if (ch >= "0" && ch <= "7") begin row = 3'd4; col = ch[2:0]; end
            else if (ch == "8" || ch == "9") begin row = 3'd5; col = ch - "8"; end
            else case (ch)
                ":": begin row = 3'd5; col = 3'd2; end
                ";": begin row = 3'd5; col = 3'd3; end
                ",": begin row = 3'd5; col = 3'd4; end
                "-": begin row = 3'd5; col = 3'd5; end
                ".": begin row = 3'd5; col = 3'd6; end
                "/": begin row = 3'd5; col = 3'd7; end
                "!": begin row = 3'd4; col = 3'd1; sh = 1'b1; end
                "\"": begin row = 3'd4; col = 3'd2; sh = 1'b1; end
                "#": begin row = 3'd4; col = 3'd3; sh = 1'b1; end
                "$": begin row = 3'd4; col = 3'd4; sh = 1'b1; end
                "%": begin row = 3'd4; col = 3'd5; sh = 1'b1; end
                "&": begin row = 3'd4; col = 3'd6; sh = 1'b1; end
                "'": begin row = 3'd4; col = 3'd7; sh = 1'b1; end
                "(": begin row = 3'd5; col = 3'd0; sh = 1'b1; end
                ")": begin row = 3'd5; col = 3'd1; sh = 1'b1; end
                "*": begin row = 3'd5; col = 3'd2; sh = 1'b1; end
                "+": begin row = 3'd5; col = 3'd3; sh = 1'b1; end
                "<": begin row = 3'd5; col = 3'd4; sh = 1'b1; end
                "=": begin row = 3'd5; col = 3'd5; sh = 1'b1; end
                ">": begin row = 3'd5; col = 3'd6; sh = 1'b1; end
                "?": begin row = 3'd5; col = 3'd7; sh = 1'b1; end
                "_", " ": begin row = 3'd6; col = 3'd7; end
                default: begin ok = 1'b0; $display("[tb] type_char: no key for %c (%02x)", ch, ch); end
            endcase
            if (ok) begin
                if (sh) shift_down;
                key(kcode(row, col));
                if (sh) shift_up;
            end
        end
    endtask

    task type_string(input [8*255:1] str);
        integer n, i;
        reg [7:0] c;
        begin
            n = 0;
            for (i = 0; i < 255; i = i + 1) if (str[8*(i+1) -: 8] != 8'd0) n = i + 1;
            for (i = n - 1; i >= 0; i = i - 1) begin
                c = str[8*(i+1) -: 8];
                type_char(c);
            end
        end
    endtask

    reg [7:0] st0, st1, st2, st3;

    // Exactly what sys_status_is_valid() in mnano/sysctrl.c does.
    task sys_status;
        begin
            spi_begin;
            spi_byte(8'd0);
            spi_byte(8'd0);
            spi_byte(8'h00);
            spi_byte(8'h00);  st0 = spi_rx;
            spi_byte(8'h00);  st1 = spi_rx;
            spi_byte(8'h00);  st2 = spi_rx;
            spi_byte(8'h00);  st3 = spi_rx;
            spi_end;
        end
    endtask

    // SYS command 5: the pending interrupts, acknowledged
    reg [7:0] irq_pending;
    task sys_irq;
        begin
            spi_begin;
            spi_byte(8'd0);
            spi_byte(8'd5);
            spi_byte(8'hFF);
            spi_byte(8'h00);  irq_pending = spi_rx;
            spi_end;
        end
    endtask

    // SYS command 7: the debug window
    reg [7:0] dbgb [0:31];
    integer dbg_i, dbg_o;
    task sys_debug;
        begin
            for (dbg_o = 0; dbg_o < 32; dbg_o = dbg_o + 8) begin
                spi_begin;
                spi_byte(8'd0);
                spi_byte(8'd7);
                spi_byte(dbg_o[7:0]);
                for (dbg_i = 0; dbg_i < 8; dbg_i = dbg_i + 1) begin
                    spi_byte(8'h00);
                    dbgb[dbg_o + dbg_i] = spi_rx;
                end
                spi_end;
            end
        end
    endtask

    //--------------------------------------------------------------------
    // SYS command 8: the ExtROM channel, as mnano/extrom.c drives it
    //--------------------------------------------------------------------
    reg [7:0] xr_count, xr_free, xr_flags;
    task xr_status;
        begin
            spi_begin;
            spi_byte(8'd0); spi_byte(8'd8); spi_byte(8'd0);
            spi_byte(8'h00); xr_count = spi_rx;
            spi_byte(8'h00); xr_free  = spi_rx;
            spi_byte(8'h00); xr_flags = spi_rx;
            spi_end;
        end
    endtask

    reg [7:0] xr_buf [0:1023];
    task xr_read(input integer n);
        integer i;
        begin
            spi_begin;
            spi_byte(8'd0); spi_byte(8'd8); spi_byte(8'd1); spi_byte(n[7:0]);
            for (i = 0; i < n; i = i + 1) begin spi_byte(8'h00); xr_buf[i] = spi_rx; end
            spi_end;
        end
    endtask

    task xr_write_byte(input [7:0] b);
        begin
            spi_begin;
            spi_byte(8'd0); spi_byte(8'd8); spi_byte(8'd2); spi_byte(b);
            spi_end;
        end
    endtask

    task xr_flush;
        begin
            spi_begin;
            spi_byte(8'd0); spi_byte(8'd8); spi_byte(8'd3);
            spi_end;
        end
    endtask

    task xr_load_rom(input [1023:0] fname);
        integer fd, c, n;
        begin
            fd = $fopen(fname, "rb");
            if (fd == 0) $display("[xr] cannot open %0s", fname);
            else begin
                spi_begin;
                spi_byte(8'd0); spi_byte(8'd8); spi_byte(8'd4);
                n = 0; c = $fgetc(fd);
                while (c != -1 && n < 256) begin spi_byte(c[7:0]); n = n + 1; c = $fgetc(fd); end
                spi_end;
                $fclose(fd);
                $display("[xr] %0t phase-1 ROM loaded: %0d bytes from %0s", $time, n, fname);
            end
        end
    endtask

    //--------------------------------------------------------------------
    // The ExtROM controller's brain: the Korvet-EXTROM API v2 as the
    // sibling repository's ext_rom.c has it, on host files.  Sectors are
    // 128 bytes; the image's logical sectors a track come from its
    // information sector (offset 16).  Writes change the copy only.
    //--------------------------------------------------------------------
    localparam XMAX = 819200;
    reg [7:0]  ximg [0:3][0:XMAX-1];
    integer    xsize [0:3];
    reg [7:0]  xroname [0:3][0:13];
    reg [1023:0] xfname;
    reg [7:0]  stage2 [0:32767];
    integer    stage2_size = 0;
    integer    xi, xk, xfd;
    reg        xtrace = 1'b0;

    task xload(input integer d, input [1023:0] name);
        integer fd, n, c;
        begin
            fd = $fopen(name, "rb");
            if (fd == 0) $display("[xr] cannot open %0s for drive %0d", name, d);
            else begin
                n = 0; c = $fgetc(fd);
                while (c != -1 && n < XMAX) begin ximg[d][n] = c[7:0]; n = n + 1; c = $fgetc(fd); end
                $fclose(fd);
                xsize[d] = n;
                $display("[xr] drive %c: %0s, %0d bytes, %0d sectors a track", "A" + d, name, n, ximg[d][16]);
            end
        end
    endtask

    initial begin
        xtrace = $test$plusargs("XTRACE");
        for (xi = 0; xi < 4; xi = xi + 1) xsize[xi] = 0;
        if ($value$plusargs("XA=%s", xfname)) xload(0, xfname);
        if ($value$plusargs("XB=%s", xfname)) xload(1, xfname);
        if ($value$plusargs("XC=%s", xfname)) xload(2, xfname);
        if ($value$plusargs("XD=%s", xfname)) xload(3, xfname);
        if ($value$plusargs("STAGE2=%s", xfname)) begin
            xfd = $fopen(xfname, "rb");
            if (xfd == 0) $display("[xr] cannot open %0s", xfname);
            else begin
                xk = $fgetc(xfd);
                while (xk != -1 && stage2_size < 32768) begin stage2[stage2_size] = xk[7:0]; stage2_size = stage2_size + 1; xk = $fgetc(xfd); end
                $fclose(xfd);
                $display("[xr] phase-2 loader: %0s, %0d bytes", xfname, stage2_size);
            end
        end
    end

    // the controller's state
    integer xstate = 0;            // 0 phase 1 (waiting for the file number), 1 commands, 2 a write's data
    reg [7:0] xcmd [0:4];
    integer   xn = 0;
    integer   xwr_drv, xwr_trk, xwr_sec, xwr_i;
    integer   xcmds = 0, xreads = 0, xwrites = 0;

    // a byte to the machine - with the firmware's poll for room: the
    // tx FIFO is 1 K and drops what is pushed into it full, and the
    // machine takes the phase-2 loader's 8 K a byte every few dozen
    // microseconds, so the sender credits itself from the status and
    // waits when the credit is spent
    integer xr_credit = 0;
    task xr_send(input [7:0] b);
        begin
            if (xr_credit == 0) begin
                xr_status;
                while (xr_free == 0) begin #50000; xr_status; end
                xr_credit = xr_free;
            end
            xr_write_byte(b);
            xr_credit = xr_credit - 1;
        end
    endtask

    // a 14-byte name field, zero padded
    task xr_send_name(input [8*16:1] name, input integer len);
        integer i;
        begin
            for (i = 0; i < 14; i = i + 1)
                xr_send((i < len) ? name[8*(len-i) -: 8] : 8'd0);
        end
    endtask

    // one 5-byte command
    task xr_command;
        reg [7:0] crc; integer off, spt, d;
        begin
            crc = xcmd[0] + xcmd[1] + xcmd[2] + xcmd[3] - 8'd1;
            xcmds = xcmds + 1;
            if (xtrace) $display("[xr] %0t cmd %02x drv %0d trk %0d sec %0d crc %02x%s", $time,
                                 xcmd[0], xcmd[1], xcmd[2], xcmd[3], xcmd[4], (crc == xcmd[4]) ? "" : " BAD");
            d = xcmd[1];
            if (crc != xcmd[4]) xr_send(8'd0);
            else case (xcmd[0])
                8'h00: xr_send(8'd1);
                8'h01: begin
                    if (d > 3 || xsize[d] == 0) xr_send(8'd0);
                    else begin
                        spt = ximg[d][16];
                        off = (xcmd[2] * spt + xcmd[3]) * 128;
                        xr_send(8'd1);
                        for (xi = 0; xi < 128; xi = xi + 1) xr_send((off + xi < xsize[d]) ? ximg[d][off + xi] : 8'h00);
                        xreads = xreads + 1;
                    end
                end
                8'h02: begin
                    if (d > 3 || xsize[d] == 0) xr_send(8'd0);
                    else begin
                        xr_send(8'd1);
                        xwr_drv = d; xwr_trk = xcmd[2]; xwr_sec = xcmd[3]; xwr_i = 0;
                        xstate = 2;
                    end
                end
                8'h80: begin
                    xr_send(8'd1); xr_send(8'd0);
                    xr_send_name("DISK", 4);
                    xr_send_name("DISKA.KDI", 9);
                end
                8'h82: xr_send((d <= 3 && xsize[d] != 0) ? 8'd1 : 8'd0);
                8'h85: begin
                    xr_send(8'd1);
                    xr_send_name("DISK", 4);
                end
                8'hA0, 8'hA1, 8'h88: xr_send(8'd1);
                default: begin $display("[xr] unsupported command %02x", xcmd[0]); xr_send(8'd0); end
            endcase
        end
    endtask

    // the loop: wake on the interrupt line, drain rx
    task xr_serve;
        integer n, i, base, blocks;
        begin
            xr_status;
            n = xr_count;
            if (n > 64) n = 64;
            if (xr_flags[3]) begin
                $display("[xr] %0t Control fell: the controller restarts", $time);
                xr_flush; xstate = 0; xn = 0; xr_credit = 0;
            end else if (n > 0) begin
                xr_read(n);
                for (i = 0; i < n; i = i + 1) begin
                    case (xstate)
                    0: begin
                        // the phase-1 loader's file number: 8 for the phase-2 loader
                        $display("[xr] %0t phase 1 asks for file %0d", $time, xr_buf[i]);
                        if (stage2_size == 0) $display("[xr] no +STAGE2= file to send");
                        else begin
                            blocks = stage2_size / 256;
                            xr_send(stage2[6]);                   // the load address, high byte
                            xr_send(blocks[7:0]);                 // 256-byte blocks
                            for (xi = 0; xi < blocks * 256; xi = xi + 1) xr_send(stage2[xi]);
                            $display("[xr] %0t phase 2 sent: %0d blocks to %02x00", $time, blocks, stage2[6]);
                        end
                        xstate = 1; xn = 0;
                    end
                    1: begin
                        xcmd[xn] = xr_buf[i]; xn = xn + 1;
                        if (xn == 5) begin xn = 0; xr_command; end
                    end
                    2: begin
                        base = (xwr_trk * ximg[xwr_drv][16] + xwr_sec) * 128;
                        if (base + xwr_i < xsize[xwr_drv]) ximg[xwr_drv][base + xwr_i] = xr_buf[i];
                        xwr_i = xwr_i + 1;
                        if (xwr_i == 128) begin xstate = 1; xwrites = xwrites + 1; end
                    end
                    endcase
                end
            end
        end
    endtask

    //--------------------------------------------------------------------
    // Run
    //--------------------------------------------------------------------
    integer run_ms, type_ms, cpu_n, gzupat_ms, gzi;
    reg [8*255:1] type_str;
    reg [1023:0]  stage1_file;
    integer tries;
    reg     fastboot, want_extrom;
    integer cfg_errs = 0;

    initial begin
        if (!$value$plusargs("RUN_MS=%d", run_ms)) run_ms = 40;
        fastboot = !$test$plusargs("NOFASTBOOT");
        want_extrom = $test$plusargs("EXTROM");

        if ($test$plusargs("VCD")) begin
            $dumpfile("sim/out/tb_top.vcd");
            $dumpvars(0, tb_top);
        end

        if (fastboot) begin
            wait (uut.init);
            #20000;
            force uut.count_rst = 24'h7FFFF0;
            #20000;
            release uut.count_rst;
            $display("[tb] %0t fastboot: count_rst forced", $time);
        end

        tries = 0;
        st0 = 0; st1 = 0; st2 = 0;
        while (tries < 200 && !(st0 == 8'h5c && st1 == 8'h42)) begin
            #100000;
            sys_status;
            tries = tries + 1;
        end

        if (st0 == 8'h5c && st1 == 8'h42)
            $display("[tb] %0t FPGA ready, core id 0x%02x (expect 08 = Korvet)", $time, st2);
        else begin
            $display("[tb] %0t FPGA never answered (got %02x %02x %02x)", $time, st0, st1, st2);
            cfg_errs = cfg_errs + 1;
        end
        if (st2 !== 8'h08) cfg_errs = cfg_errs + 1;

        sys_set_val("R", 8'd3);
        #50000;
        // the OSD's defaults (mnano/menu.c, variables_korvet), and the plusargs
        if (!$value$plusargs("CPU=%d", cpu_n)) cpu_n = 0;
        sys_set_val("A", 8'd1);
        sys_set_val("b", 8'd1);
        sys_set_val("c", cpu_n[7:0]);
        sys_set_val("f", {7'd0, !$test$plusargs("NOFDC")});
        sys_set_val("x", {7'd0, want_extrom});
        sys_set_val("y", {7'd0, $test$plusargs("AY")});
        sys_set_val("M", 8'd1);
        sys_set_val("m", {7'd0, $test$plusargs("GZU48")});
        sys_set_val("p", 8'd0); sys_set_val("q", 8'd0); sys_set_val("k", 8'd0); sys_set_val("l", 8'd0);
        if (want_extrom) begin
            if (!$value$plusargs("STAGE1=%s", stage1_file)) stage1_file = "tang/rom/stage1.rom";
            xr_load_rom(stage1_file);
        end
        sys_set_val("R", 8'd0);
        $display("[tb] %0t released reset (cpu %0d, fdc %0d, extrom %0d)", $time, cpu_n,
                 !$test$plusargs("NOFDC"), want_extrom);
        #2000;
        if (uut.system_volume !== 2'd1 || uut.system_beeper !== 1'b1 ||
            uut.system_cpu !== cpu_n[1:0] || uut.system_mouse !== 1'b1) begin
            $display("[tb] *** OSD VALUES WRONG after the defaults");
            cfg_errs = cfg_errs + 1;
        end

        // +GZUPAT=<ms>: at that time the first and the last pixel of every
        // tile of plane 0, page 0, are lit straight into the SDRAM model -
        // a ruler for the character grid, to see the text plane and the
        // graphics on the same cells - and every eighth tile is solid in
        // planes 1 and 2, so that a shift of the graphics by a whole tile
        // shows too (video.v's hand-over, 10 Sep 2026).
        if ($value$plusargs("GZUPAT=%d", gzupat_ms)) begin
            #(gzupat_ms * 64'd1000000);
            for (gzi = 0; gzi < 256 * 64; gzi = gzi + 1)
                ram.mem[21'h20000 + gzi] = (gzi[2:0] == 3'd0) ? 32'h00FFFF81 : 32'h00000081;
            $display("[tb] %0t graphics ruler written into plane 0", $time);
        end

        if ($value$plusargs("TYPE_STR=%s", type_str)) begin
            if (!$value$plusargs("TYPE_MS=%d", type_ms)) type_ms = 2500;
            #(type_ms * 64'd1000000);
            $display("[tb] %0t typing %0s", $time, type_str);
            type_string(type_str);
            key(K_ENTER);
        end

        #(run_ms * 64'd1000000);
        $display("[tb] %0t done: %0d video frames, leds=%b", $time, rx_frames, leds);
        $display("[tb] config checks: %0d wrong", cfg_errs);
        $display("[tb] cpu: %0d opcode fetches, %0d device reads, %0d device writes, %0d interrupts taken, %0d device waits, %0d memory waits",
                 m1_count, dev_rd, dev_wr, inta_count, devwait_count, memwait_count);
        $display("[tb] sysreg writes %0d (first %02x at %0t, last %02x), colour reg writes %0d, LUT writes %0d, text writes %0d, graphics writes %0d",
                 sr_writes, sr_first, sr_first_t, uut.sysreg << 2, nc_writes, lut_writes, txt_writes, gzu_writes);
        if (!$test$plusargs("NOMEMCHECK"))
            $display("[tb] read-after-write: %0d checked, %0d wrong", mem_checks, mem_errs);
        $display("[tb] sdram self-test: done %b, fail %b, late capture %b  (expect 1 0 0 against the model)",
                 uut.bist_done, uut.bist_fail, uut.cap_late);
        $display("[tb] sd transfers %0d; rom loaded %b", sd_xfers, uut.rom_loaded);
        if (want_extrom) $display("[xr] %0d commands, %0d sector reads, %0d sector writes, state %0d", xcmds, xreads, xwrites, xstate);
        sys_debug;
        $display("[tb] memcheck (CMD 7): %0d reads checked, %0d writes shadowed, %0d wrong; first %02x at %02x%02x got %02x pc %02x%02x; last %02x at %02x%02x got %02x pc %02x%02x",
                 {dbgb[20], dbgb[19]}, {dbgb[22], dbgb[21]}, dbgb[2],
                 dbgb[5], dbgb[4], dbgb[3], dbgb[6], dbgb[8], dbgb[7],
                 dbgb[11], dbgb[10], dbgb[9], dbgb[12], dbgb[14], dbgb[13]);
        $display("[tb] memcheck: flags %02x, %0d cpu resets, %0d fetches at 0000 (last from %02x%02x), last reg write %02x=%02x, pc %02x%02x",
                 dbgb[0], dbgb[15], dbgb[16], dbgb[18], dbgb[17], dbgb[23], dbgb[24], dbgb[26], dbgb[25]);
        $display("[tb] video: %0d tile fetches, page %0d, font %0d, wide %0d, lut[0..3] %x %x %x %x",
                 vid_fetches, uut.vid_ctrl[1:0], uut.vid_ctrl[2], uut.vid_ctrl[3],
                 uut.vid.lut[0], uut.vid.lut[1], uut.vid.lut[2], uut.vid.lut[3]);
        $display("[tb] i2s: %0d frames, %0d with sound", i2s_frames, i2s_nonzero);
        $display("[tb] hdmi: %0d packets, %0d ecc errors  (acr %0d, avi %0d, ai %0d, gcp %0d, audio %0d, null %0d)",
                 rx_packets, rx_ecc_errs, rx_acr, rx_avi, rx_ai, rx_gcp, rx_audio, rx_null);
        $display("[tb] hdmi frame: %0d x %0d, %0d bad guard bands", rx_w, rx_h_last, rx_bad_gb);
        if ($test$plusargs("TEXTDUMP")) text_dump;
        $finish;
    end

    // the ExtROM's brain runs on the interrupt line, with the MCU's
    // reaction time; and while the phase-2 loader is being sent the SPI
    // is busy for a while, so this is a loop, not an event
    always begin
        #100000;
        if (want_extrom && uut.xr_irq) xr_serve;
    end

    // the text RAM as a screen: 16 rows of 64.  Bytes above 7Fh are the
    // machine's Cyrillic (КОИ-8 with the font's own order); shown as '.'
    task text_dump;
        integer r, c; reg [7:0] ch;
        begin
            $display("[tb] the text RAM:");
            for (r = 0; r < 16; r = r + 1) begin
                $write("[txt] |");
                for (c = 0; c < 64; c = c + 1) begin
                    ch = uut.txt.mem[r*64 + c][7:0];
                    $write("%c", (ch >= 8'h20 && ch < 8'h7F) ? ch : ".");
                end
                $write("|\n");
            end
        end
    endtask

    //--------------------------------------------------------------------
    // Watching the processor
    //--------------------------------------------------------------------
    integer trace_ms, trace_int;
    reg     tracing = 1'b0;
    initial begin
        if (!$value$plusargs("TRACE_MS=%d", trace_ms)) trace_ms = 0;
        if (!$value$plusargs("TRACE_INT=%d", trace_int)) trace_int = 0;
        if (trace_int > 0) begin
            // from the n-th interrupt taken, one millisecond, then stop
            wait (inta_count >= trace_int);
            $display("[tb] %0t interrupt %0d taken: tracing for 1 ms, then stop", $time, trace_int);
            tracing = 1'b1;
            #(64'd1000000);
            $display("[tb] %0t TRACE_INT: stop", $time);
            $finish;
        end
        if (trace_ms > 0) #(trace_ms * 64'd1000000);
        tracing = 1'b1;
    end

    integer m1_count = 0, dev_rd = 0, dev_wr = 0, inta_count = 0, devwait_count = 0, memwait_count = 0;
    integer sr_writes = 0, nc_writes = 0, lut_writes = 0, txt_writes = 0, gzu_writes = 0;
    reg [7:0] sr_first = 8'd0; time sr_first_t = 0;
    reg     first_seen = 1'b0;
    reg [15:0] m1_adr, dev_adr, kbd_adr;
    reg        m1_pend = 1'b0, dev_pend = 1'b0, kbd_pend = 1'b0;

    always @(posedge uut.clk) begin
        if (uut.mem_rd && uut.cpu_m1_now) begin
            m1_count = m1_count + 1;
            m1_adr   = uut.cpu_a_now;
            m1_pend  = 1'b1;
            if (!first_seen) begin
                first_seen = 1'b1;
                $display("[tb] %0t CPU first fetch at %04x", $time, uut.cpu_a_now);
            end
        end
        if (m1_pend && uut.tphase == 4'd15 && !uut.mem_wait) begin
            m1_pend = 1'b0;
            if ($test$plusargs("CPUTRACE") && tracing)
                $display("[cpu] %0t %04x: %02x", $time, m1_adr, uut.cpu_din);
        end
        if (uut.inta_stb && uut.inta_n == 2'd0) begin
            inta_count = inta_count + 1;
            if (inta_count <= 3) $display("[tb] %0t interrupt %0d taken", $time, inta_count);
        end
        // +KBDTRACE: every read of the keyboard page (not the device
        // page, so IOTRACE never shows it) and every key from the MCU
        if (uut.mem_rd && uut.rd_kbd) begin kbd_adr = uut.cpu_a_now; kbd_pend = 1'b1; end
        if (kbd_pend && uut.tphase == 4'd15) begin
            kbd_pend = 1'b0;
            if ($test$plusargs("KBDTRACE") && tracing) $display("[kbd] %0t rd %04x -> %02x", $time, kbd_adr, uut.cpu_din);
        end
        if (uut.kbd_stb && $test$plusargs("KBDTRACE"))
            $display("[kbd] %0t key %02x (%s %0d)", $time, uut.kbd_byte, uut.kbd_byte[7] ? "up" : "down", uut.kbd_byte[6:0]);
        if (uut.mem_rd && uut.rd_dev) begin
            dev_rd = dev_rd + 1;
            dev_adr = uut.cpu_a_now; dev_pend = 1'b1;
        end
        // the device's byte is on cpu_din by phase 13 and stays until
        // the next read strobe, so phase 15 sees it for either CPU
        if (dev_pend && uut.tphase == 4'd15) begin
            dev_pend = 1'b0;
            if ($test$plusargs("IOTRACE") && tracing) $display("[io]  %0t rd %04x -> %02x", $time, dev_adr, uut.cpu_din);
        end
        if (uut.inta_stb && $test$plusargs("IOTRACE") && tracing)
            $display("[io]  %0t inta %0d -> %02x", $time, uut.inta_n, uut.inta_data);
        if (uut.mem_wr && uut.wr_dev) begin
            dev_wr = dev_wr + 1;
            if ($test$plusargs("IOTRACE") && tracing) $display("[io]  %0t wr %04x <= %02x", $time, uut.cpu_adr, uut.cpu_d_now);
        end
        if (uut.mem_wr && uut.wr_reg) begin
            if ($test$plusargs("IOTRACE") && tracing) $display("[io]  %0t reg %04x <= %02x", $time, uut.cpu_adr, uut.cpu_d_now);
            if (!uut.cpu_adr[7]) begin sr_writes = sr_writes + 1; if (sr_writes == 1) begin sr_first = uut.cpu_d_now; sr_first_t = $time; end end
            if (!uut.cpu_adr[6]) nc_writes = nc_writes + 1;
            if (!uut.cpu_adr[2]) lut_writes = lut_writes + 1;
        end
        if (uut.mem_wr && uut.wr_txt) txt_writes = txt_writes + 1;
        if (uut.mem_wr && uut.wr_gzu) gzu_writes = gzu_writes + 1;
        if (uut.tphase == 4'd8 && (uut.use_z80 ? uut.zcpu.dev_wait : uut.cpu.dev_wait)) devwait_count = devwait_count + 1;
        if (uut.tphase == 4'd8 && uut.mem_wait && !uut.use_z80) memwait_count = memwait_count + 1;
    end

    // +SPITRACE
    always @(posedge uut.clk)
        if ($test$plusargs("SPITRACE") && uut.mcu_sys_strobe)
            $display("[spi] %0t sys byte %02x start=%b state=%0d cmd=%02x id=%02x",
                     $time, uut.mcu_dout, uut.mcu_start,
                     uut.sctl1.state, uut.sctl1.command, uut.sctl1.id);

    //--------------------------------------------------------------------
    // Read-after-write check on the SDRAM's CPU port: a shadow of every
    // word written, lane by lane, compared against what is read back.
    // Eighteen address bits: the main RAM is words 0-3FFFh, a loaded ROM
    // 4000h-5FFFh and the graphics RAM 20000h-2FFFFh (membus.v), and the
    // graphics read-modify-write's read step comes through this port too.
    //--------------------------------------------------------------------
    reg [31:0] shadow [0:262143];
    reg [3:0]  known  [0:262143];
    integer    mem_errs = 0, mem_checks = 0;
    integer    si;
    initial for (si = 0; si < 262144; si = si + 1) known[si] = 4'd0;

    reg        rd_pend = 1'b0;
    reg [17:0] rd_w;
    always @(posedge uut.clk) begin
        if (uut.mem.cpu_req && uut.tphase == 4'd9) begin
            if (uut.mem.cpu_we) begin
                for (si = 0; si < 4; si = si + 1)
                    if (uut.mem.cpu_wmask[si]) begin
                        shadow[uut.mem.cpu_adr[17:0]][si*8 +: 8] = uut.mem.cpu_wdata[si*8 +: 8];
                        known[uut.mem.cpu_adr[17:0]][si] = 1'b1;
                    end
            end else begin
                rd_pend = 1'b1; rd_w = uut.mem.cpu_adr[17:0];
            end
        end
        if (uut.mem.cpu_ack && rd_pend) begin
            rd_pend = 1'b0;
            if (known[rd_w] != 4'd0 && !$test$plusargs("NOMEMCHECK")) begin
                mem_checks = mem_checks + 1;
                for (si = 0; si < 4; si = si + 1)
                    if (known[rd_w][si] && uut.mem.cpu_rdata[si*8 +: 8] !== shadow[rd_w][si*8 +: 8]) begin
                        mem_errs = mem_errs + 1;
                        if (mem_errs <= 10)
                            $display("[mem] %0t read %08x at word %05x, lane %0d wrote %02x",
                                     $time, uut.mem.cpu_rdata, rd_w, si, shadow[rd_w][si*8 +: 8]);
                    end
            end
        end
        if ($test$plusargs("MEMTRACE") && tracing && uut.mem.cpu_req && uut.tphase == 4'd9)
            $display("[ram] %0t %s word %05x mask %b %s %08x", $time, uut.mem.cpu_we ? "wr" : "rd",
                     uut.mem.cpu_adr, uut.mem.cpu_wmask, uut.mem.cpu_we ? "<=" : "", uut.mem.cpu_wdata);
    end

    always @(posedge uut.clk) if ($test$plusargs("ZTRACE") && tracing && uut.use_z80 && (uut.zcpu.cen || uut.tphase == 4'd9))
        $display("[z80] %0t ph %0d A %04x adr %04x wr_n %b rd_n %b mreq_n %b write %b no_read %b wait_n %b served %0d ts %b mc %b ir %02x", $time, uut.tphase,
                 uut.zcpu.A, uut.zcpu.adr, uut.zcpu.wr_n, uut.zcpu.rd_n, uut.zcpu.mreq_n, uut.zcpu.write, uut.zcpu.no_read, uut.zcpu.wait_n, uut.zcpu.served, uut.zcpu.tstate, uut.zcpu.mcycle, uut.zcpu.core.IR);
    final if ($test$plusargs("RAMDUMP")) $writememh("sim/out/ram.hex", ram.mem, 0, 131071);

    integer sd_xfers = 0;
    always @(posedge uut.clk) if (uut.sd_rdone) sd_xfers = sd_xfers + 1;

    integer vid_fetches = 0;
    always @(posedge uut.clk) if (uut.vid_req) vid_fetches = vid_fetches + 1;

    //--------------------------------------------------------------------
    // I2S monitor
    //--------------------------------------------------------------------
    reg [15:0] i2s_sr = 16'd0;
    reg [15:0] i2s_l  = 16'd0;
    reg        ws_d   = 1'b0;
    integer    i2s_frames = 0, i2s_nonzero = 0;
    always @(posedge HP_BCK) begin
        i2s_sr <= {i2s_sr[14:0], HP_DIN};
        ws_d   <= HP_WS;
        if (HP_WS && !ws_d) i2s_l <= i2s_sr;
        if (!HP_WS && ws_d) begin
            i2s_frames = i2s_frames + 1;
            if (i2s_l !== 16'd0 || i2s_sr !== 16'd0) i2s_nonzero = i2s_nonzero + 1;
        end
    end

    //--------------------------------------------------------------------
    // The HDMI receiver: hdmi_serdes is stubbed, so what leaves the
    // design is three ten-bit TMDS words a pixel clock.  This decodes
    // them as a sink does and rebuilds the picture for `make frames`.
    //--------------------------------------------------------------------
    wire        px_clk = uut.clk;
    wire [9:0]  t0 = uut.tmds_ch0;
    wire [9:0]  t1 = uut.tmds_ch1;
    wire [9:0]  t2 = uut.tmds_ch2;

    localparam [9:0] CTL00 = 10'b1101010100, CTL01 = 10'b0010101011,
                     CTL10 = 10'b0101010100, CTL11 = 10'b1010101011;
    localparam [9:0] VGB_02 = 10'b1011001100, VGB_1 = 10'b0100110011;

    function is_ctl(input [9:0] w);
        is_ctl = (w == CTL00) || (w == CTL01) || (w == CTL10) || (w == CTL11);
    endfunction

    function [1:0] ctl_of(input [9:0] w);
        ctl_of = (w == CTL00) ? 2'b00 : (w == CTL01) ? 2'b01 :
                 (w == CTL10) ? 2'b10 : 2'b11;
    endfunction

    function [7:0] tmds_dec(input [9:0] w);
        reg [7:0] qm, d;
        integer   i;
        begin
            qm = w[9] ? ~w[7:0] : w[7:0];
            d[0] = qm[0];
            for (i = 1; i < 8; i = i + 1)
                d[i] = w[8] ? (qm[i] ^ qm[i-1]) : (qm[i] ~^ qm[i-1]);
            tmds_dec = d;
        end
    endfunction

    function [4:0] terc4_dec(input [9:0] w);
        case (w)
            10'b1010011100: terc4_dec = 5'h00;
            10'b1001100011: terc4_dec = 5'h01;
            10'b1011100100: terc4_dec = 5'h02;
            10'b1011100010: terc4_dec = 5'h03;
            10'b0101110001: terc4_dec = 5'h04;
            10'b0100011110: terc4_dec = 5'h05;
            10'b0110001110: terc4_dec = 5'h06;
            10'b0100111100: terc4_dec = 5'h07;
            10'b1011001100: terc4_dec = 5'h08;
            10'b0100111001: terc4_dec = 5'h09;
            10'b0110011100: terc4_dec = 5'h0a;
            10'b1011000110: terc4_dec = 5'h0b;
            10'b1010001110: terc4_dec = 5'h0c;
            10'b1001110001: terc4_dec = 5'h0d;
            10'b0101100011: terc4_dec = 5'h0e;
            10'b1011000011: terc4_dec = 5'h0f;
            default:        terc4_dec = 5'h10;
        endcase
    endfunction

    function [7:0] ecc_step(input [7:0] ecc, input b);
        ecc_step = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'b10000011 : 8'd0);
    endfunction

    localparam RX_CTL = 0, RX_VGB = 1, RX_VID = 2,
               RX_DGB = 3, RX_DI  = 4, RX_DGBT = 5;

    integer rx_state   = RX_CTL;
    integer rx_gb      = 0;
    integer rx_frames  = 0;
    integer rx_packets = 0, rx_ecc_errs = 0;
    integer rx_acr = 0, rx_avi = 0, rx_ai = 0, rx_audio = 0, rx_null = 0, rx_gcp = 0;
    integer rx_bad_gb = 0;

    reg        rx_vs = 1'b0, rx_vs_d = 1'b0;
    integer    rx_x = 0, rx_y = 0, rx_w = 0, rx_h_last = 0;

    parameter MAXW = 1024;
    parameter MAXH = 640;
    reg [23:0] fb [0:MAXW*MAXH-1];

    reg [4:0]  pk_cnt = 5'd0;
    reg [23:0] pk_hdr;
    reg [55:0] pk_sub [0:3];
    reg [7:0]  pk_par [0:4];
    reg [7:0]  pk_ecc [0:4];
    integer    gi;

    integer fh, fi, fj, fh_h;
    integer written = 0, ppm_max;
    reg     want_ppm = 0;
    reg [255:0] fname;
    integer ppm_from, ppm_every;
    reg     ppm_armed = 1'b0;
    initial begin
        want_ppm = $test$plusargs("VIDEO_PPM");
        if (!$value$plusargs("PPM_MAX=%d", ppm_max)) ppm_max = 4;
        if (!$value$plusargs("PPM_FROM=%d", ppm_from)) ppm_from = 0;
        if (!$value$plusargs("PPM_EVERY=%d", ppm_every)) ppm_every = 1;
        if (ppm_from > 0) #(ppm_from * 64'd1000000);
        ppm_armed = 1'b1;
    end

    task write_ppm;
        begin
            written = written + 1;
            fh_h = (rx_y > MAXH) ? MAXH : rx_y;
            $sformat(fname, "sim/out/frame_%04d.ppm", rx_frames);
            fh = $fopen(fname, "wb");
            if (fh) begin
                $fwrite(fh, "P6\n%0d %0d\n255\n", rx_w, fh_h);
                for (fj = 0; fj < fh_h; fj = fj + 1)
                    for (fi = 0; fi < rx_w; fi = fi + 1)
                        $fwrite(fh, "%c%c%c",
                                fb[fj*MAXW+fi][23:16],
                                fb[fj*MAXW+fi][15:8],
                                fb[fj*MAXW+fi][7:0]);
                $fclose(fh);
                $display("[hdmi] %0t wrote %0s (%0dx%0d)", $time, fname, rx_w, fh_h);
            end
        end
    endtask

    task finish_packet;
        reg [7:0] ptype;
        begin
            rx_packets = rx_packets + 1;
            for (gi = 0; gi < 5; gi = gi + 1)
                if (pk_par[gi] !== pk_ecc[gi]) rx_ecc_errs = rx_ecc_errs + 1;
            ptype = pk_hdr[7:0];
            case (ptype)
                8'h00: rx_null  = rx_null  + 1;
                8'h01: rx_acr   = rx_acr   + 1;
                8'h02: rx_audio = rx_audio + 1;
                8'h03: rx_gcp   = rx_gcp   + 1;
                8'h82: rx_avi   = rx_avi   + 1;
                8'h84: rx_ai    = rx_ai    + 1;
                default: ;
            endcase
            if ($test$plusargs("HDMIDBG"))
                $display("[hdmi] %0t packet type %02x hdr %06x sub0 %014x",
                         $time, ptype, pk_hdr, pk_sub[0]);
        end
    endtask

    always @(posedge px_clk) begin : rx
        reg [1:0] c0, c1, c2;
        reg [4:0] n0, n1, n2;
        reg [7:0] dr, dg, db;
        c0 = ctl_of(t0); c1 = ctl_of(t1); c2 = ctl_of(t2);

        case (rx_state)
        RX_CTL: begin
            if (is_ctl(t0)) begin
                rx_vs_d = rx_vs;
                rx_vs   = c0[1];
                if (rx_vs && !rx_vs_d) begin
                    if (rx_frames > 0 && want_ppm && ppm_armed &&
                        written < ppm_max && (rx_frames % ppm_every) == 0) write_ppm;
                    rx_frames = rx_frames + 1;
                    rx_h_last = rx_y;
                    rx_x = 0; rx_y = 0;
                end
            end
            if (is_ctl(t1) && c1 == 2'b01) begin
                if (is_ctl(t2) && c2 == 2'b01) rx_state = RX_DGB;
                else                           rx_state = RX_VGB;
                rx_gb = 0;
            end
        end

        RX_VGB: begin
            if (is_ctl(t1) && ctl_of(t1) == 2'b01) begin
            end else begin
                if (t0 !== VGB_02 || t1 !== VGB_1 || t2 !== VGB_02)
                    rx_bad_gb = rx_bad_gb + 1;
                rx_gb = rx_gb + 1;
                if (rx_gb == 2) begin rx_state = RX_VID; rx_x = 0; end
            end
        end

        RX_VID: begin
            if (is_ctl(t0)) begin
                if (rx_x > rx_w) rx_w = rx_x;
                rx_x = 0;
                rx_y = rx_y + 1;
                rx_state = RX_CTL;
            end else begin
                db = tmds_dec(t0); dg = tmds_dec(t1); dr = tmds_dec(t2);
                if (rx_x < MAXW && rx_y < MAXH)
                    fb[rx_y*MAXW+rx_x] = {dr, dg, db};
                rx_x = rx_x + 1;
            end
        end

        RX_DGB: begin
            if (is_ctl(t1) && ctl_of(t1) == 2'b01 &&
                is_ctl(t2) && ctl_of(t2) == 2'b01) begin
            end else begin
                if (t1 !== VGB_1 || t2 !== VGB_1) rx_bad_gb = rx_bad_gb + 1;
                rx_gb = rx_gb + 1;
                if (rx_gb == 2) begin
                    rx_state = RX_DI;
                    pk_cnt = 5'd0;
                    for (gi = 0; gi < 5; gi = gi + 1) pk_par[gi] = 8'd0;
                end
            end
        end

        RX_DI: begin
            n0 = terc4_dec(t0); n1 = terc4_dec(t1); n2 = terc4_dec(t2);
            if (n0[4] || n1[4] || n2[4]) begin
                rx_gb = 0;
                rx_state = RX_DGBT;
            end else begin
                if (pk_cnt < 5'd24) pk_hdr[pk_cnt] = n0[2];
                for (gi = 0; gi < 4; gi = gi + 1) begin
                    pk_sub[gi][{pk_cnt, 1'b0}] = n1[gi];
                    pk_sub[gi][{pk_cnt, 1'b1}] = n2[gi];
                end
                if (pk_cnt >= 5'd28) begin
                    for (gi = 0; gi < 4; gi = gi + 1) begin
                        pk_ecc[gi][{pk_cnt[1:0], 1'b0}] = n1[gi];
                        pk_ecc[gi][{pk_cnt[1:0], 1'b1}] = n2[gi];
                    end
                end
                if (pk_cnt >= 5'd24) pk_ecc[4][pk_cnt[2:0]] = n0[2];
                if (pk_cnt < 5'd28) begin
                    for (gi = 0; gi < 4; gi = gi + 1) begin
                        pk_par[gi] = ecc_step(pk_par[gi], n1[gi]);
                        pk_par[gi] = ecc_step(pk_par[gi], n2[gi]);
                    end
                    if (pk_cnt < 5'd24)
                        pk_par[4] = ecc_step(pk_par[4], n0[2]);
                end
                if (pk_cnt == 5'd31) begin
                    finish_packet;
                    for (gi = 0; gi < 5; gi = gi + 1) pk_par[gi] = 8'd0;
                end
                pk_cnt = pk_cnt + 5'd1;
            end
        end

        RX_DGBT: begin
            rx_gb = rx_gb + 1;
            if (rx_gb == 2) rx_state = RX_CTL;
        end
        endcase
    end

endmodule
