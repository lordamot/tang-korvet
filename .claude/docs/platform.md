# The machine: ПК8020 "Корвет"

The Корвет is the Soviet school computer of 1987-1988, designed at the
Institute of Nuclear Physics of Moscow State University and built in
Baku (ПК8010 for the pupils' seats, ПК8020 for the teacher's, with the
floppy controller, the printer port and RS-232 populated) and, as
clones, in other works (Контур, Нейва, БК-8Т).  A КР580ВМ80А (8080A) at
2.5 MHz, 64 KB of DRAM, a 512x256 display with a 64x16 text plane over
three bit-planes of graphics and a colour look-up table, 24 KB of ROM
(the ОПТС - the resident monitor and the boot loader - with BASIC), a
matrix keyboard the processor scans, a КР580ВИ53 timer, a КР580ВН59
interrupt controller, three КР580ВВ55А parallel adapters, two
КР580ВВ51А serial adapters, a КР1818ВГ93 floppy controller, and a
"side connector" with the third ВВ55 on it, which is where the
community's ExtROM disk emulator and AY sound module plug in.  Its
peculiarity: no I/O instructions are used at all - every device is in
the memory map, and the map itself is programmable through a PLM.

## What this design is built against

| source | what it is authority for |
|---|---|
| `infosource/techref/TEHREF-*.TXT` | the техническое описание: the synchroniser and its PLM (D40), the processor and the wait state on device access, the memory decode PLM (D31) and its fuse map, the RAM, the text controller and the attribute flip-flop, the graphics controller with its write mask and read compare (D88/D101), the floppy, the interrupt levels, the timer's clocks, the keyboard |
| `infosource/ПЛМ_v1.zip` (`D31.v`, `D88.v`, `CorD40V.v`) | the three PLMs as Verilog, from the 2022 board's EPM3032 replacements; D31 is what `memmap.v` is generated from |
| Emu80 `Korvet.cpp`, `korvet.conf`, `mapper.mem` | the graphics adapter's write and read arithmetic, the text adapter's attribute, the ВВ55 bits, the keyboard matrices, the AY on the ВВ55 #3, the raster's line positions, the device-page wait |
| MAME `pk8020.cpp` | the register decode in the register page (A7, A6, A2), the serial mouse on the ВВ51, the 8259 wiring, a second reading of the PLM |
| `../korvet-extrom-forth32` | the ExtROM controller: `.claude/docs/extrom.md` |

Where they disagree: MAME has VBL on port A bit 1 as 1 during blanking,
Emu80 and the техописание (VBL high for 28 of every 156 double-lines,
i.e. low during blanking) as 1 during the picture - the техописание
wins; Emu80 charges two wait states on a device access, the техописание
one (D24: `1READY = CSDEV | WAIT`, one TW) - the техописание wins.

## The memory map

The processor's 64 KB is decoded by the PLM D31 from the top eight
address bits, five bits of the system register (port 7Fh, bits 6..2,
written to any byte of the register page with A7 low) and the read and
write strobes.  Emu80's `mapper.mem` is the read side of the 32
configurations; `tools/decplm.py` runs the PLM's equations over all of
them and agrees with it on every page but the register page (which the
PLM reads as RAM and Emu80 as 0FFh).  The write side is the PLM's, and
it says two things worth knowing: a write under a ROM window goes to the
RAM beneath, and a write to the keyboard page too.

| 7Fh | 0000 | 2000 | 4000 | 6000-BFFF | C000-F7FF | F800 | FA00 | FB00 | FC00 |
|---|---|---|---|---|---|---|---|---|---|
| 00 | ROM1 | ROM2 (to 37FF), then KBD 3800, REG 3A00, DEV 3B00, TXT 3C00 | RAM | RAM | RAM | RAM | RAM | RAM | RAM |
| 04, 14, 44 | ROM1 | RAM | RAM | RAM | RAM | KBD | REG | DEV | TXT (04: no KBD/REG/DEV/TXT: all RAM) |
| 10, 18, 40, 48 | ROM1 | RAM / ROM2 (18, 48) / ROM2+ROM3 (40) | RAM | RAM | RAM | KBD | REG | DEV | TXT |
| 1C, 4C | RAM | RAM | RAM | RAM | RAM | KBD | REG | DEV | TXT |
| 20, 24, 28, 2C | ROM1 (20 as 00 with the 3800 devices) | .. | RAM | RAM | GZU (C000-FFFF) | | | | |
| 30-3C | ROM1 or RAM | RAM or ROM2 | GZU (4000-7FFF) | RAM | RAM | RAM | RAM (FE00 DEV, FF00 REG) | | |
| 50-5C | ROM1..ROM3 or RAM | | RAM | RAM | RAM | RAM | RAM | DEV FE00, REG FF00 | |
| 60-6C | ROM1..ROM3 or RAM | | RAM | RAM | GZU | | REG at BF00 | | |
| 70-7C | ROM1..ROM3 or RAM | | RAM | RAM | GZU | | | | |

`tools/decplm.py` prints the whole table, read and write, and
`infosource/korvet_configs.jpg` is the same picture by the machine's
own names (TRS80, ROMB1, ROMB2, ODOSA, NDOS, BASIC, BASG, DOSA, DOSG1).
After reset the register is 0: the ROM at 0000h, the devices at 3800h,
which is where the ОПТС starts.  CP/M runs in 1Ch (all RAM, the devices
at F800h); BASIC in 40h.

## The register page

Three write-only registers, picked by a low address bit since only the
top byte reaches the PLM (`ports.v`; MAME's `sysreg_w`):

| byte | bit low | register |
|---|---|---|
| 7Fh | A7 | the system register: bits 6..2 the configuration |
| BFh | A6 | the colour register (NCREG): bit 7 colour mode; bits 3..1 the planes written (colour mode: the colour; plane mode: the planes EXCLUDED); bit 0 plane mode's value; bits 6..4 the planes read (colour mode: the colour compared) |
| FBh | A2 | the colour table: bits 3..0 the entry, bits 7..4 its colour {I, R, G, B} |

## The graphics RAM (ГЗУ)

Three planes of 64 KB, each four pages of 16 KB; the processor sees one
page of one address space through the 16 KB window (C000h or 4000h),
the page for access chosen by the ВВ55 #1's port C bits 7:6 and the
page displayed by bits 1:0.  A byte's address within the page is
`line * 64 + column`, the bit order the pixel order.  A write is a mask
applied to all three planes at once (техописание §7; Emu80's
`writeByte`, MAME's `gzu_w` - the same):

- colour mode (NCREG bit 7 set): for plane n, the bits set in the data
  are set if NCREG bit 1+n is 1 and cleared if it is 0;
- plane mode: for every plane whose NCREG bit 1+n is 0, the bits set in
  the data are set if NCREG bit 0 is 1 and cleared if 0.

A read (D88/D101):

- colour mode: the OR over planes of (plane XOR NCREG bit 4+n) - a
  result bit of 0 means the pixel is the colour NCREG bits 6..4 name;
- plane mode: the OR of the planes whose NCREG bit 4+n is set.

Here the three planes of an address are one 32-bit SDRAM word
(`membus.v`), so a read is one access and a write a read-modify-write.
The OSD's "Graphics RAM: 48K" masks the page bits to 0 - a ПК8010 with
one page in each plane; Erokhin's emulator has the same switch.

## The text RAM (АЦЗУ)

1 K x 9 at FC00h: 64 x 16 characters and, in the ninth bit, inversion.
The ninth bit is written from the flip-flop D75, which port C bits 5:4
of the ВВ55 #1 control: 01 clears it (INVOFF), 10 sets it (INVON), 11
leaves it holding the bit the last READ of the text RAM latched, 00 is
forbidden (Emu80: the stored bit is left alone).  Port A bit 3 reads the
flip-flop.  Bit 2 of port C picks one of the two fonts in the 8 KB
character generator, bit 3 the 32-column mode (each character doubled,
the odd columns of the text RAM unused).

## The display

512 x 256 at 10 MHz, 656 pixel times a line (65.6 us), 312 lines a
frame (20.5 ms, 48.9 Hz); the picture on lines 40..295 (Emu80's
`renderLine`).  A pixel is four bits - the text plane's bit (glyph XOR
attribute) and the three planes' bits - through the 16-entry colour
table, whose entry {I, R, G, B} gives a component C0h or 00h, or FFh /
40h with the intensity bit (Emu80's palette).  VBL, the ВВ55 #1's port A
bit 1, is 1 while the picture is drawn and 0 through the 56 blanking
lines; its fall raises IRQ4 (through the edge-triggered ВН59).  HBL
clocks the timer's counter 2 once a line.  `video.md` has the raster
this design makes of it.

## The device page

256 bytes, the ИД7 D23 on A5..A3, so eight bytes a chip and the page
repeating every 64 (`devices.v`):

| offset | chip | notes |
|---|---|---|
| 00h-03h | ВИ53 timer | counter 0 the sound (2 MHz in, gated by the ВВ55 #2 port C bit 3), counter 1 the ВВ51 #1's clock (2 MHz in), counter 2 the interrupt timer (HBL in, out to IRQ5) |
| 08h-0Bh | ВВ55 #3 | the side connector: the ExtROM (port A mode 2, port C's upper half), the AY module (port A the data, port B bit 7 BDIR, bit 6 BC1), a digital joystick on port B on some machines (not here) |
| 10h-11h | ВВ51 #1 | RS-232 / current loop; the serial mouse |
| 18h-1Bh | ВГ93 | the floppy controller's four registers |
| 20h-21h | ВВ51 #2 | the classroom network, 19.2 kbit/s; nothing on the line here |
| 28h-29h | ВН59 | the interrupt controller |
| 30h-33h | ВВ55 #2 | A out: printer data; C out: bits 1:0 tape output (a two-bit DAC some programs play), bit 2 tape motor, bit 3 sound gate, bit 5 printer strobe, bit 7 Control (the ExtROM's start signal) |
| 38h-3Bh | ВВ55 #1 | A in: bit 0 tape input, bit 1 VBL, bit 2 printer busy, bit 3 the attribute flip-flop, bits 7:4 the network address (15 here); B out: bits 3:0 drive select, bit 4 side, bit 5 motor, bits 7:6 the floppy's clock and density; C out: the display (bits 7:6 the graphics page for access, 5:4 the attribute control, 3 the 32-column mode, 2 the font, 1:0 the graphics page shown) |

Every access to the page costs one wait state (техописание §3), which
`cpu8080.v` and `cpuz80.v` insert.

## The interrupts

The ВН59 in 8080 mode: a three-byte CALL, the vector from ICW1/ICW2.
Level 0 the expansion connector - and, through the ExtROM's jumper,
Control - 1 the ВВ51 #1's receiver, 2 its transmitter, 3 the ВВ51 #2's
receiver, 4 the frame (VBL's end), 5 the timer's counter 2, 6 the
printer (nothing), 7 the floppy motor's three-second time-out (the
one-shot's inverted output: high while the motor is off).  The ExtROM's
documents and the connector call Control's partner pin IRQ7, but the
ОПТС 2.0 tests **bit 0** of the ВН59's request register after raising
Control (korvet20.rom 04C0h-04CEh: bit 0 must be 0 with Control low
and 1 with it high), and Erokhin's emulator patch raises request 0;
the ROM wins.  A request bit follows its line - set by the edge,
cleared when the line goes low - as Emu80's Pic8259 and the datasheet
have it, so every source here is a level held until it is served.

## The keyboard

Two matrices the processor reads through the keyboard page (F800h):
with A8 low, each of A7..A0 selects a row of the main 8x8 matrix and
the byte is the OR of the selected rows, a pressed key a 1; with A8
high, A2..A0 select the three rows of the second field.  The rows are
Emu80's `KorvetKeyboard` (and `mnano/korvet.h`'s comment): letters and
symbols in the main field, the cursor and function keys in the second.
What a key types - the case of a letter, АЛФ for Cyrillic, ФИКС as a
lock - is the ОПТС's business; the ROM debounces across its scans, so
a key has to be down for a few frames to be seen (the testbench holds
70 ms).

## The floppy

A ВГ93 with the drive, side and motor from the ВВ55 #1's port B; four
drives; a disk is 80 cylinders x 2 sides x 5 sectors of 1024 bytes,
819200 bytes, which is what a .kdi holds (cylinder, side, sector).
CP/M sees 40 logical sectors of 128 bytes a track and two system
tracks (`tools/kdi.py` reads the parameters from the information
sector); the images in circulation (`infosource/`, `soft/`) are all of
that shape.

## The side connector and the ExtROM

The ВВ55 #3's three ports on a 37-pin connector, with Control and
the pin the ExtROM calls IRQ7 beside them.  The ОПТС raises Control
after its tests and, if it sees it come back at level 0 of the ВН59
(above), reads a cartridge ROM through port A with ports B and
C as the address and runs what it finds.  The Korvet-EXTROM is a
microcontroller on that connector that answers as a ROM with a 256-byte
loader and then talks to it through port A in mode 2: `extrom.md`.

## The processor's speed

2.5 MHz from the 20 MHz crystal (here 2.53 from 40.5 MHz).  No wait
states but the device page's one; the DRAM refresh is in the
synchroniser's spare cycles and never stalls the processor.  The Z80
accelerator (`infosource/links.txt`) is a Z80 in the ВМ80's place at
2.5 MHz or, on a switch, 5; it runs the 8080 code as it is, and the
ВН59's CALL works on it through IM 0.
