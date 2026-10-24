"""The shared scene. Geometry, dug cells, farm and drops come from tests/ui/map-scene.txt; turtle
states, jobs, totals, displays and events come from tests/ui/status-scene.txt. tests/ui/s0.lua feeds
the same two files to the real gather, so a fixture made here must equal the Lua screen."""
import os

from kit import tone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
DIRS = {0: (0, -1), 1: (1, 0), 2: (0, 1), 3: (-1, 0)}


def lines(name):
    with open(os.path.join(ROOT, "tests", "ui", name)) as f:
        for line in f:
            parts = line.split()
            if parts:
                yield parts


def load_map():
    s = {"dug": [], "reserve": [], "turtles": [], "drops": [], "spots": [], "poses": {}, "views": []}
    for p in lines("map-scene.txt"):
        k = p[0]
        if k == "server":
            s["server"] = tuple(map(int, p[1:4]))
        elif k == "mine":
            x, y, z, f, bottom, length = map(int, p[1:7])
            branches = int(p[8])
            d, r = DIRS[f], DIRS[(f + 1) % 4]
            gap = 2 if p[7] == "fast" else 4
            s["g"] = dict(home=(x, y, z), x=x + d[0], z=z + d[1], top=y, bottom=bottom, dx=d[0], dz=d[1],
                          rx=r[0], rz=r[1], gap=gap, branches=branches, length=length,
                          spine=branches * gap, mode=p[7])
        elif k == "dug":
            s["dug"].append(tuple(map(int, p[1:7])))
        elif k == "reserve":
            s["reserve"].append((p[1],) + tuple(map(int, p[2:8])))
        elif k == "turtle":
            s["poses"][p[1]] = dict(x=int(p[2]), y=int(p[3]), z=int(p[4]), f=int(p[5]))
        elif k == "drop":
            s["drops"].append(dict(kind=p[1], x=int(p[2]), y=int(p[3]), z=int(p[4]), broken=len(p) > 5))
        elif k == "saplings":
            s["drops"].append(dict(kind="saplings", x=int(p[1]), y=int(p[2]), z=int(p[3]), broken=False))
        elif k == "farm":
            s["area"] = dict(x1=int(p[1]), z1=int(p[2]), x2=int(p[3]), z2=int(p[4]), ground=int(p[5]))
        elif k == "spot":
            s["spots"].append(dict(x=int(p[1]), z=int(p[2]), ready=p[3] == "ready"))
        elif k == "view":
            # view NAME WxH LEVEL fit|SXxSZ CX CZ [turtle ID | drop ID | server | shaft | cell X Z]
            w, h = map(int, p[2].split("x"))
            v = dict(name=p[1], w=w, h=h, level="all" if p[3] == "all" else int(p[3]), scale=None, centre=None)
            rest = p[4:]
            if rest[0] != "fit":
                v["scale"], v["centre"] = tuple(map(int, rest[0].split("x"))), (int(rest[1]), int(rest[2]))
                rest = rest[3:]
            else:
                rest = rest[1:]
            v["pick"] = None if not rest else (rest[0], rest[1]) if rest[0] in ("turtle", "drop") else \
                ("cell", int(rest[1]), int(rest[2])) if rest[0] == "cell" else (rest[0],)
            s["views"].append(v)
    for i, d in enumerate(s["drops"]):
        d["id"] = i + 1
    return s


PHASE = {"scan": "scanning", "base": "felling", "climb": "felling", "descend": "felling",
         "plant": "planting", "plantPlace": "planting"}


def load_status(m):
    """The status model, field for field what so-mod-display's gather builds."""
    st = {"turtles": [], "leases": {}, "displays": [], "events": []}
    for p in lines("status-scene.txt"):
        k = p[0]
        if k == "epoch":
            st["epoch"] = int(p[1])
        elif k == "server":
            st["id"], st["uptime"] = int(p[1]), int(p[2])
        elif k == "disk":
            st["cap"], st["free"] = int(p[1]), int(p[2])
        elif k == "today":
            st["today"] = dict(ore=int(p[1]), logs=int(p[2]), recent=int(p[3]),
                               names=[(a.split(":")[0], int(a.split(":")[1])) for a in p[4:]])
        elif k == "mining":
            st["mining"] = dict(running=p[1] == "running", done=int(p[2]), total=int(p[3]))
        elif k == "lumber":
            st["lumber"] = dict(running=p[1] == "running", grow=int(p[2]))
        elif k == "turtle":
            st["turtles"].append(dict(id=int(p[1]), job=p[2], state=p[3].replace("_", " "), fuel=int(p[4]),
                                      ore=int(p[5]), ago=int(p[6]), at=p[7]))
        elif k == "lease":
            st["leases"][int(p[1])] = p[2]
        elif k == "display":
            st["displays"].append(dict(id=int(p[1]), role=p[2], size=p[3]))
        elif k == "event":
            st["events"].append(dict(time=p[1], text=" ".join(p[2:])))
    return st


S = load_map()
ST = load_status(S)

# Turtle states for the map markers.
for t in ST["turtles"]:
    pose = S["poses"][str(t["id"])]
    word = "lost" if ST["leases"].get(t["id"]) == "lost" else PHASE.get(t["state"], t["state"])
    lease = ST["leases"].get(t["id"])
    S["turtles"].append(dict(id=str(t["id"]), x=pose["x"], y=pose["y"], z=pose["z"], f=pose["f"],
                             state=word, col=tone(word), fuel=t["fuel"], ore=t["ore"], ago=t["ago"],
                             lease="expired" if lease == "lost" else lease or "-"))
S["turtles"].sort(key=lambda t: int(t["id"]))
