"""Route A screens: the fixtures the UI tests compare against, and PNGs of them.

python3 -I docs/ui/schematic/screens.py --fixtures DIR    write every fixture (default tests/ui/fixtures)
python3 -I docs/ui/schematic/screens.py --png DIR [--font PATH] [names...]
    render PNGs with CC's own font, read from PATH, $CC_FONT or a CC:Tweaked jar (see ccfont.find)

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
import mapscreen as MS  # noqa: E402
import status as ST  # noqa: E402
import pocket as PK  # noqa: E402
import system as SY  # noqa: E402
import jobs as J  # noqa: E402
import other as O  # noqa: E402


def status(w, h, title, wall_map=False):
    def make():
        m = ST.model()
        if wall_map:
            m["thumb"] = MD.thumb
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


def with_alert(m):
    """The status model with the scene's state alert, as the gather lists it: lost turtles, alerts, drops."""
    m = dict(m)
    a = PK.SYS["alert"]
    lost = [f for f in m["flags"] if f["text"].endswith(" lost")]
    m["flags"] = lost + [dict(text=a["text"])] + m["flags"][len(lost):]
    return m


def alert(w, h, title, mapped=True):
    return lambda: SY.alert(ST.model(), PK.SYS["alert"], w, h, 3000, mapped, title)


def view(mode, **extra):
    v = dict(id=1, uptime="up 3h12", mode=mode, log=PK.SYS["log"], offset=0)
    v.update(extra)
    return v


ROLES = [dict(id=1, size="57x24", role="status"), dict(id=2, size="26x20", role="pocket"),
         dict(id=5, size="57x24", role="mining"), dict(id=6, size="57x24", role="unassigned"),
         dict(id=7, size="15x10", role="status"), dict(id=9, size="-", role="drops")]

FIXTURES = [
    ("kit-M", kit_sample),
    ("status-M", status(57, 24, "Status, room monitor 57x24 at scale 0.5")),
    ("status-W", status(100, 38, "Status, wall 100x38 at scale 0.5", True)),
    ("status-XL", status(164, 81, "Status, largest wall 164x81 at scale 0.5", True)),
    ("status-T", status(51, 19, "Status, 51x19 terminal size")),
    ("status-L", status(39, 19, "Status, wall monitor 4x3 at scale 1")),
    ("status-P", status(26, 20, "Status at 26x20 (a pocket assigned status)")),
    ("status-XS", status(15, 10, "Status, smallest monitor 1x1 at scale 0.5")),
    ("pocket-fleet-P", lambda: PK.fleet(ST.model())),
    ("pocket-alerts-P", lambda: PK.alerts(with_alert(ST.model()))),
    ("pocket-jobs-P", lambda: PK.jobs(ST.model())),
    ("pocket-shop-P", PK.shop_sent),
    ("pocket-pair-P", lambda: PK.pair(ST.model())),
    ("pocket-code-P", lambda: PK.pair(ST.model(), code=PK.SYS["code"], left=PK.SYS["left"])),
    ("alert-M", alert(57, 24, "Alert takeover, room monitor 57x24, 3 s left")),
    ("alert-W", alert(100, 38, "Alert takeover, wall 100x38")),
    ("alert-T", alert(51, 19, "Alert takeover, 51x19")),
    ("alert-P", alert(26, 20, "Alert takeover, pocket 26x20")),
    ("alert-XS", alert(15, 10, "Alert takeover, smallest monitor 15x10")),
    ("alert-nomap-M", alert(57, 24, "Alert takeover without the map module", False)),
    ("unassigned-M", lambda: SY.unassigned(57, 24, 6, title="Unassigned display 6, room monitor")),
    ("unassigned-XS", lambda: SY.unassigned(15, 10, 6, title="Unassigned display 6, smallest monitor")),
    ("unloaded-M", lambda: SY.unassigned(57, 24, 9, "MAP", "Display 9 set to map while the map module is missing")),
    ("outage-M", lambda: SY.outage(ST.status(ST.model(), 57, 24), "No server: the last status picture, stale palette")),
    ("outage-P", lambda: SY.outage(PK.fleet(ST.model()), "No server on a pocket: the last FLEET page")),
    ("server-T", lambda: SY.terminal(ST.model(), view("normal"), title="Server terminal 51x19")),
    ("pairing-T", lambda: SY.terminal(ST.model(), view("code", code=PK.SYS["code"], now=0, expires=292000),
                                      title="Server terminal, pair code")),
    ("log-T", lambda: SY.terminal(ST.model(), view("log"), title="Server terminal, full log (L)")),
    ("roles-T", lambda: SY.terminal(ST.model(), view("role", input="6 shop", notice="display 7: status", displays=ROLES),
                                    title="Server terminal, role command (R)")),
]
FIXTURES += SH.FIXTURES + MS.FIXTURES
FIXTURES += J.FIXTURES
FIXTURES += O.FIXTURES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", nargs="?", const=os.path.join(cc_root(), "tests", "ui", "fixtures"))
    ap.add_argument("--png")
    ap.add_argument("--font")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    if not (args.fixtures or args.png):
        ap.error("give --fixtures or --png")
    chosen = [(n, f) for n, f in FIXTURES if not args.names or n in args.names]
    if args.fixtures:
        os.makedirs(args.fixtures, exist_ok=True)
        for name, make in chosen:
            make().fixture(os.path.join(args.fixtures, name + ".txt"))
    if args.png:
        source = ccfont.find(args.font)
        if not source:
            sys.exit("no CC font: pass --font term_font.png or the cc-tweaked jar, or set CC_FONT")
        font = ccfont.Font(source)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
        sizes = {}
        for name, make in chosen:
            canvas = make()
            pal = cc.STALE if name.startswith("outage") else None
            cc.png(canvas, os.path.join(args.png, name + ".png"), font, palette=pal)
            sizes[name] = canvas.frame_bytes()
            print("%-12s %3dx%-3d %6d bytes" % (name, canvas.w, canvas.h, sizes[name]))
        with open(os.path.join(args.png, "frame-bytes.json"), "w") as f:
            json.dump(sizes, f, indent=1)


def cc_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


if __name__ == "__main__":
    main()
