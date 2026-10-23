"""Route A screens: the fixtures the UI tests compare against, and PNGs of them.

python3 -I docs/ui/schematic/screens.py --fixtures DIR    write every fixture (default tests/ui/fixtures)
python3 -I docs/ui/schematic/screens.py --png DIR [--font PATH] [names...]
    render PNGs with CC's own font, read from PATH, $CC_FONT or a CC:Tweaked jar (see ccfont.find)
python3 -I docs/ui/schematic/screens.py --prototype DIR [--font PATH]
    render the route A prototype screens that are not ported yet (prototype.py)

Add a ported screen to FIXTURES; tests/ui/s0.lua checks that this output equals the committed files.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cc  # noqa: E402
import ccfont  # noqa: E402
import mapdraw as MD  # noqa: E402
import shop as SH  # noqa: E402
import status as ST  # noqa: E402


def thumb(cv, x, y, w, h):
    MD.draw(cv, MD.fit(w, h, "all", "top"), x, y)


def status(w, h, title, wall_map=False):
    def make():
        m = ST.model()
        if wall_map:
            m["thumb"] = thumb
        return ST.status(m, w, h, title)
    return make


def kit_sample():
    """Every kit primitive once; tests/ui/s0.lua draws the same calls with so-ui.lua."""
    from cc import Canvas
    import kit as K
    cv = Canvas(57, 24, "Route A kit primitives")
    K.bar(cv, "MINING", ["overview", "setup"], "overview", "running", "d")
    K.section(cv, 2, 3, 26, "SECTION", "5")
    K.leader(cv, 2, 4, 26, "ore", "214")
    K.leader(cv, 2, 5, 26, "fuel", "412", "1")
    K.ticks(cv, 2, 6, 10, 3)
    K.progress(cv, 2, 7, 10, 7, 10)
    K.progress(cv, 2, 8, 10, 9, 12, "d", "♠", "8", "♣")
    x = 2
    for kind in ("plain", "primary", "stop", "muted", "on", "off"):
        x = K.chip(cv, x, 10, kind, "chip:" + kind, kind) + 1
    K.chip(cv, 2, 12, "START", "start", "primary", 12)
    K.chip(cv, 16, 12, "STOP", "stop", "stop", 12)
    K.flag(cv, 2, 14, 26, "#6 lost", "184,-58,-369")
    K.box(cv, 30, 3, 26, 9, "e")
    K.digits(cv, 32, 5, "4821")
    K.digits(cv, 2, 16, "0123456789", "3", 4, 5, 1)
    K.rule(cv, 2, 22, 56)
    for i, (ch, fg) in enumerate(zip("►◄▲▼•×♠♣º¦·@", "d1eb0ed893b9")):
        cv.put(2 + 2 * i, 23, ch, fg)
    cv.put(2, 24, "%s %s %s %s" % (K.arrow(0), K.arrow(1), K.arrow(5), K.age(185000, True)), K.tone("wait lane"))
    return cv


def map_sample():
    """The route A map at the largest wall, 164x81, for the frame-size test in tests/ui/s0.lua."""
    from cc import Canvas
    cv = Canvas(164, 81, "Route A map at 164x81 (frame-size sample)")
    MD.draw(cv, MD.fit(164, 81, "all"), 1, 1)
    return cv


FIXTURES = [
    ("schematic-map-XL", map_sample),
    ("kit-M", kit_sample),
    ("status-M", status(57, 24, "Status, room monitor 57x24 at scale 0.5")),
    ("status-W", status(100, 38, "Status, wall 100x38 at scale 0.5", True)),
    ("status-XL", status(164, 81, "Status, largest wall 164x81 at scale 0.5", True)),
    ("status-T", status(51, 19, "Status, 51x19 terminal size")),
    ("status-L", status(39, 19, "Status, wall monitor 4x3 at scale 1")),
    ("status-P", status(26, 20, "Status at 26x20 (a pocket assigned status)")),
    ("status-XS", status(15, 10, "Status, smallest monitor 1x1 at scale 0.5")),
]
FIXTURES += SH.FIXTURES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", nargs="?", const=os.path.join(cc_root(), "tests", "ui", "fixtures"))
    ap.add_argument("--png")
    ap.add_argument("--prototype")
    ap.add_argument("--font")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    if not (args.fixtures or args.png or args.prototype):
        ap.error("give --fixtures, --png or --prototype")
    chosen = [(n, f) for n, f in FIXTURES if not args.names or n in args.names]
    if args.fixtures:
        os.makedirs(args.fixtures, exist_ok=True)
        for name, make in chosen:
            make().fixture(os.path.join(args.fixtures, name + ".txt"))
    if args.png or args.prototype:
        source = ccfont.find(args.font)
        if not source:
            sys.exit("no CC font: pass --font term_font.png or the cc-tweaked jar, or set CC_FONT")
        font = ccfont.Font(source)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
        sizes = {}
        for name, make in chosen:
            canvas = make()
            cc.png(canvas, os.path.join(args.png, name + ".png"), font)
            sizes[name] = canvas.frame_bytes()
            print("%-12s %3dx%-3d %6d bytes" % (name, canvas.w, canvas.h, sizes[name]))
        with open(os.path.join(args.png, "frame-bytes.json"), "w") as f:
            json.dump(sizes, f, indent=1)
    if args.prototype:
        import prototype
        os.makedirs(args.prototype, exist_ok=True)
        for name, make in prototype.SCREENS:
            if args.names and name not in args.names:
                continue
            canvas = make()
            pal = cc.STALE if name.startswith("19") else None
            cc.png(canvas, os.path.join(args.prototype, name + ".png"), font, palette=pal)


def cc_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


if __name__ == "__main__":
    main()
