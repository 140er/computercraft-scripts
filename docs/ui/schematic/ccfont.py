"""Decode CC:Tweaked's term_font.png (paletted PNG, 16x16 glyphs of 6x9 px) without PIL.

The font belongs to CC:Tweaked, so the repo never stores it. find() reads it from a path given on
the command line, $CC_FONT (a .png or the mod .jar), or a CC:Tweaked jar in a known mods folder.
"""
import glob
import os
import struct
import zipfile
import zlib

ENTRY = "assets/computercraft/textures/gui/term_font.png"
SEARCH = ["~/.minecraft/mods/cc-tweaked-*.jar", "~/work/gateb-modpack/client/mods/cc-tweaked-*.jar",
          "~/work/*/mods/cc-tweaked-*.jar", "~/work/*/*/mods/cc-tweaked-*.jar"]


def read(path):
    """PNG bytes from a .png file or from inside a CC:Tweaked .jar."""
    if path.endswith(".jar"):
        with zipfile.ZipFile(path) as jar:
            return jar.read(ENTRY)
    with open(path, "rb") as f:
        return f.read()


def find(path=None):
    """The font source path, or None when no font is available."""
    for candidate in [path, os.environ.get("CC_FONT")]:
        if candidate:
            return os.path.expanduser(candidate)
    for pattern in SEARCH:
        hits = sorted(glob.glob(os.path.expanduser(pattern)))
        if hits:
            return hits[0]
    return None


def pixels(data):
    i, idat, plte, trns = 8, b"", None, None
    while i < len(data):
        n, kind = struct.unpack(">I4s", data[i:i + 8])
        body = data[i + 8:i + 8 + n]
        i += 12 + n
        if kind == b"IHDR":
            w, h, depth, _ = struct.unpack(">IIBB", body[:10])
        elif kind == b"PLTE":
            plte = body
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    stride, prev, p, px = (w * depth + 7) // 8, bytearray((w * depth + 7) // 8), 0, []
    for _ in range(h):
        mode, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - 1] if x else 0
            b = prev[x]
            c = prev[x - 1] if x else 0
            if mode == 1:
                line[x] = (line[x] + a) & 255
            elif mode == 2:
                line[x] = (line[x] + b) & 255
            elif mode == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif mode == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev, row = line, []
        for x in range(w):
            idx = (line[x * depth // 8] >> (8 - depth - (x * depth) % 8)) & ((1 << depth) - 1)
            alpha = trns[idx] if trns and idx < len(trns) else 255
            r = plte[idx * 3] if plte else idx
            row.append(1 if alpha > 128 and r > 128 else 0)
        px.append(row)
    return px


class Font:
    def __init__(s, path):
        s.px = pixels(read(path))
        s.cache = {}

    def glyph(s, c):
        """9 rows of 6 pixels (0 or 1) for CC byte c."""
        if c not in s.cache:
            cx, cy = 1 + (c % 16) * 8, 1 + (c // 16) * 11
            s.cache[c] = [[s.px[cy + y][cx + x] for x in range(6)] for y in range(9)]
        return s.cache[c]
