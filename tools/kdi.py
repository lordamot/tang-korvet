#!/usr/bin/env python3
"""List, extract and add files on a Корвет floppy image (.kdi).

A .kdi is 819200 bytes: 80 cylinders x 2 sides x 5 sectors x 1024 bytes,
cylinder-side-sector order - the same geometry as the Сура's .fdd, which
is why the core's ВГ93 (fdc.v, wd1793.sv) takes both.  The first sector
is the information sector the ОПТС and the ExtROM read (offset 16: the
128-byte logical sectors a track, 40; offset 0x1E: the system tracks),
and the CP/M disk parameters after it are read here rather than assumed:
block size 2 KB, 128 directory entries, two system tracks of 5 KB each
on a standard disk (the directory at 2800h), with 16-bit allocation
numbers and eight to an extent.

    kdi.py -l disk.kdi                    list the directory
    kdi.py -x disk.kdi NAME [outdir]      extract a file (all with '*')
    kdi.py out.kdi base.kdi FILE...       copy base.kdi, add the files
    kdi.py out.kdi - FILE...              a blank data disk with them

Names are the host file names, upper-cased to 8.3.  A file already on
the disk with that name is replaced.  The DPB decode follows CP/M 2.2's
layout of the parameter block the information sector carries at 0x20;
a disk whose block size is not 2 KB is refused.
"""
import os, sys

SIZE = 819200
INFO = 0x20          # the DPB in the information sector (Emu80's FdImage, the ExtROM's create)


def dpb(img):
    """(spt, bsh, blm, exm, dsm, drm, off) from the information sector."""
    d = img[INFO:INFO + 16]
    spt = d[0] | d[1] << 8
    bsh, blm, exm = d[2], d[3], d[4]
    dsm = d[5] | d[6] << 8
    drm = d[7] | d[8] << 8
    off = d[13] | d[14] << 8
    if spt == 0 or bsh == 0:
        # no parameters: the standard disk
        spt, bsh, blm, exm, dsm, drm, off = 40, 4, 15, 0, 0x18A, 0x7F, 2
    return spt, bsh, blm, exm, dsm, drm, off


class Disk:
    def __init__(self, img):
        self.img = img
        self.spt, self.bsh, self.blm, self.exm, self.dsm, self.drm, self.off = dpb(img)
        self.bs = 128 << self.bsh
        if self.bs != 2048:
            sys.exit(f"kdi: a block of {self.bs} bytes is not the {2048} this tool knows")
        self.dir = self.off * self.spt * 128
        self.nent = self.drm + 1
        self.dirblks = (self.nent * 32 + self.bs - 1) // self.bs
        self.nblk = self.dsm + 1

    def entry(self, i):
        o = self.dir + i * 32
        return self.img[o:o + 32]

    def blk(self, b):
        return self.dir + b * self.bs

    def used(self):
        u = set(range(self.dirblks))
        for i in range(self.nent):
            e = self.entry(i)
            if e[0] <= 15:
                for k in range(8):
                    b = e[16 + 2 * k] | e[17 + 2 * k] << 8
                    if b:
                        u.add(b)
        return u


def ent_name(e):
    return (bytes(c & 0x7F for c in e[1:9]).decode("ascii", "replace").rstrip() + "." +
            bytes(c & 0x7F for c in e[9:12]).decode("ascii", "replace").rstrip()).rstrip(".")


def files(dk):
    out = {}
    for i in range(dk.nent):
        e = dk.entry(i)
        if e[0] <= 15:
            n = ent_name(e)
            ex = e[12] | (e[14] << 5)
            out.setdefault(n, []).append((ex, e))
    return out


def listing(dk):
    fl = files(dk)
    for n in sorted(fl):
        ents = fl[n]
        size = max(ex * 16384 + e[15] * 128 for ex, e in ents)
        print(f"{size:7d}  {n}")
    print(f"{len(fl)} files, {len(dk.used()) - dk.dirblks} of {dk.nblk - dk.dirblks} blocks used, "
          f"{dk.spt} logical sectors a track, {dk.off} system tracks")


def extract(dk, name, outdir):
    fl = files(dk)
    names = list(fl) if name == "*" else [name.upper()]
    for n in names:
        if n not in fl:
            sys.exit(f"kdi: no {n}")
        data = bytearray()
        for ex, e in sorted(fl[n]):
            recs = e[15]
            for k in range(8):
                b = e[16 + 2 * k] | e[17 + 2 * k] << 8
                if not b:
                    break
                take = min(recs, 16) * 128
                data += dk.img[dk.blk(b):dk.blk(b) + take]
                recs -= min(recs, 16)
        open(os.path.join(outdir, n), "wb").write(data)
        print(f"{n}: {len(data)} bytes")


def cpm_name(path):
    base = os.path.basename(path).upper()
    name, _, ext = base.partition(".")
    return name[:8].ljust(8).encode("ascii"), ext[:3].ljust(3).encode("ascii")


def delete(dk, name8, ext3):
    for i in range(dk.nent):
        o = dk.dir + i * 32
        if dk.img[o] <= 15 and dk.img[o + 1:o + 9] == name8 and dk.img[o + 9:o + 12] == ext3:
            dk.img[o] = 0xE5


def add(dk, path):
    name8, ext3 = cpm_name(path)
    data = open(path, "rb").read()
    delete(dk, name8, ext3)
    used = dk.used()
    free = [b for b in range(dk.dirblks, dk.nblk) if b not in used]
    nblocks = (len(data) + dk.bs - 1) // dk.bs
    if nblocks > len(free):
        sys.exit(f"kdi: no room for {path}")
    blocks = free[:nblocks]
    for b, i in zip(blocks, range(0, len(data), dk.bs)):
        chunk = data[i:i + dk.bs]
        dk.img[dk.blk(b):dk.blk(b) + len(chunk)] = chunk
    slots = [dk.dir + i * 32 for i in range(dk.nent)
             if dk.img[dk.dir + i * 32] == 0xE5 or dk.img[dk.dir + i * 32] > 15]
    nrec = (len(data) + 127) // 128
    for ex in range((nblocks + 7) // 8 or 1):
        if not slots:
            sys.exit("kdi: the directory is full")
        o = slots.pop(0)
        e = bytearray(32)
        e[1:9] = name8
        e[9:12] = ext3
        e[12] = ex & 0x1F
        e[14] = ex >> 5
        recs = nrec - ex * 128
        e[15] = 128 if recs > 128 else max(recs, 0)
        for i, b in enumerate(blocks[ex * 8:ex * 8 + 8]):
            e[16 + 2 * i] = b & 0xFF
            e[17 + 2 * i] = b >> 8
        dk.img[o:o + 32] = e
    print(f"{path}: {len(data)} bytes in {nblocks} block(s)")


# the information sector of a standard 800 K disk (the ExtROM's create)
INFOSECTOR = bytes([
    0x80, 0xc3, 0x00, 0xda, 0x0a, 0x00, 0x00, 0x01, 0x01, 0x01, 0x03, 0x01, 0x05, 0x00, 0x50, 0x00,
    0x28, 0x00, 0x04, 0x0f, 0x00, 0x8a, 0x01, 0x7f, 0x00, 0xc0, 0x00, 0x20, 0x00, 0x02, 0x00, 0x10])


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == "-l":
        listing(Disk(bytearray(open(a[1], "rb").read())))
        return
    if a[0] == "-x":
        extract(Disk(bytearray(open(a[1], "rb").read())), a[2], a[3] if len(a) > 3 else ".")
        return
    out, base, fl = a[0], a[1], a[2:]
    if base == "-":
        img = bytearray(b"\xE5" * SIZE)
        img[0:INFO + 32] = b"\0" * INFO + INFOSECTOR
        dk = Disk(img)
        img[dk.dir:dk.dir + dk.dirblks * dk.bs] = b"\xE5" * (dk.dirblks * dk.bs)
    else:
        img = bytearray(open(base, "rb").read())
        if len(img) != SIZE:
            sys.exit(f"kdi: {base} is not an 819200-byte image")
    dk = Disk(img)
    for f in fl:
        add(dk, f)
    open(out, "wb").write(img)
    listing(dk)


if __name__ == "__main__":
    main()
