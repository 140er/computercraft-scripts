import math
from pathlib import Path


def generate(Canvas):
    scenes = []
    for mw, mh in [(26, 20), (29, 12), (57, 24)]:
        c = Canvas(mw, mh)
        c.header("MAP", "")
        header = next(y for y, row in enumerate(c.t) if "MAP" in "".join(row))
        vh = mh - 4 - header
        scale = max(1, math.ceil(13 / mw), math.ceil(14 / vh))
        left, top = -(mw // 2) * scale, -4 - (vh // 2) * scale
        def mark(x, z, ch=" ", bg="7"):
            px, py = (x - left) // scale, (z - top) // scale + header + 1
            if 0 <= px < mw and header + 1 <= py <= header + vh:
                c.text(px, py, ch, bg)
                return px, py
        for z in range(-9, 0):
            mark(0, z)
        for z in [-5, -9]:
            for x in range(5):
                mark(x, z)
        mark(1, -7, bg="8")
        for x in range(-5, -2):
            for z in range(-3, 0):
                if x in [-5, -3] or z in [-3, -1]:
                    mark(x, z, bg="d")
        mark(0, -1, "H", "9")
        for x, y, ch in [(5, -5, "O"), (-5, 2, "F"), (-3, 2, "W"), (-1, 2, "S")]:
            mark(x, y, ch, "a")
        mark(0, 2, "@", "9")
        for x, z, ch, ident, bg in [(2, -5, ">", "2", "d"), (4, -9, "v", "3", "b")]:
            px, py = mark(x, z, ch, bg)
            if scale == 1:
                c.text(px + 1, py, ident, bg)
        c.header("MAP", f"N ^ 1:{scale}")
        available = mw - 3
        for row, labels in [(mh - 3, ["BACK", "FIT", "+", "-"]), (mh - 2, ["^", "<", "v", ">"] )]:
            for i, label in enumerate(labels):
                start = math.floor(i * available / 4 + 0.5)
                end = math.floor((i + 1) * available / 4 + 0.5)
                c.button(start + i, row, end - start, label, "9" if label == "FIT" else "7", h=1)
        c.button(0, mh - 1, mw, "ALL", h=1)
        scenes.append((f"map-{mw}x{mh}", c, f"Map, projected levels {mw}x{mh}"))
    return scenes


def write(Canvas, destination, fixtures=False):
    destination = Path(destination)
    scenes = generate(Canvas)
    if fixtures:
        for stem, canvas, title in scenes:
            layers = [f"{canvas.w}x{canvas.h} {title}"]
            layers += ["".join(row) for row in canvas.t]
            layers += ["".join(row) for row in canvas.b]
            (destination / (stem + ".txt")).write_text("\n".join(layers) + "\n", encoding="utf-8")
    else:
        (destination / "map-mockups.md").write_text(
            "\n\n".join(canvas.dump(title, True) for _, canvas, title in scenes) + "\n", encoding="utf-8")
