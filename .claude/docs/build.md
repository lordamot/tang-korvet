# Building and flashing

Two binaries, two toolchains.  What ships prebuilt is:

```
bin/tang.fs      the FPGA bitstream   (make bitstream)
bin/bl616.bin    the MCU firmware     (make fw, copied by hand)
```

A user who only wants to run the machine flashes those two and needs no
toolchain at all.  That is the point of committing them.

**Both halves build on this host.**  Everything they need lives under
`tools/`, fetched by `make toolchain` - about 7 GB including Gowin -
nothing is installed on the host and `tools/` is in `.gitignore`.  On
this machine `tools/` was made as hard links into `../tang-pk8000/tools/`
(5 Sep 2026), which is the same content at no cost in disk; a clone
elsewhere runs `make toolchain`.

```
make toolchain   fetch the toolchain into tools/  (~7 GB, once)
make lint        Verilator over the whole design - the fast check, seconds
make sim         run the machine (RUN_MS=1500; ~11 ms a second)
make frames      the same, writing video frames as .ppm (PPM_FROM=1200)
make wave        the same, dumping a VCD, then open it (WAVE_MS=2)
make bitstream   build the FPGA bitstream -> bin/tang.fs (about a minute)
make timing      the timing gate alone, on the last PnR report
make fw          build the BL616 firmware -> build/fw/bl616.bin
make menu-test   the OSD menu on the host: every form walked, screens as PNG
make extrom-test the ExtROM controller's state machine on the host
make rom         regenerate the two pROM modules from tang/rom/
make memmap      regenerate tang/src/korvet/memmap.v from tools/decplm.py
make mif         the ROMs as $readmemh hex for the sim models (build/mif/)
make flash-fpga  openFPGALoader the shipped bitstream to SRAM
make flash-mcu   flash the firmware over UART (COMX=/dev/ttyACM0)
```

`SIMARGS="+CPUTRACE +TRACE_MS=100"` and the like pass plusargs to the
simulator; `sim/tb/tb_top.v`'s header lists them.

## The FPGA half

Toolchain: **Gowin EDA Education edition**, V1.9.11.03, in
`tools/gowin/`.  `make bitstream` drives its headless shell with a Tcl
generated from `tang/korvet.gprj` and the IDE's own
`tang/impl/korvet_process_config.json` (`tools/gowin_tcl.py`), so the
command line and an IDE build read the same list and options.  The
result is `tang/impl/pnr/korvet.fs`, copied to `bin/tang.fs` when the
timing gate passes.  `gw_sh`'s three quirks - its bundled libraries
fight a current Linux, its option names differ from the IDE's, and
`-use_sspi_as_gpio 1` is not optional - are handled by `tools/fetch.sh`
and the Makefile; UKNC Nano's `.claude/docs/build.md` has the account.

The timing gate (`tools/timing_check.py`, `.claude/rules/timing.md`)
wants `clk27`, `clk40` and `spi_clk` in the report, no violations, no
undeclared or unrelated clock.

## What lint and simulation cover

`make lint` runs Verilator over exactly the `.gprj`'s list with the
stubs standing in.  It is clean but for warnings, most of them the
MiSTeryNano sources', vm80a's and tv80's (timescale, unused bits); any
error is yours.

`make sim` builds the whole machine into a Verilator binary against a
functional SDRAM model (32 bits wide) and a stand-in BL616 that speaks
the real SPI protocol, and runs the ОПТС.  The testbench's end-of-run
lines are the checks:

```
[tb] config checks: 0 wrong                     the OSD values landed in sysctrl
[tb] cpu: N opcode fetches, ... device waits    the core runs; the device wait is paid
[tb] sysreg writes N (first 20 ...)             the ОПТС sets its map
[tb] read-after-write: N checked, 0 wrong       every SDRAM word read back as written
[tb] sdram self-test: done 1, fail 0, late 0    the controller's own four words
[tb] memcheck (CMD 7): ...                      the Debug page's numbers
[tb] hdmi: ... 0 ecc errors                     the data islands are well formed
[tb] hdmi frame: 1024 x 512                     the raster is what video.md says
[tb] the text RAM:                              (+TEXTDUMP) the screen as text
```

The SDRAM model is FUNCTIONAL: it tracks rows and serves words, checks
no timing, and drives read data the way the chip does with the
90-degree clock.  Nothing here says anything about the real card, the
real SDRAM pads, the HDMI PHY or a monitor's opinion of a 49.5 Hz frame.

The ОПТС tests all of the memory at start - about nine seconds of
machine time (Emu80's `fastResetCpuTicks` is 23.5 million ticks) -
before it decides how to boot, so a boot is `RUN_MS=10000` and a
quarter of an hour of wall time.  `make frames PPM_FROM=9800 PPM_MAX=2`
with `+TEXTDUMP` shows what it did.  The runs `progress.md` reports:

```
make frames RUN_MS=1500 PPM_FROM=1400 PPM_MAX=2 SIMARGS="+TEXTDUMP"
make frames RUN_MS=10000 PPM_FROM=9800 PPM_MAX=2 SIMARGS="+TEXTDUMP +KDIA=soft/disk.kdi +SDFAST"
```

`+TYPE_STR=` types any text at the prompt (`_` for a space; note
`PPM_FROM` is milliseconds, not a frame number).  Type after the
prompt is really there: CP/M's BIOS keeps ONE key and does not scan
while it is unread, and without `+SDFAST` the floppy boot reaches its
first console read only at about 9.5 s, so keys typed before that are
lost after the first (progress.md, defect 9).  `+KBDTRACE` shows every
read of the keyboard page while tracing and every key from the MCU -
`+IOTRACE` does not, the keyboard page is not the device page.
`+GZUPAT=<ms>` writes
a ruler into the graphics RAM at that time (the edge pixels of every
tile in plane 0, every eighth tile solid in planes 1 and 2) so that a
frame shows the text and the graphics on the same cells, `+CPU=1`
or `2` runs the Z80, `+EXTROM +STAGE2=... +XA=...` boots the ExtROM way
with the testbench as the controller (`extrom.md`), `+PPM_EVERY=` thins
the frames.  `tools/ppm2png.py` turns a frame into a PNG.

On this host the simulation runs at about 11 ms of machine time a
second.  Runs are independent: run them in parallel from separate
directories that hold `build/`, `soft/` and `tang/` as symlinks and an
empty `sim/out/`, since the testbench writes its frames to `sim/out/`
relative to where it runs.

## The MCU half

The Bouffalo SDK (`master_legacy`) plus a T-Head RISC-V GCC, both in
`tools/`; `make fw` builds `mnano/` into `build/fw/bl616.bin` and it is
copied on to `bin/` by hand.  The three things UKNC Nano settled to make
that work (the SDK branch, the host-tool patch, the two `-D`s through
`BOARD`) are still in `tools/fetch.sh` and the Makefile and still
needed.  The version in the OSD's caption is the first line of
`VERSION`, read by `mnano/CMakeLists.txt` into `CORE_VERSION`.

## Flashing

**Tang Nano 20K**: `make flash-fpga` (SRAM, gone at power-off) or
`make flash-fpga-flash` (the SPI flash), then **power-cycle the board**
- `openFPGALoader -f -r` writes the flash and reports success but does
not reliably reconfigure the chip.  Once anything has opened
`/dev/ttyUSB*` the next flash fails with `ftdi_usb_reset failed` and
only replugging the cable clears it.  Replug, flash, power-cycle, in
that order.

**BL616**: hold BOOT, tap RESET, release BOOT; the chip enumerates as a
serial port (`/dev/ttyACM0`); `make flash-mcu COMX=/dev/ttyACM0` (needs
`dialout`; `sg dialout -c '...'` works without a relogin).  `BFLB IMG
LOAD HANDSHAKE FAIL` means the port opened and nothing answered: not in
boot mode, or the wrong port.  Press RST afterwards.

## Reading the board

The six LEDs, lit when the thing is true (`top.v`'s last lines; the
board's LEDs are active low and the assignments invert):

```
LED0  the power-on reset has finished (lit 207 ms after the memory is up)
LED1  the piezo is on
LED2  the ExtROM is active (Control up with the switch on) - or, at boot,
      the SDRAM self-test chose the late capture
LED3  a disk or SD transfer is busy - or, at boot, the SDRAM self-test
      FAILED both captures
LED4  the CPU is held in reset
LED5  the SDRAM is initialised
```

A healthy start is LED5 then LED0 coming on, LED4 going out, and 2 and 3
dark.  What the screen says while the ОПТС boots: its blue screen with
"ОПТС 2.0" at the top left and the test's progress mark at the bottom
right for about nine seconds (it tests every byte of the 256 KB), then
the boot: from the ExtROM if it is on (the ОПТС looks for it first),
else from drive A if a disk is in it, else its own BASIC.  The OSD on F12 says whether the MCU link works, and needs
no memory.

**The Debug page** (main form, below About) is PK8000 Nano's instrument:
`memcheck.v` keeps a shadow of F000h-FFFFh in BSRAM (the ОПТС's stack
and variables are there in the boot configurations), compares every
read from there with it as the word comes back, and counts; the MCU
reads 32 bytes through `sysctrl.v`'s CMD 7 and formats them
(`menu_debug_open`, menu.c).  The lines:

```
por 1 init 1 rst 0 bist 1 fail 0 late 0     the flags, as the LEDs
F000-FFFF: 4100 rd 4351 wr 0 bad             reads checked, writes shadowed, mismatches
1st F7FC exp 29 got 00 pc 005C               the first mismatch: address, shadow, memory, last opcode fetch
last ....                                    the most recent one
cpu resets 2, M1 at 0000: 2                  resets seen; opcode fetches from 0000h
  last from 292A                             the fetch before the last one at 0000h
last OUT 7f=14 pc 24C1 m1 37                 the last register-page write, the last opcode address, a fetch counter
```

"bad" at 0 with the ОПТС still restarting means the RAM told the CPU
the truth and the fault is elsewhere; "M1 at 0000" climbing faster
than "cpu resets" is the ROM jumping to 0000h by itself.  A counter
that does not move between two samples is a machine that has stopped.
The simulation's numbers (`make sim`, the `[tb] memcheck` lines) are
what a working machine shows.

## The SD card

FAT32.  The firmware reads it through the FPGA's `sd_card.v` and keeps
its settings in `/korvet.ini`; the floppy images anywhere on it; the
ExtROM's files under `/extrom` (`extrom.md`).
