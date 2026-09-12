# Changelog

## Unreleased

- Reconfig support for `../tang-ultima` (three machines in one flash):
  SYS command 9 + A5h in `sysctrl.v` pulses `reconfig_n`, RECONFIG_N as a
  GPIO output on pin 9; `gowin_tcl.py --abs --multiboot-addr` and
  `timing_check.py <pnr dir>` for building out of this tree.  A build
  here is unchanged in behaviour: its header names address 0.

## 0.1.0 alpha - 5 September 2026

The first cut, built in one day from PK8000 Nano's framework.  Authors:
Sergei Lemeshev and Claude Code.  Not yet run on a board.

### The machine
- The КР580ВМ80А (vm80a) at 2.5 MHz on a single 40.5 MHz clock, sixteen
  clocks a T-state, with the device page's wait state; or the Z80
  accelerator (tv80) at 2.5 or 5 MHz, the ВН59's CALL through IM 0.
- The memory configuration PLM D31 as its own equations (`memmap.v`,
  generated and checked against Emu80's table); 64 KB in the SDRAM; the
  built-in ОПТС 2.0 in BSRAM and any ROM image from the card in the
  SDRAM instead; the graphics RAM's three planes as one 32-bit word,
  four pages or one; the text RAM with its attribute flip-flop.
- The display: 512x256, text over three planes through the colour
  table, both fonts, the 32-column mode; 1024x512 over HDMI at 49.5 Hz.
- The device page: ВИ53, ВН59, three ВВ55 (mode 0 and mode 2), two
  ВВ51, the ВГ93 with four .kdi drives, the motor time-out.
- The keyboard's two matrices from USB; a Microsoft serial mouse on the
  ВВ51 #1 from the USB mouse; the piezo, the tape output's two bits and
  the AY module over HDMI and I²S.
- The Korvet-EXTROM disk emulator: the connector side in the FPGA, the
  controller's program in the BL616 on the card's `extrom` folder.

### The on-screen menu
- Four floppies, Reset, Hardware (CPU, OPTS ROM, Floppy, ExtROM, AY,
  Mouse, Graphics RAM, Volume, Beeper, four write protections), About,
  Debug, Save settings; settings in `/korvet.ini`; the core id 8.

### For builders
- `make lint`, `make sim` (the ОПТС to its blue screen and, given nine
  seconds, its boot; frames as `.ppm`; typing; the ExtROM boot with the
  testbench as the controller), `make bitstream` with the timing gate,
  `make fw`, `make menu-test`, `make extrom-test`; `tools/decplm.py`,
  `tools/kdi.py`; the documentation under `.claude/`.
