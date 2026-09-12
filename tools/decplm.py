#!/usr/bin/env python3
"""The Корвет's memory-configuration PLM (КР556РТ2, D31) as a table.

Two sources describe what the system register (port 7Fh) does to the
address space.  Emu80's `mapper.mem` (tang/rom/mapper.mem, also the
Etalon emulator's) is a lookup: for each of the 32 configurations and
each 256-byte page, which of nine things answers - RAM, ROM1, ROM2, ROM3,
the keyboard, the device page, the register page, the text RAM, the
graphics RAM.  It says nothing about writes.  The D31 equations here are
Славик's redraw of the PLM's fuse map for the 2022 board's EPM3032
replacement (infosource/ПЛМ_v1.zip, D31.v), sixteen inputs and eight
outputs, and they do: input 15 is the read strobe and input 13 the write
strobe (MAME's pk8020.cpp feeds the same fuse map that way, and its
bitswap gives the pin order used below).

  decplm.py            check the equations against mapper.mem on reads,
                       then print the read map and the WRITE map
  decplm.py -v         the whole table, one line a page
  decplm.py --verilog  write tang/src/korvet/memmap.v: the same equations
                       on the machine's signals (make memmap)

The outputs, as MAME reads them: Z0 ROM3, Z1 keyboard, Z2 ROM1, Z3 ROM2,
Z4 devices, Z5 system register (all active low); Z7:Z6 = 00 RAM,
01 graphics RAM, 10 text RAM, 11 nothing.  This is what memmap.v
implements; `make memmap` regenerates the Verilog table from here.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPPER = os.path.join(ROOT, "tang", "rom", "mapper.mem")

# D31.v, transcribed: each output is a sum of products over inputs A0..A15
# (the PLM's own input numbering), '~' the inverse.
Z = {}
Z[7] = "(A14)|(~A14&~A12&~A10&~A9&A8&~A7&A6&A5&A4&A3&~A2&~A1&~A0)|(~A14&~A11&~A10&A9&A8&A6&A5&A4&A3&A2&~A1&A0)|(~A14&~A11&A10&~A9&A8&A6&A5&A4&A3&A2&~A1&A0)|(~A14&A11&~A10&A9&A8&A6&~A5&A4&A3&A2&A1&A0)|(~A14&~A11&A10&A9&A8&A6&~A5&A4&A3&A2&A1&A0)|(~A14&~A13&~A12&~A10&~A9&A8&~A7&A6&~A4&A3&~A2&~A1&~A0)|(~A14&~A13&~A11&~A10&A9&A8&A6&~A4&A3&A2&~A1&A0)|(~A14&~A13&~A11&A10&~A9&A8&A6&~A4&A3&A2&~A1&A0)|(~A15&~A14&~A12&~A10&~A9&A8&~A7&A6&~A5&A4&A3&~A2&~A1&~A0)|(~A15&~A14&~A11&~A10&A9&A8&A6&~A5&A4&A3&A2&~A1&A0)|(~A15&~A14&~A11&A10&~A9&A8&A6&~A5&A4&A3&A2&~A1&A0)|(~A15&~A14&A11&A10&~A9&A8&A6&A5&A4&A3&A2&A1&~A0)|(~A15&~A14&A11&~A10&A9&A8&A6&A5&A4&A3&A2&A1&A0)|(~A15&~A14&~A11&A10&A9&A8&A6&A5&A4&A3&A2&A1&A0)|(~A14&~A12&~A10&~A9&A8&~A7&A6&A3&~A2&A1&~A0)|(~A14&~A11&~A10&A9&A8&A6&A3&A2&A1&A0)|(~A14&~A11&A10&~A9&A8&A6&A3&A2&A1&A0)|(~A15&A14)|(A15&~A14&~A12&~A6&~A2&~A0)|(A15&~A14&~A7&~A6&~A2&~A0)|(A15&~A14&~A12&~A10&~A9&~A8&~A7&A6&~A2&~A0)|(A15&~A14&~A12&~A10&~A9&A8&~A7&A6&~A3&~A2&~A0)|(A15&~A14&~A12&~A10&A7&A6&~A2&~A0)|(A15&~A14&~A12&A10&A6&~A2&~A0)|(A15&~A14&~A12&A10&~A7&~A6&~A2&A0)"
Z[6] = "(A14)|(~A14&~A12&~A10&~A9&A8&~A7&A6&A5&A4&A3&~A2&~A1&~A0)|(~A14&~A11&~A10&A9&A8&A6&A5&A4&A3&A2&~A1&A0)|(~A14&~A11&A10&~A9&A8&A6&A5&A4&A3&A2&~A1&A0)|(~A14&A11&~A10&A9&A8&A6&~A5&A4&A3&A2&A1&A0)|(~A14&~A11&A10&A9&A8&A6&~A5&A4&A3&A2&A1&A0)|(~A14&~A13&~A12&~A10&~A9&A8&~A7&A6&~A4&A3&~A2&~A1&~A0)|(~A14&~A13&~A11&~A10&A9&A8&A6&~A4&A3&A2&~A1&A0)|(~A14&~A13&~A11&A10&~A9&A8&A6&~A4&A3&A2&~A1&A0)|(~A15&~A14&~A12&~A10&~A9&A8&~A7&A6&~A5&A4&A3&~A2&~A1&~A0)|(~A15&~A14&~A11&~A10&A9&A8&A6&~A5&A4&A3&A2&~A1&A0)|(~A15&~A14&~A11&A10&~A9&A8&A6&~A5&A4&A3&A2&~A1&A0)|(~A15&~A14&A11&A10&~A9&A8&A6&A5&A4&A3&A2&A1&~A0)|(~A15&~A14&A11&~A10&A9&A8&A6&A5&A4&A3&A2&A1&A0)|(~A15&~A14&~A11&A10&A9&A8&A6&A5&A4&A3&A2&A1&A0)|(~A15&A14)|(~A14&A11&A10&A2&A0)|(~A14&A11&~A10&A9&~A2&A0)|(~A14&A11&~A9&A2&A0)|(A15&~A14&~A12&~A6&~A2&~A0)|(A15&~A14&~A7&~A6&~A2&~A0)|(A15&~A14&~A12&~A10&~A9&~A8&~A7&A6&~A2&~A0)|(A15&~A14&~A12&~A10&~A9&A8&~A7&A6&~A3&~A2&~A0)|(A15&~A14&~A12&~A10&A7&A6&~A2&~A0)|(A15&~A14&~A12&A10&A6&~A2&~A0)|(A15&~A14&~A12&A10&~A7&~A6&~A2&A0)"
Z[5] = "~((~A15&~A14&~A12&~A10&~A9&A8&~A7&A6&~A5&A4&A3&~A2&~A1&~A0)|(~A15&~A14&~A11&~A10&A9&A8&A6&~A5&A4&A3&A2&~A1&A0)|(~A15&~A14&~A11&A10&~A9&A8&A6&~A5&A4&A3&A2&~A1&A0)|(~A15&~A14&A11&A10&~A9&A8&A6&A5&A4&A3&A2&A1&~A0)|(~A15&~A14&A11&~A10&A9&A8&A6&A5&A4&A3&A2&A1&A0)|(~A15&~A14&~A11&A10&A9&A8&A6&A5&A4&A3&A2&A1&A0)|(~A15&A14))"
Z[4] = "~((A14)|(~A14&~A12&~A10&~A9&A8&~A7&A6&A5&A4&A3&~A2&~A1&~A0)|(~A14&~A11&~A10&A9&A8&A6&A5&A4&A3&A2&~A1&A0)|(~A14&~A11&A10&~A9&A8&A6&A5&A4&A3&A2&~A1&A0)|(~A14&A11&~A10&A9&A8&A6&~A5&A4&A3&A2&A1&A0)|(~A14&~A11&A10&A9&A8&A6&~A5&A4&A3&A2&A1&A0))"
Z[3] = "~((A15&~A14&~A12&~A10&~A9&~A8&~A7&A6&~A2&~A0)|(A15&~A14&~A12&~A10&~A9&A8&~A7&A6&~A3&~A2&~A0)|(A15&~A14&~A12&~A10&A7&A6&~A2&~A0)|(A15&~A14&~A12&A10&A6&~A2&~A0))"
Z[2] = "~((A15&~A14&~A12&~A6&~A2&~A0)|(A15&~A14&~A7&~A6&~A2&~A0))"
Z[1] = "~((~A14&~A13&~A12&~A10&~A9&A8&~A7&A6&~A4&A3&~A2&~A1&~A0)|(~A14&~A13&~A11&~A10&A9&A8&A6&~A4&A3&A2&~A1&A0)|(~A14&~A13&~A11&A10&~A9&A8&A6&~A4&A3&A2&~A1&A0))"
Z[0] = "~(A15&~A14&~A12&A10&~A7&~A6&~A2&A0)"

def plm(inputs):
    env = {f"A{i}": bool(inputs >> i & 1) for i in range(16)}
    out = 0
    for k, e in Z.items():
        v = eval(e.replace("~", " not ").replace("&", " and ").replace("|", " or "), {}, env)
        if v: out |= 1 << k
    return out

# MAME: bitswap<13>((addr & 0xff00) | bank, 2,5,6,4,12,3,13,8,9,11,15,10,14) | 0x8000 (read) / 0x2000 (write).
# bitswap's first argument lands in the result's bit 12.  So PLM input k
# (k = 0..12) is bit SRC[k] of {addr, bank}: bank bits 2..6 are the five
# system-register bits (7Fh bits 2..6), addr bits 8..15 are A8..A15.
SRC = [14, 10, 15, 11, 9, 8, 13, 3, 12, 4, 6, 5, 2]

def plm_inputs(cfg, a_hi, rd, wr):
    src = (a_hi << 8) | (cfg << 2)
    v = 0
    for k, b in enumerate(SRC):
        if src >> b & 1: v |= 1 << k
    if rd: v |= 1 << 15
    if wr: v |= 1 << 13
    return v

NAMES = {0: "RAM", 1: "ROM1", 2: "ROM2", 3: "ROM3", 4: "KBD", 5: "DEV", 6: "REG", 7: "TXT", 8: "GZU"}

def decode(sel, wr):
    """MAME memory_r/memory_w's reading of the eight outputs, as a page id."""
    things = []
    if not sel & 4: things.append(1)
    if not sel & 8: things.append(2)
    if not sel & 1: things.append(3)
    if not wr and not sel & 2: things.append(4)
    if wr and not sel & 32: things.append(6)
    if not sel & 16: things.append(5)
    mem = sel >> 6 & 3
    if mem == 0: things.append(0)
    if mem == 1: things.append(8)
    if mem == 2: things.append(7)
    return things

# PLM input k, as the machine wires it (MAME's bitswap, above; input 14 is
# the interrupt-acknowledge flop D15, which this design handles in
# cpu8080.v and ties low here)
PIN = {0: "a[14]", 1: "a[10]", 2: "a[15]", 3: "a[11]", 4: "a[9]", 5: "a[8]", 6: "a[13]",
       7: "sr[3]", 8: "a[12]", 9: "sr[4]", 10: "sr[6]", 11: "sr[5]", 12: "sr[2]",
       13: "wr", 14: "1'b0", 15: "rd"}

def verilog():
    out = ["`timescale 1ns / 1ps",
           "//========================================================================",
           "// memmap.v - the Корвет's memory-configuration PLM (КР556РТ2, D31).",
           "//",
           "// GENERATED by tools/decplm.py --verilog (make memmap) - do not edit.",
           "// The equations are the PLM's fuse map as Славик redrew it for the 2022",
           "// board's EPM3032 (infosource/ПЛМ_v1.zip, D31.v), on the pins MAME's",
           "// pk8020.cpp feeds the same map through: the top eight address bits,",
           "// the five system-register bits (port 7Fh, bits 2..6), the read strobe",
           "// on input 15 and the write strobe on input 13.  tools/decplm.py checks",
           "// them against Emu80's mapper.mem on every read of every configuration.",
           "//",
           "// The outputs, active low but for the top pair:",
           "//   z[0] ROM3 (4000h-5FFFh)   z[1] the keyboard   z[2] ROM1   z[3] ROM2",
           "//   z[4] the device page      z[5] the system-register page (writes)",
           "//   z[7:6] 00 RAM, 01 the graphics RAM, 10 the text RAM, 11 nothing",
           "// A read under a ROM window gives the ROM and no RAM; a write there",
           "// gives the RAM under it.  The keyboard and register pages read as RAM",
           "// where the PLM says so, and Emu80 says 0FFh; platform.md has the table.",
           "//========================================================================",
           "module memmap (",
           "    input  [15:8] a,        // the address, top byte",
           "    input  [6:2]  sr,       // the system register, port 7Fh bits 6..2",
           "    input         rd,",
           "    input         wr,",
           "    output [7:0]  z",
           ");", ""]
    for k in range(8):
        e = Z[k]
        for i in range(15, -1, -1):
            e = e.replace(f"~A{i}", f"~{PIN[i]}").replace(f"A{i}", PIN[i])
        # tidy the constant input away for readability
        e = e.replace("~1'b0", "1'b1")
        out.append(f"assign z[{k}] = {e};")
        out.append("")
    out.append("endmodule")
    path = os.path.join(ROOT, "tang", "src", "korvet", "memmap.v")
    open(path, "w").write("\n".join(out) + "\n")
    print(f"wrote {path}")

def main():
    if "--verilog" in sys.argv:
        verilog(); return 0
    verbose = "-v" in sys.argv
    mm = open(MAPPER, "rb").read()
    bad = 0
    for cfg in range(32):
        for pg in range(256):
            want = mm[(cfg << 8) | pg]
            got = decode(plm(plm_inputs(cfg, pg, 1, 0)), 0)
            # the register page answers reads with nothing (Emu80: 0FFh); the
            # PLM's Z5 is a write strobe, so a read there decodes as empty
            wgot = got[0] if got else 6
            if wgot != want and not (want == 6 and got == []):
                bad += 1
                if bad < 20:
                    print(f"cfg {cfg:2d} page {pg:02X}: mapper says {NAMES[want]}, the PLM says {[NAMES[t] for t in got]}")
    print(f"reads: {bad} pages differ from mapper.mem")
    print()
    print("cfg  7F  read map (Emu80 = the PLM) / write map (the PLM)")
    for cfg in range(32):
        rd = [decode(plm(plm_inputs(cfg, pg, 1, 0)), 0) for pg in range(256)]
        wr = [decode(plm(plm_inputs(cfg, pg, 0, 1)), 1) for pg in range(256)]
        def runs(tbl):
            out = []; s = 0
            for i in range(1, 257):
                if i == 256 or tbl[i] != tbl[s]:
                    out.append((s, i - 1, tbl[s])); s = i
            return out
        def fmt(r):
            return "  ".join(f"{a:02X}-{b:02X}:{'+'.join(NAMES[t] for t in v) or '-'}" for a, b, v in r)
        print(f"{cfg:2d}  {cfg<<2:02X}  R: {fmt(runs(rd))}")
        print(f"        W: {fmt(runs(wr))}")
        if verbose:
            for pg in range(256):
                print(f"      {pg:02X}: rd {rd[pg]} wr {wr[pg]} sel {plm(plm_inputs(cfg, pg, 1, 0)):02X}/{plm(plm_inputs(cfg, pg, 0, 1)):02X}")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
