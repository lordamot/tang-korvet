# The BL616 firmware: `mnano/`

MiSTeryNano's firmware (Till Harbaum), as PK8000 Nano carried it, with
the ПК8000's parts taken out and the Корвет's put in.  The MCU does what
the FPGA cannot: USB host (keyboard, mouse, joysticks), the SD card's
file system, the on-screen menu, and it hands the FPGA its settings
over SPI.  New here, it is also the brain of the ExtROM disk emulator
(`extrom.c`, `.claude/docs/extrom.md`).  The FPGA side of every one of
these is under `tang/src/mister/`.

Built by `make fw` (`.claude/docs/build.md`); flashed by `make flash-mcu
COMX=/dev/ttyACM0`; the shipped binary is `bin/bl616.bin`.

## The core id

`sysctrl.v` answers CMD 0 with `5c 42 08`; 08 is `CORE_ID_KORVET` in
`sysctrl.h`, index 8 of every table the firmware selects by core:
`core_names[]` (sysctrl.c), `keymap[]` and `modifier[]` (usb_host.c),
`settings_file[]` (menu.c: `/sd/korvet.ini`), the forms and variables
(menu.c).  The other MiSTeryNano cores' tables are still there; the
UKNC's (5) and the PK8000's (7) are `NULL`.

## The keyboard

`mnano/korvet.h`: `keymap_korvet[]` indexed by USB HID usage,
`modifier_korvet[8]` by modifier bit.  A code is `KV(row, col) =
row*8 + col + 1` (1..64, the main matrix) or `KX(row, col) = 64 +
row*8 + col + 1` (65..88, the second field); 0 is `MISS`, a key the
machine does not have (F12 among them - it is the OSD's).  The generic
path in `usb_host.c` sends a press as the code and a release as
`0x80 | code` through HID CMD 1; `hid.v` hands the byte to `ports.v`
with a strobe, and the matrices live there.  No row tracking, no
pacing: the ОПТС scans the matrices and debounces.

The mapping is by key position: letters and digits as on the cap,
`=` is `^`, `'` is `:`, `` ` `` is `@`, F6 is `_`, F7 and Pause СТОП,
F8 and Caps Lock ФИКС, F9 СЕЛ, F10 and left Alt ГРФ, F11 and right Alt
АЛФ, Esc ПРФ, Ctrl УПР, the cursor keys and Home/End/PgUp/PgDn the
second field's keys, the keypad the same as on the Корвет's own (7 the
home-up-left, 9 the end-down-right, 5 МЕНЮ, `-` СТРН, `*` ВЗ, `/` ИЗ).
What a key types is the ОПТС's business.

## The mouse

The USB mouse's reports go to the core as they arrive (HID CMD 2:
buttons, dx, dy) and `mouse.v` makes a Microsoft serial mouse of them
on the ВВ51 #1.  Nothing to configure here but the OSD's switch.

## The menu

```
Korvet Nano                  Hardware
  Floppy A:   <file>           CPU:          VM80|Z80|Z80 5MHz          (c)  resets
  Floppy B:   <file>           OPTS ROM:     <file>                     (slot 4)
  Floppy C:   <file>           Floppy:       Off|On                     (f)
  Floppy D:   <file>           ExtROM:       Off|On                     (x)
  Reset              (R)       AY module:    Off|On                     (y)
  Hardware  >                  Mouse:        Off|On                     (M)
  About     >                  Graphics RAM: 192K|48K                   (m)  resets
  Debug     >                  Volume:       Mute|33%|66%|100%          (A)
  Save settings                Beeper:       Mute|On                    (b)
                               Floppy A..D prot.: Off|On                (p q k l)
```

The file entries are `sdc_image_open` slots: 0..3 the floppies (`.kdi`),
4 the ROM (`.rom`, `.bin`); `sd_card.v`'s `image_mounted` index is the
same number.  The letters are `sysctrl.v`'s CMD 4 ids, and a value
needs three edits: the letter in the form string, an entry in
`variables_korvet[]` (the default), and a case in `sysctrl.v`.  A
change of the CPU or the graphics RAM size sends R=1, R=0 after the
value, since both take effect at a reset.  "Save settings" writes
`/korvet.ini` on the card; at start every variable is sent once
(A b c f x y M m p q k l), then the ExtROM is initialised, then R 3 and
R 0.  The Hardware form scrolls; its return to the main form is by
form number.  The version at the right of the main form's caption is
the first line of `VERSION`, read by `CMakeLists.txt` into
`CORE_VERSION`.

"About" is a page of text (`about_korvet[]`); "Debug" is `memcheck.v`'s
32 bytes through CMD 7, formatted by `menu_debug_open` exactly as in
PK8000 Nano (`build.md`, "Reading the board").

`make menu-test` walks all of this on the host (`menu_test.c`) and
leaves each screen under `build/menu/` as text and PNG.  It is the only
way to see whether a label and its value fit the 128 pixels.

## The ExtROM

`extrom.c`, `extrom.h`: `extrom_init()` at the end of `menu_init()`
loads the phase-1 ROM into the core (`/sd/extrom/STAGE1.ROM`, or the
built-in copy), reads `MOUNT.CFG` and flushes the channel;
`extrom_handle_event()` runs from `sys_handle_interrupts()` on
interrupt bit 4.  The SPI side is `sysctrl.c`'s `sys_extrom_*` over
CMD 8.  `make extrom-test` runs the state machine on the host.  The
whole protocol is in `.claude/docs/extrom.md`.

## The SD card

The card is in the Tang's slot and `sd_card.v` reads it; the firmware's
FatFs goes through that module over SPI, and the floppy images go the
other way: a request from the FPGA is an interrupt, the MCU reads which
slot and which sector, translates it through the file's cluster map and
drives the card, and the bytes land in the FPGA (`fpga.md`, the SD
path).  Write protection is the FPGA's: the letters p, q, k, l reach
`fdc.v`.  The ExtROM's images are read and written by the MCU itself
through FatFs.

## The SPI link

Mode 1, 20 MHz, four targets by the first byte (0 SYS, 1 HID, 2 OSD, 3
SDC); `mcu_spi.v` takes it through a handshake into the 40.5 MHz domain.
`-DM0S_DOCK=1` picks the pinout in `spi.c` that matches the seven wires
in `README.md`.  UKNC Nano's `.claude/docs/mcu.md` has the byte-level
protocol of each target; this core adds SYS CMD 8.

## What was removed from PK8000 Nano's firmware (Sep 2026)

`pk8000.h`, `pk8000_tokens.h`, `bas.c/h` ("Run .bas" and its test), the
PK8000 forms and variables.  `git log --all` of `../tang-pk8000` has
them all.
