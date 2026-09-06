# Tools and ROM data

The toolchain is fetched into `tools/` and driven from the `Makefile`;
`.claude/docs/build.md` says what builds here.  Beside it there is a
handful of small scripts, all committed (force-added past the `/tools/`
ignore line), and the ROM data under `tang/rom/`.

## `tools/`

| script | what |
|---|---|
| `fetch.sh` | fetches the toolchain (oss-cad-suite, CMake, Ninja, the RISC-V GCC, the Bouffalo SDK, Gowin EDA Education, gh), patches the SDK's host-tool selection, shadows Gowin's stale bundled libraries.  UKNC Nano's |
| `env.sh` | puts the same set on `PATH` for use by hand |
| `srcs.py` | prints the design's source list out of `tang/korvet.gprj`; `--ip` the stubbed files, `--cst`, `--sdc` |
| `gowin_tcl.py` | emits `tang/build.tcl` for `gw_sh`, from the same `.gprj` and the IDE's process config |
| `timing_check.py` | the timing gate (`.claude/rules/timing.md`) |
| `bin2prom.py` | a flat binary -> a Verilog module of Gowin pROM primitives (1024 x 16 each), registered output; `make rom` runs it for the ОПТС and the font |
| `decplm.py` | the PLM D31's equations: checks them against Emu80's `mapper.mem` on every read, prints the read and write maps, and `--verilog` writes `tang/src/korvet/memmap.v` (`make memmap`) |
| `kdi.py` | lists, extracts and adds CP/M files on a .kdi, reading the disk parameters from its information sector |
| `mif.py` | flat binary <-> `.mif` <-> `$readmemh` hex; `binhex` makes the sim models' images |
| `ppm2png.py` | the simulation's `.ppm` frames as PNG (`-s 2` scales down) |
| `osd_png.py` | the OSD test's text dumps -> PNG |
| `sdk-host-tools.patch` | the Bouffalo SDK's `cmake/bflb_flash.cmake` fix, applied at fetch |

`bin2prom.py` packs little-endian 16-bit words, so byte 2n is the low
half of word n and `top.v` picks the byte by the address's bit 0; the
sim models (`opts_rom`, `font_rom` in `sim/stubs/gowin_ip_sim.v`) read
`mif.py binhex`'s hex, which is the same layout.

## `tang/rom/`

| file | what |
|---|---|
| `korvet20.rom` | 24576 bytes: ОПТС 2.0 with BASIC (Moscow, 1988), the built-in ROM.  Emu80's `rom1/2/3.bin`, the three 8 KB chips D34, D33, D32; `infosource/roms/rom-2023/korvet20.rom` less its two trailing FFh bytes; `OPTS2_0.zip`'s 002-004.BIN |
| `korvet11.rom` | 24576 bytes: ОПТС 1.1 with BASIC 1.1 (1986), the "first Корвет"; Emu80's `rom11/12/13.bin`.  Not built in: put it on the card and choose it as the OPTS ROM |
| `korvet2.fnt` | 8192 bytes: the character generator D59, two fonts of 256 characters of 16 lines; Emu80's `font.bin`.  `OPTS2_0.zip`'s `001.BIN` is the same first font with a different second one |
| `stage1.rom` | 256 bytes: the ExtROM's phase-1 loader (`korvet-extrom-forth32`, `SD_ROOT/STAGE1.ROM`), what the core serves as the cartridge |
| `mapper.mem` | 8192 bytes: Emu80's (and the Etalon emulator's) memory table, 32 configurations x 256 pages; `decplm.py`'s reference |

The техописание, the album of schematics (.djvu), the PLM projects and
the ExtROM's documents stay in `infosource/`, which is the operator's
folder and not part of the build.

## `soft/`

| file | what |
|---|---|
| `disk.kdi` | a games disk from the Korvet v0.9 emulator's distribution (36 programs, two system tracks), the one the simulation boots from |
| `ktdp.kdi` | the КТДП diagnostics (TDP.COM and a font), from micklab's collection |

`tools/kdi.py -l` lists either.
