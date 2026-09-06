# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in
this repository.

## Project overview

This is the **ПК8020 "Корвет"** - the Soviet school computer of 1987, a
КР580ВМ80А (8080A) at 2.5 MHz with a 512x256 display of a text plane
over three bit-planes, its devices in the memory map behind a
programmable PLM - reimplemented on a **Tang Nano 20K** (Gowin
GW2AR-18C), with a **Bouffalo BL616** board alongside it providing USB
HID, the SD card and the on-screen menu.  It is a sibling of **PK8000
Nano** (`../tang-pk8000`) and through it of **UKNC Nano**
(`../tang-uknc`): the MiSTeryNano side, the HDMI encoder, the SDRAM
timetable, the toolchain, the Makefile and the method are taken from
there, and the machine itself is new.  Started 5 Sep 2026.

Two halves, two toolchains, and **both build here**:

```
tang/     the FPGA design      - make bitstream  (gw_sh, headless Gowin, ~1 min)
mnano/    the BL616 firmware   - make fw
bin/      the two shipped binaries, both rebuilt from these sources
sim/      testbench, SDRAM model and the stand-ins for the vendor primitives
tools/    the fetched toolchain - make toolchain, ~7 GB, not committed (scripts are)
tang/rom/ the ROM images, the font, the ExtROM's loader, Emu80's memory table
soft/     two .kdi images
infosource/  the operator's sources: the техописание, schematics, PLMs, ExtROM docs
```

`make lint` and `make sim` are the cheap checks; `make bitstream` is the
real one.  `make help` lists the rest.  **What cannot be done here is
running it on a board.  Nothing has been on a board yet.**  See
`.claude/docs/progress.md` for what each build showed; anything built is
untested on the board until it says otherwise there.  So "it builds",
"it lints", "it boots in simulation" and "it meets timing" are four
different claims, none of them is "it works", and you should say which
one you are making.

The machine, as implemented: vm80a (1801BM1's gate-level КР580ВМ80А),
or tv80 as the Z80 accelerator, on a 40.5 MHz clock with the two phases
as enables, a T-state of sixteen clocks; the PLM D31 as `memmap.v`; the
64 KB, a loaded ROM and the graphics RAM's three planes (one 32-bit word
an address) in the SDRAM through `membus.v`'s write queue, with a fixed
slot for the CPU and one for the video in every T-state; the built-in
ОПТС 2.0 and the font in BSRAM; the text RAM with its attribute
flip-flop; the display rendered line by line into a buffer and read out
as 1024x512 at 49.5 Hz over HDMI; the device page with the timer, the
interrupt controller, the three ВВ55s, the two ВВ51s and the ВГ93 with
four .kdi drives; the serial mouse from USB; the ExtROM disk emulator
with the BL616 as its controller; the AY module on the side connector.

Key documentation: `.claude/docs/platform.md` (the machine: the memory
map, the registers, the graphics arithmetic, the device page, the
keyboard, where the facts come from), `.claude/docs/fpga.md` (the
implementation: the clock, the timetable, the memory map's users, the
files), `.claude/docs/video.md` (the display), `.claude/docs/extrom.md`
(the ExtROM: protocol, the card's folder, the firmware),
`.claude/docs/mcu.md` (the firmware, the keymap, the menu letters),
`.claude/docs/build.md` (both toolchains, the Makefile, what lint and
simulation cover, flashing, reading the board), `.claude/docs/tools.md`
(`tools/` and the ROM data), `.claude/docs/progress.md` (state, defects,
what is next).  Follow `.claude/rules/guideline.md`,
`.claude/rules/git.md` and `.claude/rules/timing.md`.

## Traps worth remembering

- **`tang/korvet.gprj` is the source of truth for what gets built.**
  Every file under `tang/src/` is in it and every module in it is
  instantiated; keep it that way.  `tools/srcs.py` reads it for lint
  and sim, `tools/gowin_tcl.py` for the bitstream.
- **There is one clock, and everything is a phase of it.**  `clk` is
  40.5 MHz; `tphase` (0..15) is the CPU's T-state, `hcnt`/`vcnt` the
  machine's raster, and they run from PLL lock.  The SDRAM controller
  gives the CPU phases 9..16 and the video phases 1..8 of every
  T-state and nobody ever waits for memory but for `membus.v`'s hazard.
  Do not add a clock, a divided clock, or a flop clocked by a data
  signal - a slower thing is an enable - and do not touch memory
  outside a slot.  `.claude/rules/timing.md` keeps it so.
- **The machine has no I/O instructions; everything is in the memory
  map, and the map is the PLM's.**  `memmap.v` is generated from the
  D31 equations (`tools/decplm.py`, `make memmap`) and the script checks
  them against Emu80's `mapper.mem` on every read of every
  configuration.  Reads and writes decode differently (a write under a
  ROM window goes to the RAM beneath; the register page reads as RAM).
  Do not hand-edit the decode; change the script.
- **Every access to the device page costs one wait state**, inserted by
  the board (`1READY = CSDEV | WAIT`).  `cpu8080.v` and `cpuz80.v` pay
  it from `dev_hit`, which is the PLM's z[4] at the strobe.  Emu80
  charges two; the техописание says one.
- **A graphics write is a mask on three planes, and the three planes of
  an address are one SDRAM word.**  `membus.v` does the read-modify-write
  in two slots out of its queue; the colour register's value is captured
  with the write, and a CPU read of a queued word is held off (READY)
  until the queue has passed it.  The read arithmetic (colour compare,
  plane select) is in `top.v` on the word that comes back.
- **The ВН59's interrupt is a three-byte CALL, and every one of its
  three bytes is an acknowledge cycle.**  vm80a marks the two operand
  reads with the INTA status bit (the техописание's M8 cycles) and
  `cpu8080.v` counts them (`inta_n`); the controller answers CDh, the
  low byte, ICW2.  tv80's IM 0 reads the operands from PC: one line in
  `tv80_core.v` (marked "Korvet Nano") keeps PC still during the
  interrupt instruction and `cpuz80.v` answers those reads from the
  controller.  Do not touch that line without reading `cpuz80.v`.
- **The text RAM's ninth bit is the attribute, written through the
  flip-flop the ВВ55 #1's port C bits 5:4 drive** (01 clear, 10 set, 11
  hold what the last read latched, 00 leave stored).  `txtram.v` reads
  the stored attribute before it writes, so a write is two clocks; the
  strobes are T-states apart and never collide with the read.
- **VBL is 1 while the picture is drawn** (ВВ55 #1 port A bit 1) and
  its FALL is IRQ4.  MAME has it the other way; the техописание and
  Emu80 agree on this one.
- **The SDRAM word is on the bus one slot clock EARLIER than the CAS
  latency suggests, because the chip is clocked 90 degrees behind.**
  The capture is at slot clock 3 (`sdram.v`'s header has the arithmetic,
  at 40.5 MHz with less margin than at 30) and the self-test moves it
  to 4 if the board says so; `bist_fail` is on LED3.  All of that is
  PK8000 Nano's, kept.  A read-after-write count with "0 wrong" is only
  evidence if the data was not zero.
- **The ОПТС tests every byte of the 256 KB before it boots** - about
  nine seconds of machine time, a quarter of an hour of simulation.  The
  blue screen with "ОПТС 2.0" and the mark at the bottom right is that
  test, not a hang.  `RUN_MS=1500` shows the screen; `RUN_MS=10000`
  shows the boot.
- **The ExtROM's bytes cross the MCU, not the SD path.**  `extrom.v`
  is a 256-byte ROM and two FIFOs on the ВВ55 #3's mode-2 handshake;
  `mnano/extrom.c` is the controller (Erokhin's `ext_rom.c`, function
  for function) on FatFs under `/sd/extrom`; `sysctrl.v`'s CMD 8 is the
  channel and interrupt bit 4 the wake.  The phase-1 ROM is served at
  the address on port B while port C is 0 and port A is still in mode
  0; from mode 2 on it is the FIFOs.  Control falling is the
  controller's reset.  The testbench has a Verilog copy of the brain
  (`+EXTROM`) so the FPGA side is tested without the firmware, and
  `make extrom-test` tests the firmware's side without the FPGA.
- **`hid.v`'s keyboard byte has a strobe** (PK8000 Nano's lesson): the
  code is `row*8+col+1` (1..64 the main matrix, 65..88 the second) with
  bit 7 for release, 0 for no key - `mnano/korvet.h` and `ports.v` agree
  and must keep agreeing.  A pressed key is a 1 in the matrix byte, the
  address bits select the rows.
- **The firmware's core id is 8** (`CORE_ID_KORVET`), and every table
  the firmware selects by core is indexed by it - `settings_file[]`,
  `keymap[]`, `modifier[]`, `core_names[]`.  A menu value is three
  edits: the letter in the form string, `variables_korvet[]`, and
  `sysctrl.v`.  'c' and 'm' send a reset after themselves.
- **The firmware mounts the images while it holds the machine in reset**
  (`menu.c`: the files, then R=3, R=0), so `mounted`/`image_size`
  bookkeeping is never under `cpu_rst` (`top.v`'s `mounted[]`,
  `romload.v`); PK8000 Nano's IDE learned that.
- **`hdmi_tx.v` sends FOUR packets an island here** (the back porch is
  200 clocks) and `ACR_CTS` is 40500 for exactly 48 kHz.  Changing the
  raster's blanking means checking `DI_PKTS` against it.
- **The frame is 1024x512 in 1312x624 at 49.5 Hz, not a CEA mode.**
  Whether a given sink takes this is a board question, and a black
  screen on a board is that before it is anything else.
- **`tools/` on this host is hard links into `../tang-pk8000/tools/`.**
  Same files, same inodes; an in-place edit to one is an edit to both.
  Nothing in `tools/` is edited in place - a new toolchain version is a
  fresh fetch.
- **Flashing the FPGA is replug, flash, power-cycle - in that order**,
  and the BL616 must be in boot mode (hold BOOT, tap RESET, release
  BOOT).  `.claude/docs/build.md`.
- **Gowin's synthesis will not read a file that says `` `default_nettype
  none``** and its place-and-route refuses an inferred dual-port RAM
  that reads the old data on a write (PA2122).  An inferred RAM here is
  read-only-or-write on a port, never both in one clock; `wd1793.sv`
  and `txtram.v` are written that way.
- **The SD request must stay up until the card is busy on it**
  (`sd_arbiter.v` latches the direction and the sector at the grant).
- **`prompts/` is a transcript, not context.**  Never read it at the
  start of a session; append every exchange as it finishes, in the form
  `.claude/rules/guideline.md` gives.
