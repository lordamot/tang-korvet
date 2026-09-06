# The display

`tang/src/korvet/video.v`, with `txtram.v` and `font_rom.v` beside it.
The machine's side is in `platform.md`; this is what the design makes
of it.

## The machine's raster, in clocks

At 40.5 MHz a pixel is four clocks and a line 2624 (164 T-states):

```
hcnt      0..31    the fetch of tile 0 (T-states 0 and 1)
         32..2079  the 512 pixels: tile t shown at 32(t+1)..32(t+1)+31,
                   fetched during 32t..32t+31
       2080..2623  blanking (hbl_tick at 2080: the timer's counter 2)
vcnt      0..39    blanking (VBL low)
         40..295   the 256 picture lines (VBL high)
        296..311   blanking
```

Emu80 draws lines 40..295 too, with a 64 us line; MAME and the
техописание have 65.6 us, which is what the counters here make (82
T-states of 8 pixels).  There is no border: the machine's blanking is
black on a monitor and the HDMI frame carries the picture only.

## A tile

Eight pixels are two T-states.  On the first clock of a tile's period
the graphics word is asked for (the request is registered so that it is
UP on phase 1, the video slot's first clock - PK8000 Nano's lesson) and
the text RAM is addressed with the row and the column (the even column
in the 32-column mode); on clock 2 the character and its attribute are
latched and the font addressed with {font, character, line}; on clock 6
the glyph is there (the pROM's registered word, the byte picked by a
registered address bit) and the graphics word has been back since
clock 5; on the last clock the glyph, inverted by the attribute and
doubled for the wide mode (Emu80's `bt3` arithmetic), is handed over
with the three plane bytes to the shift registers.

Each pixel then takes the four top bits, {text, plane 2, plane 1,
plane 0}, through the colour table and puts the entry - four bits
{I, R, G, B} - into the line buffer.  The table is written from the
register page at any time; the write lands in the entry and shows from
the next pixel that reads it, which is close enough to the machine
(where the table is a RAM in the video path).

## The output raster

Two lines of 512 four-bit entries: the one being drawn and the one
being shown.  The HDMI side reads the shown line back twice, so every
machine line is two output lines of 1312 clocks (32.4 us) with 1024
active pixels, each machine pixel twice: a 1024 x 512 picture in a
1312 x 624 frame at 30.9 kHz and 48.9 Hz (49.5 with the 1.25%).

```
out_h 0..1311 : DE 0..1023, front porch 1024..1047, HSYNC 1048..1111 (64),
                back porch 1112..1311 (200: hdmi_tx.v's island with four
                packets needs 4+8+2+128+2 and the video preamble's 10)
out_v 0..623  : VSYNC 8..13, DE 82..593 (the line drawn at vcnt 40 is
                read out at vcnt 41; out_v = {vcnt, second half})
```

Not a CEA mode.  PK8000 Nano's 768x576 at 50.73 Hz was taken by the
sinks it met; whether a given one takes 1024x512 at 49.5 Hz is a board
question, and a black screen on a board is that before it is anything
else.  The OSD centres itself on the syncs and needs no change.

Colours: a component is C0h when its bit is set and 00h when not, or
FFh / 40h with the intensity bit - Emu80's palette, MAME's within a
shade.

## Audio in the HDMI stream

`hdmi_tx.v` resamples the mix to exactly 48 kHz with N = 6144 and
CTS = 40500 (40.5e6 x 6144 / (128 x 40500) = 48000) and sends the clock
regeneration packet at that ratio, so the rate the sink regenerates and
the rate delivered agree to the bit.  Four packets an island fit the
200-clock back porch; `DI_PKTS` is 4 again (PK8000 Nano had to send
three in its 144).
