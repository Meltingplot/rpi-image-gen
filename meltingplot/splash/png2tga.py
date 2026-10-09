#!/usr/bin/env python3
"""Turn the splash PNG into the TGA the rpi-splash-screen layer wants.

The Raspberry Pi kernel draws the boot logo from an uncompressed 24-bit TGA
with fewer than 224 colours. The source here is an anti-aliased PNG exported
from hmi-splash.sla, so this keeps the 223 most frequent colours and moves
every other pixel to the nearest of them; for a logo on a plain background
that only touches edge pixels. Pure Python, so it needs nothing installed.

    python3 png2tga.py hmi-splash.png hmi-splash.tga [--rotate180]

--rotate180 is for a panel mounted upside down, if the kernel does not turn
the logo itself.
"""
import argparse
import struct
import zlib
from collections import Counter

MAX_COLOURS = 223


def read_png(path):
    """Pixels of an 8-bit RGB or RGBA, non-interlaced PNG as rows of RGB tuples."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    w, h, depth, ctype, _, _, interlace = ihdr
    if depth != 8 or interlace != 0 or ctype not in (2, 6):
        raise SystemExit(f"{path}: need 8-bit RGB/RGBA without interlacing")
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        if bpp == 4 and any(line[x] != 255 for x in range(3, stride, 4)):
            raise SystemExit(f"{path}: has transparent pixels, export it opaque")
        rows.append([tuple(line[x:x + 3]) for x in range(0, stride, bpp)])
        prev = line
    return w, h, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("png")
    ap.add_argument("tga")
    ap.add_argument("--rotate180", action="store_true")
    args = ap.parse_args()

    w, h, rows = read_png(args.png)
    counts = Counter(p for row in rows for p in row)
    palette = [c for c, _ in counts.most_common(MAX_COLOURS)]
    kept_set = set(palette)
    nearest = {c: c if c in kept_set else min(palette, key=lambda p: sum((p[k] - c[k]) ** 2 for k in range(3)))
               for c in counts}
    if args.rotate180:
        rows = [row[::-1] for row in rows[::-1]]

    # Uncompressed true colour, origin bottom left, as the demo splash of
    # rpi-image-gen: rows go bottom up, pixels as BGR.
    out = bytearray(struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 24, 0))
    for row in reversed(rows):
        for p in row:
            r, g, b = nearest[p]
            out += bytes((b, g, r))
    open(args.tga, "wb").write(out)
    kept = sum(n for c, n in counts.items() if nearest[c] == c)
    print(f"{args.tga}: {w}x{h}, {len(set(nearest.values()))} colours, "
          f"{100 * kept / (w * h):.2f} % of pixels unchanged")


if __name__ == "__main__":
    main()
