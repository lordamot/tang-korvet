# Korvet Nano - how to

The short form.  `README.md` has the wiring and the flashing; the long
form of everything is under `.claude/docs/`.

## 1. What you get

A ПК8020 Корвет that starts into its ОПТС - nine seconds of memory
test on a blue screen - and then into CP/M from a disk, into the ExtROM's
loader, or into BASIC, on HDMI at 1024x512 (the machine's 49.5 Hz), with
a USB keyboard and a USB mouse on the BL616, and the piezo and the AY
module over HDMI and the dock's I2S output.  Software comes in from the
SD card: `.kdi` floppies through the ВГ93, the whole card's `extrom`
folder through the Korvet-EXTROM, a ROM image in place of the ОПТС.
Not on a board yet (5 Sep 2026).

## 2. The keyboard

The machine's keyboard is two matrices and the USB keyboard is mapped
onto them by position (`mnano/korvet.h`).  The whole layout, Корвет key
first:

| Корвет key | PC key |
|---|---|
| `0` .. `9` | the digits |
| `A` .. `Z` | the letters |
| `@` | `` ` `` |
| `[` `]` `\` | `[` `]` `\` (and the ISO key next to Enter) |
| `^` | `=` |
| `_` | F6 |
| `:` | `'` |
| `;` `,` `-` `.` `/` | `;` `,` `-` `.` `/` |
| РГ (Shift) | Shift (left is the left РГ, right the right) |
| УПР (Ctrl) | Ctrl |
| ГРФ (Graph) | left Alt, F10 |
| АЛФ (Cyrillic/Latin) | right Alt, F11 |
| ФИКС (Caps) | Caps Lock, F8 |
| ПРФ | Esc |
| СЕЛ | F9 |
| СТОП | F7, Pause |
| ВК (Enter) | Enter, keypad Enter |
| ЗБ (Backspace) | Backspace |
| ТАБ | Tab |
| ВЗ (Insert) | Insert, keypad `*` |
| ИЗ (Delete) | Delete, keypad `/` |
| СТРН (Clear) | keypad `-` |
| ← ↑ ↓ → | the cursor keys; keypad 4, 8, 2, 6 |
| home-up-left | keypad 7 |
| end-down-right | keypad 9 |
| home | Home, keypad 1 |
| end | End, keypad 3 |
| page-home | PgUp, keypad 0 |
| page-end | PgDn, keypad `.` |
| МЕНЮ | keypad 5 |
| F1 .. F5 | F1 .. F5 |
| (the menu) | F12 - never reaches the machine |

What the keys type - the case, the Cyrillic under АЛФ, the symbols
under РГ - is the ОПТС's business and the machine's own layout, not the
PC's.

## 3. The mouse

A USB mouse is a Microsoft serial mouse on the RS-232 port (the ВВ51
#1), which is what the Корвет's mouse programs (Абрис, Спред) expect:
1200 baud, three-byte reports, the "M" when the port raises RTS.
"Mouse: On" in the menu (the default); "Off" leaves the port silent.

## 4. The menu

F12.  Cursor keys move, left/right step a value, Space or Enter selects,
Esc closes.

- **Floppy A..D** - the image slots on the card (`.kdi`).
- **Reset** - the machine restarts.
- **Hardware** - **CPU** (VM80 / Z80 / Z80 5MHz; a change restarts the
  machine); **OPTS ROM** (a ROM image from the card, up to 32 KB, in
  place of the built-in ОПТС 2.0; "No Disk" is the built-in one);
  **Floppy** (the ВГ93 controller); **ExtROM** (the Korvet-EXTROM on the
  side connector, section 5); **AY module** (the AY-3-8910 on the same
  connector, Emu80's wiring); **Mouse**; **Graphics RAM** (192K, four
  pages, or 48K, one - a change restarts); Volume (Mute / 33% / 66% /
  100%); Beeper (Mute / On); write protection for the four floppies.
- **About**, **Debug** (what the memory gave the CPU - for when it does
  not start, `.claude/docs/build.md`).
- **Save settings** - writes `/korvet.ini` on the card; loaded at power-up.

## 5. The ExtROM

With "ExtROM: On" the ОПТС, after its tests, finds the cartridge and
runs its loader: "BOOT:F500:" at the top left, then the phase-2 loader
from the card's `extrom/STAGE2.ROM`, then CP/M from `extrom/DISK/DISKA.KDI`
with its system tracks from `extrom/SYSTEM.BIN`, and the A> prompt with
the ExtROM driver in the BIOS.  From there `MOUNT` (on drive E, the
tools disk `extrom/EXRTOOLS.KDI`) shows and changes what A..D are:
`MOUNT C ABRIS` mounts `ABRIS.KDI` from the current folder on C,
`MOUNT /L` lists the folder, `MOUNT /F GAMES` changes the folder,
`MOUNT /R` mounts read-only, `MOUNT /P` makes it permanent
(`extrom/MOUNT.CFG`), `MOUNT /C D NEW` creates a blank image.  A digit
held at boot starts `extrom/ROMn.BIN` instead of the loader (7 is the
КТДП diagnostics on a real card).  The whole protocol and the folder:
`.claude/docs/extrom.md`.

The ExtROM and the ВГ93 can both be on: the ОПТС boots the ExtROM way
when it sees it, and CP/M's C and D can still be the real drives (its
`MOUNT B $0` maps a drive letter to the ВГ93's drive 0).

## 6. If it does not start

- No picture at all: the monitor may not take 1024x512 at 49.5 Hz -
  try another; and check the seven wires (`README.md`).
- The blue screen for ever, or the ОПТС saying a memory is faulty:
  the SDRAM.  This is the one thing simulation cannot vouch for; the
  Debug page says what the CPU read.
- The picture but no keys: the BL616 is not talking - its firmware, the
  wires, or the card missing (the firmware still runs without one).
- Flashing: replug, flash, power-cycle, in that order
  (`.claude/docs/build.md`).
