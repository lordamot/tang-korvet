# The ExtROM: the Korvet-EXTROM disk emulator

forth32's Korvet-EXTROM (`../korvet-extrom-forth32`, and its documents
in `infosource/extrom/`) is an ATmega32 on the Корвет's side connector
with an SD card: four virtual floppies from .kdi images on the card, a
fifth for its tools, and a way of booting a ПК8010 that has no floppy
controller at all.  Here the connector side is `tang/src/korvet/extrom.v`
and the ATmega's program is `mnano/extrom.c` on the BL616, with the
card's `extrom` folder as its root.

## How the machine sees it

1. After its tests the ОПТС raises Control (the ВВ55 #2's port C bit 7)
   and looks for it in the ВН59's request register - at **bit 0**,
   level 0, though the connector's pin and the ExtROM's documents call
   it IRQ7 (`platform.md`).  The controller's jumper connects the two;
   here `top.v` raises level 0 from Control while the OSD's ExtROM
   switch is on.
2. Seeing it, the ОПТС reads a cartridge ROM through the ВВ55 #3: port
   A in, ports B and C the address.  It reads bytes 4..7 of the header
   (the start address, the load address's high byte, the number of
   256-byte blocks), then the block three times (checksum, copy,
   checksum), and jumps.  `extrom.v` answers those reads from a 256-byte
   RAM the firmware loaded at start with STAGE1.ROM (or its built-in
   copy of it), at the address on port B while port C is 0.
3. The phase-1 loader (`loader/stage1/stage1.asm`) prints "BOOT:F500:",
   puts port A into mode 2 (control word C0h), reads the digit row of
   the keyboard and sends one byte - 8, or the digit held - and then
   reads a load address, a block count and the file.  From here on
   every byte crosses port A's mode-2 handshake: the machine's byte is
   in the output latch with OBF/ low until the device acknowledges;
   the device's byte is strobed into the input latch, IBF high until the
   machine reads it.  `extrom.v` acknowledges into a 1 K FIFO the MCU
   reads, and strobes bytes out of a 1 K FIFO the MCU fills.
4. The phase-2 loader (STAGE2.ROM; or ROMn.BIN for a held digit) loads
   the system tracks of drive A - from the image, or from SYSTEM.BIN /
   MICRODOS.BIN when the substitution mode is on - patches the BIOS with
   the ExtROM driver and starts CP/M.  The driver then speaks API v2:
   five-byte commands (command, drive, track, sector, checksum = the sum
   of the four minus one), a one-byte answer (1 ok, 0 fail), and data:
   128-byte sectors read and written, images mounted by name, folders,
   the tool disk unlocked, the substitution and the Control sense
   switched (`infosource/extrom/api_v2.odt`).

Control falling is the controller's only notion of a reset (the
connector has no reset line): the real one reboots on it, and so does
`extrom.c` when the core reports it (a program that drops Control loses
the disks on the real machine too; API command A1h switches that off).

## The card's folder

`/extrom` on the FAT32 card, the layout the controller's own card has
(`infosource/extrom/SD_ROOT`, and the sibling repository's `SD_ROOT`):

| file | what |
|---|---|
| `STAGE1.ROM` | the phase-1 loader, 256 bytes; the firmware has a copy built in for a card without it |
| `STAGE2.ROM` | the phase-2 loader (8 KB); the name the AVR firmware and the emulator patch use (the documents call it LOADER.BIN) |
| `ROM0.BIN`..`ROM7.BIN` | programs started instead by a digit held at boot; the ktdp diagnostics are the usual `ROM7.BIN` |
| `SYSTEM.BIN`, `MICRODOS.BIN` | the system tracks substituted for drive A's |
| `EXRTOOLS.KDI` | drive E: MOUNT, CONTROL, EUNLOCK |
| `MOUNT.CFG` | the mounts: four (folder, file) pairs of 14 bytes and the current folder; made with the defaults if missing |
| `DISK/` | the default folder of images: `DISKA.KDI`..`DISKD.KDI` are mounted at start |

Names are 8.3, upper case, one level of folders (the controller's
limits, kept here so that a card works on both).

## The firmware's side

`mnano/extrom.c` is Erokhin's `emu_patch/ext_rom.c` for the Etalon
emulator, function for function, on a small file layer that is FatFs
on the board and stdio on the host (`make extrom-test`, which builds a
card in a directory and walks the protocol: the phase-1 request, ping,
reads against the image, a write read back, mounting, the folder, the
substitution, creating an image, a reset).  The core's channel is
`sysctrl.v`'s CMD 8 (`sysctrl.c`'s `sys_extrom_*`): status (bytes
waiting, room, flags), read N, write, flush, load the ROM.  The core
raises interrupt bit 4 while bytes wait or Control has fallen, and
`sys_handle_interrupts` calls `extrom_handle_event`, which drains the
FIFO into the state machine and pushes the answers back in chunks of
64 with a status poll for room.

Throughput: a sector read is five bytes in, 129 out - one interrupt,
two SPI transactions at 20 MHz; the MCU's reaction is the FreeRTOS
wake, tens of microseconds.  The AVR did it at 8 MHz with a bit-banged
card.

## The testbench's side

`sim/tb/tb_top.v` has the controller's brain too, in Verilog tasks, so
the FPGA side can be exercised without the firmware: `+EXTROM` turns
the switch on and loads `+STAGE1=` (default `tang/rom/stage1.rom`);
`+STAGE2=` is sent when phase 1 asks; `+XA=`..`+XD=` are the images for
commands 1 and 2; `+XTRACE` prints every command.  Its sender credits
itself from the status's room byte and waits when the credit is spent,
as the firmware does: the tx FIFO drops what is pushed into it full,
and the phase-2 loader's 8 K goes to the machine a byte every few
dozen microseconds.  The run's last lines count the commands, the
sector reads and the writes.
