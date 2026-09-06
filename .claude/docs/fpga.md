# The FPGA implementation

Target: **GW2AR-LV18QN88C8/I7** (GW2AR-18C, QFN88) - the Tang Nano 20K.
Project file `tang/korvet.gprj`, top module `top` in `tang/src/top.v`,
constraints `tang/src/korvet.cst` and `korvet.sdc`.

## What is built

**`tang/korvet.gprj` is the source of truth.**  Every file under
`tang/src/` is in it and every module is instantiated.  `tools/srcs.py`
reads the list for lint and simulation, `tools/gowin_tcl.py` for the
bitstream.

| role | files |
|---|---|
| top | `top.v` - the clock, the resets, the counters, the memory map's users, the mix, and every instance |
| the processor | `korvet/vm80a.v` (the КР580ВМ80А, 1801BM1, verbatim), `korvet/cpu8080.v` (its bus, the status decode, the ВН59's three-byte acknowledge, the device wait); `korvet/tv80_*.v` (tv80, one line changed), `korvet/cpuz80.v` (the Z80 accelerator on the same bus) |
| the memory | `korvet/memmap.v` (generated: the PLM D31), `korvet/membus.v` (the SDRAM's CPU port: the RAM, a loaded ROM, the graphics RAM's three planes in one word, the write queue), `korvet/sdram.v` (the timetable), `korvet/opts_rom.v` (generated: the built-in ОПТС 2.0), `korvet/romload.v` (a ROM from the card into the SDRAM), `korvet/txtram.v` (the text RAM and the attribute flip-flop), `korvet/poke.v`, `korvet/memcheck.v` |
| the display | `korvet/video.v`, `korvet/font_rom.v` (generated: the character generator) |
| the devices | `korvet/ports.v` (the register page, the keyboard), `korvet/devices.v` (the device page), `korvet/ppi8255.v`, `pit8253.v`, `pic8259.v`, `i8251.v`, `korvet/fdc.v` + `wd1793.sv` (MiSTer's ВГ93), `korvet/mouse.v` (a serial mouse from the USB one), `korvet/extrom.v` (the ExtROM's connector side), `korvet/ay.v` + `ym2149.sv` (the AY module), `korvet/sd_arbiter.v` |
| clock, sound | `sys_pll.v` (rPLL by hand: 27 -> 40.5 MHz), `i2s_tx.v` |
| MiSTeryNano | `mister/{mcu_spi,sysctrl,hid,osd_u8g2,sd_card,sd_rw,sdcmd_ctrl,sector_dpram}.v` - PK8000 Nano's copies; `sysctrl.v` rewritten for this core's letters and the ExtROM channel |
| HDMI | `hdmi/{hdmi_tx,tmds_channel,hdmi_packet,hdmi_serdes}.v` - UKNC Nano's encoder with audio, at 40.5 MHz with four packets an island |

Stubbed in simulation (`tools/srcs.py`'s `STUBBED`): `sys_pll.v`,
`hdmi/hdmi_serdes.v`, the two generated ROMs and `mister/sector_dpram.v`
by `sim/stubs/gowin_ip_sim.v`; and `mister/sd_card.v` with `sd_rw.v` and
`sdcmd_ctrl.v` by `sim/stubs/sd_card_sim.v`, which serves image files
from the host on the same core-side interface (`+KDIA=`..`+KDID=`,
`+OPTS=`).

## Resources

Not built yet (`progress.md`).  The BSRAM budget on paper: the ОПТС 12
blocks, the font 4, the text RAM 1, the line buffer 1, memcheck 3, the
ExtROM's FIFOs 1, the OSD 1, the card's sector buffer 1, the ВГ93's
buffer 1, the ROM loader's 1 - 26 of 46.  The main RAM, a loaded ROM
and the graphics RAM are in the SDRAM.

## The clocks

```
clk27            27 MHz     the crystal, pin 4
  `- sys_pll (x3 / 2)
      |- clk           40.5 MHz  CLKOUT: everything
      `- O_sdram_clk   40.5 MHz  CLKOUTP, 90 degrees behind: the SDRAM pad only
  `- hdmi_ser/pll_hdmi (x5, referenced to clk)
      `- clk_serial   202.5 MHz  the four OSER10s
m0s[3]           20 MHz     the BL616's SPI clock, asynchronous, into mcu_spi.v
```

That is all of them.  Every flop of the design is on `clk`; the CPU's
T-state, the machine's pixel, the HDMI pixel, the timer's 2 MHz, the
mouse's 1200 baud and the I2S bit clock are phases or enables of it.
`korvet.sdc` declares `clk27`, `clk40` and `spi_clk`.  Why 40.5 and not
PK8000 Nano's 30: the 512-pixel line has to leave the chip as 1024 HDMI
pixels inside half a machine line, and 30 MHz gives 984 clocks for it;
27 x 3/2 is the nearest an rPLL gets to 40, an exact 40 needing a 1 MHz
phase detector below the part's floor.  The machine runs 1.25% fast
(2.53 MHz, 49.5 Hz); nothing in it counts real time.

## The timetable

A T-state of the CPU is sixteen clocks, `tphase` 0..15, cut into two
eight-clock SDRAM slots:

```
tphase   0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
         F1  |------ video slot ------|  F2  |------- CPU slot -------
             ACT RD  -   cap -   -   -   -    ACT RD/WR -  cap -   -   ...0
```

- `F1` (phase 0) and `F2` (phase 8) are the 8080's two clock phases as
  one-clock enables into vm80a.  Its SYNC and the status byte appear on
  the F2 edge, so at phase 9 `cpu8080.v` knows the cycle and the
  address, and that is the CPU slot's first clock: ACTIVE at 9, READ or
  WRITE at 10, the word captured at 12, in `rd_data` by 13 - long before
  the core samples the bus.  The Z80 (`cpuz80.v`) is enabled at phase 0
  (and 8 in turbo); a read or a write is asserted from T2 with the
  address latched at the request (WR/ from T2 is tv80s.v's T2Write = 1
  form, not its default T3: in turbo a T-state is eight clocks and T3
  alone need not contain phase 9), gets the same slot, and WAIT is held
  in T2 until the phase-9 strobe has gone out and the memory has
  answered - three clocks, so a cycle that begins at phase 0 in turbo
  costs one wait state and no other does.
- The video asks at phase 1 and has its word by phase 5: one 32-bit
  word a tile, the three planes of eight pixels, in the first of the
  tile's two T-states; the second T-state's slot is refresh's.
- Reads never wait for writes: `membus.v` queues the writes (four deep;
  a graphics write is a read-modify-write of two slots) and serves a
  read as it comes unless it is of a queued word (the hazard), in which
  case READY / WAIT holds the CPU until the queue has passed it.  The
  queue is also where the MCU's bytes (`poke.v`) go.
- Every access is ACTIVE, then READ or WRITE with auto-precharge (A10
  set, written at its own bit: PK8000 Nano's lesson), the read captured
  on slot clock 3 by the arithmetic in `sdram.v`'s header, with the
  self-test that moves it to clock 4 if a board says so.

## The memory map's users

`memmap.v` is the PLM D31 on the live address at the read strobe and on
the latched one at the write strobe.  A read goes to `membus.v` (the
RAM, the graphics RAM, or the loaded ROM), the built-in pROM, the
keyboard, the device page or the text RAM, and `rd_src` remembers which
of them the read in flight will answer from; `cpu_din` is that mux and
it is steady from phase 13 of T1.  A write goes to `membus.v`, the text
RAM, the device page or the register page.  The graphics word comes
back as three planes and `top.v` applies the colour register's read
arithmetic (`platform.md`) to make the byte.

The ROM: `opts_rom.v` (ОПТС 2.0 in twelve pROMs) unless `romload.v` has
copied an image from the card's slot 4 into the SDRAM's ROM region,
when `rom_loaded` sends ROM reads there instead.

## Reset

`sdram.v`'s `init` is the root: `hcnt`/`tphase` run from PLL lock, the
MiSTeryNano side waits 2^23 clocks after `init` (`por_done`, 207 ms)
and takes `mist_rst` until then, and the CPU is held by `cpu_rst` while
`mist_rst` or the OSD's 'R' bit 0 or `~init` or a ROM load is up and
for 16 T-states after.  The unselected processor is held in reset by
the OSD's 'c'.  The MCU sends R=3 at start and R=0 when it has sent the
settings, so the machine starts when the OSD's values are in.  S1
(`buts[0]`) resets everything.

## The SD path

`sd_card.v` (MiSTeryNano's) has one sector interface for the machine:
request levels `rstart[4:0]`/`wstart[4:0]` one-hot by image slot, the
sector within the image, then `rbusy`, the 512 bytes on
`outen/outaddr/outbyte` (or taken from `inbyte` at `outaddr` for a
write), and `rdone`.  Five clients share it through `sd_arbiter.v`:
slots 0..3 the four floppies (one ВГ93; its drive bits pick the slot),
slot 4 the ROM loader.  The ExtROM is NOT on this path: its images are
files the firmware reads through FatFs, and its bytes cross `sysctrl.v`.

## Pinout

The board as PK8000 Nano wires it, unchanged - `README.md` has the
table.  The SDRAM is in the package and its pins are the tool's, all 32
data lines used here.  The USB-C serial (pin 69) is driven idle.

## What is not there

The tape input and output as files, the printer (its data and strobe
go nowhere), the network ВВ51's line, a digital joystick on the ВВ55
#3's port B - and everything in `progress.md`.
