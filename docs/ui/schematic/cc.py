"""CC text-cell canvas, fixture writer, frame-size estimate and PNG renderer.

Cells hold [byte, fg, bg]. Fixtures store text as Unicode (UNI below for the control glyphs,
Latin-1 for 160-255), so tests/ui/render.lua must map bytes the same way.
"""
import struct
import zlib

# Authoring glyph -> CC byte. ASCII and Latin-1 (160-255) map to themselves.
UNI = {'►': 16, '◄': 17, '↕': 18, '▲': 30, '▼': 31, '↑': 24, '↓': 25, '→': 26, '←': 27, '•': 7,
       '♠': 6, '♣': 5, '♦': 4, '∟': 28, '↔': 29, '▬': 22, '◘': 8, '▒': 127, '☺': 1, '♪': 14}
BACK = {v: k for k, v in UNI.items()}


def cc(ch):
    if ch in UNI:
        return UNI[ch]
    o = ord(ch)
    if o < 256 and (o >= 160 or 32 <= o < 127):
        return o
    raise ValueError("no CC glyph for %r" % ch)


# Route A palette, slot by slot. The frame header carries it to the client.
PAL = {"0": "E6EAF2", "1": "FFC24B", "2": "E57FD8", "3": "9DB0D2", "4": "DEDE6C", "5": "7FCC19",
       "6": "F2B2CC", "7": "18223A", "8": "7886A3", "9": "2DD4BF", "a": "B69CFF", "b": "5AB0FF",
       "c": "28344D", "d": "3DDC84", "e": "FF6B5E", "f": "0B111C"}
# No server: the client keeps the last picture and swaps to this grey ramp; slot 2 carries the coral bar.
STALE = dict(PAL)
STALE.update({k: "46526C" for k in "13456789abde"})
STALE.update({"0": "6A7690", "c": "222B3E", "2": "FF6B5E"})


class Canvas:
    def __init__(s, w, h, title=""):
        s.w, s.h, s.title = w, h, title
        s.cells = [[[32, "0", "f"] for _ in range(w)] for _ in range(h)]
        s.buttons = []

    def ok(s, x, y):
        return 1 <= x <= s.w and 1 <= y <= s.h

    def put(s, x, y, text, fg="0", bg=None):
        for i, ch in enumerate(str(text)):
            if s.ok(x + i, y):
                c = s.cells[y - 1][x + i - 1]
                c[0], c[1] = cc(ch), fg
                if bg:
                    c[2] = bg

    def fill(s, x, y, w, h, bg, ch=" ", fg="0"):
        for j in range(h):
            for i in range(w):
                if s.ok(x + i, y + j):
                    s.cells[y + j - 1][x + i - 1] = [cc(ch), fg, bg]

    def hit(s, bid, x, y, w, h=1, label=""):
        s.buttons.append({"id": bid, "x": x, "y": y, "w": w, "h": h, "label": label})

    def fixture(s, path):
        rows = ["%dx%d %s" % (s.w, s.h, s.title)]
        rows += ["".join(BACK.get(c[0], chr(c[0])) for c in r) for r in s.cells]
        rows += ["".join(c[1] for c in r) for r in s.cells]
        rows += ["".join(c[2] for c in r) for r in s.cells]
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(rows) + "\n")

    def frame_bytes(s):
        """Wire size as so-mod-display sends it: per row the smaller of {text,fg,bg} and
        {text,runs} under so-proto's %q, blank cells reusing the previous fg (D.compact)."""
        def q(b):
            n = 2
            for x in b:
                n += 2 if x in (34, 92, 10, 13, 0) else 4 if x < 32 or x == 127 else 1
            return n
        total = 0
        for r in s.cells:
            text = bytes(c[0] for c in r)
            fg = "".join(c[1] for c in r)
            bg = "".join(c[2] for c in r)
            full = len('{["bg"]=,["fg"]=,["text"]=}') + q(bg.encode()) + q(fg.encode()) + q(text)
            runs = []
            for c in r:
                if runs and runs[-1][2] == c[2] and (runs[-1][1] == c[1] or c[0] == 32):
                    runs[-1][0] += 1
                else:
                    runs.append([1, c[1], c[2]])
            rtext = text.rstrip(b" ")
            comp = len('{["runs"]={},["text"]=}') + q(rtext) + sum(
                len('{[1]=,[2]="0",[3]="f"},') + len(str(n)) for n, _, _ in runs)
            total += min(full, comp) + len("[00]=,")
        total += sum(60 + len(b["id"]) + len(b["label"]) for b in s.buttons)
        return total + 400


# ---------------------------------------------------------------- PNG

def _chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)


def png(canvas, path, font, k=2, palette=None):
    """Render with CC's own font (ccfont.Font) at 6x9 px per cell, k times zoomed."""
    pal = {key: bytes.fromhex(v) for key, v in (palette or PAL).items()}
    w, h = canvas.w * 6 * k, canvas.h * 9 * k
    raw = bytearray()
    for row in canvas.cells:
        for gy in range(9):
            line = bytearray()
            for ch, fg, bg in row:
                bits = font.glyph(ch)[gy]
                f, b = pal[fg], pal[bg]
                for gx in range(6):
                    line += (f if bits[gx] else b) * k
            for _ in range(k):
                raw.append(0)
                raw += line
    data = b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    data += _chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)
