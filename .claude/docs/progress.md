# Progress

The state of Korvet Nano, its defects, and what is next.  The rule
(`.claude/rules/guideline.md`): built, linted, simulated and timed are
four different claims and none of them is "works", and until this file
says a build booted on a board, none has.

## State - 6 September 2026, 0.1.0 alpha

**Built, linted, timed, and simulated to CP/M's A> prompt three ways.
Not on a board.**  Made on 5 September from PK8000 Nano's framework
(`../tang-pk8000`); the machine, the memory map, the graphics, the
device page, the ExtROM and the Z80 accelerator are new.  6 September
found and fixed four defects by simulation (below) and rewrote what the
5th's runs had really shown.

What each check shows:

- `make lint` - clean but for the usual warnings.
- `make bitstream` (6 Sep 11:54, after the fixes below) - Logic 44%,
  Register 23%, BSRAM 29/46 (64%), PLL 2/2; clk40 0 setup and 0 hold
  violations, the timing gate passes, `bin/tang.fs` is that build.
  (The first build, 5 Sep 18:32, had the HDMI PLL's `FCLKIN` still at
  "30", which the tool warned about as TA1118; corrected to "40.5" and
  the audio constants to CTS 40500, DI_PKTS 4 for the 200-clock back
  porch, and rebuilt.)
- `make fw` - builds, 439 KB.
- `make menu-test` - 0 errors, 18 screens; every form, value and page
  walked, the CPU and graphics-RAM changes seen to reset the machine.
- `make extrom-test` - 0 errors; the phase-1 request, the API's ping,
  a bad checksum, sector reads against the image and the substituted
  system tracks, a write read back, the read-only tool disk, mounting
  and its MOUNT.CFG, the folder, creating an image, a reset.
- `make sim` - the ОПТС 2.0 runs.  On a blue screen it tests every byte
  of the 256 KB for about nine seconds (Emu80's fast-reset tick count),
  then boots.  Three boots, all to **CP/M-80 v. 2.2, BIOS Ver. 1.2 (c)
  III 1988, A>** in the text RAM, at 11 s of machine time (about 20
  minutes of wall time each; the logs are `sim/out/`):
  - **the ВМ80 from the floppy** (`+KDIA=soft/disk.kdi +SDFAST`,
    `i80_disk.log`): 42 card transfers, 125 frame interrupts taken; the
    device trace shows the ОПТС's RESTORE, the sector register, READ
    SECTOR 84h and the boot sector's bytes 80 C3 00 DA 0A 00 00 01
    coming back exactly as the image has them.
  - **the Z80 at 5 MHz from the floppy** (`+CPU=2`, `z80t_disk.log`):
    the same 42 transfers, 308 interrupts taken.
  - **the ВМ80 from the ExtROM** (`+EXTROM +STAGE2=soft/extrom/STAGE2.ROM
    +XA=soft/disk.kdi`, `xr_final.log`): the ОПТС's Control test
    passes, phase 1 prints "BOOT:F500:2000-20" and 32 asterisks, asks for
    file 8 and takes the 8 KB phase-2 loader; stage 2 says "ROM: OPTS
    2.0 | PK8020 with FDC | GZU: 192k", reads 158 sectors of drive A's
    system tracks through the API (162 commands, all checksums good),
    patches the BIOS ("Detected: CPM_12_88_3_niijaf"), maps A: and B:
    to the image and C:, D: to the real floppies, and CP/M starts.
  In every run the self-test passes (done 1, fail 0, late 0), the
  read-after-write shadow on the SDRAM port is 0 wrong (up to 8.5
  million checked), the on-chip memcheck is 0 wrong, the HDMI frame is
  1024x512 with 0 ECC errors, the config values land.

**What the 5th's "boots BASIC" runs had really shown**: "Бейсик КОРВЕТ
в.2.0, Москва 1988 / Ok" is the ОПТС ROM's own BASIC (the banner is at
185Bh of korvet20.rom), which the ОПТС starts when the floppy boot
fails - and it had failed every time: every one of those runs says "sd
transfers 0".  The cause was defect 6 below.  Those runs did show the
memory test, the display, the interrupt and the Z80 correctly; they did
not show a disk boot.

### What the simulation shows, step by step
- Reset, the register set to 0 (ROM at 0000h, devices at 3800h), the
  ОПТС's opcode at 0000h; the memory test walks all 32 configurations
  (6 system-register writes seen before the boot decision).
- The colour table is loaded (16 writes), the colour register set, the
  text and graphics RAM written; the display shows the ОПТС's blue
  screen, then the boot's.
- The ОПТС lowers Control, reads the ВН59's request register, raises
  Control, reads it again (04C0h-04CEh), and goes to the ExtROM if bit 0
  followed, else to the floppy: drive select, RESTORE, the boot sector,
  else to its BASIC.

## Defects and open questions

1. **Settled: the testbench's read-after-write mismatches were the
   testbench's.**  `run7` (`+MEMTRACE +CPUTRACE` around the first
   mismatch, 7.94 s) showed every "wrong" read to be the read step of a
   graphics read-modify-write at word 23DFFh and below, compared against
   the shadow of main-RAM word 3DFFh: the shadow was indexed by seventeen
   address bits and the graphics RAM's words are 20000h-2FFFFh
   ({5'b00010, page, address}), so they aliased onto the RAM.  The shadow
   is eighteen bits wide now, and the two comments that said 10000h
   (`membus.v`, `video.v`) say 20000h.  The memory itself was never
   wrong: memcheck.v's 0 over the same run stands, and the aliasing
   explains the 0FFh (fresh graphics RAM) exactly.  Confirmed: the
   BASIC boot rerun with the widened shadow (`sim/out/basic.log`, 5 Sep
   23:29) has "read-after-write: 533750 checked, 0 wrong".
2. **The Z80 accelerator: three defects found by simulation, fixed,
   confirmation running.**  With `+CPU=2` the first runs fetched and
   wrote nothing to the register page.  Three causes, one under the
   other: (a) WAIT was sampled one enable before the read was served (a
   read that starts at phase 0, in turbo, meets the sample at phase 8
   before the phase-9 slot) - `cpuz80.v` holds WAIT until the strobe
   has gone out and the memory has answered; (b) the write's address
   was latched at the strobe itself, so `top.v` decoded every Z80 write
   with the previous read's address (the ОПТС's ВВ55 setup landed in
   the RAM at 301h) - the address is latched with the request now, as
   `cpu8080.v` does at SYNC; (c) WR/ was asserted in T3 only (tv80s.v's
   default), and in turbo a T-state is eight clocks, so a write whose
   T3 fell on phases 0-7 never met the strobe and was dropped without a
   trace - WR/ is from T2 now, with the same WAIT hold as a read.  A 3 ms
   trace shows the ОПТС's device writes and its screen clear going where
   they should.  Confirmed: with the disk mounted both `+CPU=1`
   (`z80p_fix.log`, 9 s, 66 interrupts taken) and `+CPU=2`
   (`z80t_fix.log`, 6 s, 82 interrupts taken) reach the ROM BASIC's
   "Ok" in the text RAM with 0 wrong on every check - so the IM 0 CALL
   through the one changed line in `tv80_core.v` takes.  (That "Ok" was
   the ОПТС's own BASIC, not a disk boot - defect 6; the real one is
   `z80t_disk.log`, 6 Sep, CP/M from the floppy.)  The 8080 is the
   default; the Z80 is the second claim.
3. **Nothing has been on a board.**  Everything below "simulated" is
   untested: the SDRAM pads at 40.5 MHz (12 ns of early margin on the
   capture where PK8000 Nano had 21 at 30 MHz - `sdram.v`'s header),
   the HDMI PHY, whether a monitor takes 1024x512 at 49.5 Hz, the real
   card, the seven wires, the ExtROM over the real handshake.
4. **Fixed: the ExtROM's Control went to the wrong request level.**
   The first ExtROM runs (`xr_io.log`, `xr_sense.log`) had the ОПТС
   raise Control, read the request register and go to the floppy
   instead: `devices.v` had put Control on IR7, the level the
   connector's pin and the ExtROM's documents call IRQ7, but the ОПТС
   2.0 tests **bit 0** (04C2h: LDAX D; CMA; ANI 01 with Control low,
   then ANI 01 with it high), and Erokhin's Etalon patch (`emu_patch/
   ppi.c`) raises request 0 for it.  Control is IR0 now, the floppy
   motor's time-out stays IR7.  `platform.md` carries the reasoning.
5. **Fixed: a request bit did not follow its line.**  `pic8259.v` held
   an edge-mode request until acknowledged; the datasheet and Emu80's
   `Pic8259::irq` clear it when the line goes low.  It follows the line
   now, and the floppy motor's request is therefore a level (the
   one-shot's inverted output: high while the motor is off) rather than
   a one-clock pulse the chip would never have seen.  The three boots
   above are the confirmation that the frame interrupt still takes.
6. **Fixed: the floppy's byte reached the CPU one read late.**
   `devices.v` took `fdc_rdata` on the clock `fdc.v` registered it, so
   every read of the ВГ93 returned the previous read's value (the first
   of a run its power-up 00 - visible in `xr_sense.log`).  The ОПТС's
   sector loop reads the status and returns when bit 0 says idle, so it
   quit on the first data byte (80h), the boot failed, and the ROM's
   BASIC came up looking like a boot; stage 2's floppy test (write 5 to
   the track register, read it back) said "no FDC" the same way.  One
   more stage in devices.v's pipe; the sector bytes in `i80_disk.log`
   are the proof.  PK8000 Nano takes the byte through its own mux and
   does not have this.
7. **Fixed (testbench): the ExtROM brain overran the tx FIFO.**  It
   pushed the phase-2 loader's 8 K into the 1 K FIFO without asking for
   room, the FIFO drops what it cannot take, and the machine got six
   blocks then waited for ever (`xr_ir0.log`).  The brain credits itself
   from the status's room byte now, as `mnano/extrom.c` always did.  The
   FIFO's drop-when-full is unchanged and a flag for it on the Debug page
   would be a reasonable addition.

## Not built yet

- The tape as `.cas`/`.wav` files (the two-bit output is summed into the
  sound; the input reads 0).
- The printer (its data and strobe are decoded and go nowhere).
- The network ВВ51 (present, its line idle).
- A digital joystick on the ВВ55 #3's port B (the connector is the
  ExtROM's and the AY's here).
- Writing settings needs the card write path, which the firmware has
  (sdc.c) but which is untested on this core.

## What is next, in order

1. A board: flash, and write here what the LEDs, the screen and the
   Debug page show, the way PK8000 Nano's progress.md did.  Everything
   above is simulation.
2. The ExtROM against the real firmware (the testbench's brain is a
   stand-in): `make extrom-test` covers the state machine, the board
   covers the handshake's timing.
3. The Z80 from the ExtROM (only the ВМ80 has booted that way), and
   the accelerator's device wait under CP/M.
