from .model import Criteria, Blocked, values, pocket_frame
from .visual import check

TITLE = "Pocket and physical monitor navigation"

# Route A pages are header tabs; the active tab sits on the panel colour 7.
# Older builds drew a SETUP button and a mine-back or lumber-back button.
SETUP = ("tab:setup", "setup")
MAIN = {"mining": ("tab:main", "tab:overview", "mine-back"), "lumber": ("tab:main", "tab:overview", "lumber-back")}


def ids(frame):
    return [b.get("id", "") for b in values(frame.get("buttons"))]


def rows(frame):
    r = frame.get("rows")
    return [r[k] for k in sorted(r, key=int)] if isinstance(r, dict) else list(r or [])


def background(row, x):
    if row.get("bg"):
        return row["bg"][x-1:x]
    end = 0
    for run in values(row.get("runs")):
        end += run[0]
        if x <= end:
            return run[2]
    return ""


def active_tab(frame):
    lines = rows(frame)
    for b in values(frame.get("buttons")):
        if b.get("id", "").startswith("tab:") and 1 <= b.get("y", 0) <= len(lines):
            if all(background(lines[b["y"]-1], x) == "7" for x in range(b["x"], b["x"] + b.get("w", 1))):
                return b["id"]
    return None


def page(ctx, name, role, want):
    """Open the setup or main page through its visible tab and report whether it became active."""
    frame = ctx.frame(name)
    choices = SETUP if want == "setup" else MAIN[role]
    target = next((i for i in choices if i in ids(frame)), None)
    if not target:
        raise Blocked(f"Visible {want} tab absent on {name} {role}")
    after = ctx.click(name, target)
    if target.startswith("tab:"):
        return after, active_tab(after) == target or want == "main" and active_tab(after) in MAIN[role][:2]
    # Legacy pages: setup shows a back button, main shows the setup button again.
    return after, any("back" in i for i in ids(after)) if want == "setup" else "setup" in ids(after)


def coordinates_of(ctx, name, frame, miners):
    """Each miner's x,y,z on the mining screen: its list row when wide enough, else its details page."""
    found = []
    text = "\n".join(r.get("text", "") for r in rows(frame))
    for miner in miners:
        ident = ctx.computer(miner)
        pos = ",".join(map(str, ctx.manifest["computers"][str(ident)]["pos"]))
        if pos in text:
            found.append(True)
            continue
        if f"turtle:{ident}" not in ids(ctx.frame(name)):
            found.append(False)
            continue
        details = ctx.click(name, f"turtle:{ident}")
        ctx.record(f"C3-{name}-mining-turtle-{ident}.json", details)
        found.append(pos in "\n".join(r.get("text", "") for r in rows(details)))
        if "turtle-back" not in ids(details):
            raise Blocked(f"Visible turtle-back button absent on {name} turtle {ident}")
        ctx.click(name, "turtle-back")
    return found


def evaluate(d):
    c = Criteria()
    for name in ("all_screens_reached", "setups_and_returns", "coordinates_fit", "generic_survives_reboot", "single_order_delivery", "real_photos"):
        c.require(d.get(name), name.replace("_", " "))
    return c.finish(d)


def run(ctx):
    reached, setups, photos, coordinates = [], [], [], []
    ctx.mining(start=False)
    ctx.lumber(start=False)
    ctx.cli("client", ctx.run, "start", timeout=180)
    try:
        pocket_frame(ctx)
        ctx.screenshot("C3-client-overview.png")
        if getattr(ctx, "linked_install", None):
            ctx.linked_install()
        for name in ("pocket", "wall"):
            for role in ("mining", "lumber", "generic", "ar", "map", "shop", "status"):
                frame = ctx.navigate(name, role)
                ctx.record(f"C3-{name}-{role}.json", {"frame": frame, "screen": ctx.request("monitors", computer=ctx.computer(name)) if name == "wall" else ctx.terminal(name)})
                reached.append(frame.get("role") == role)
                if role == "mining":
                    coordinates.extend(coordinates_of(ctx, name, frame, ("miner1", "miner2")))
                if role in ("mining", "lumber"):
                    setup, opened = page(ctx, name, role, "setup")
                    ctx.record(f"C3-{name}-{role}-setup.json", setup)
                    _, returned = page(ctx, name, role, "main")
                    setups.append(opened and returned)
                if ctx.manifest.get("client_views", {}).get(name):
                    ctx.command(ctx.manifest["client_views"][name])
                    photo = f"C3-{name}-{role}.png"
                    ctx.screenshot(photo)
                    photos.append(check(ctx, photo))
        ctx.power("storage", "on")
        ctx.navigate("wall", "shop")
        ctx.type_text("wall", "diamond")
        ctx.wait(lambda: any(b.get("id") == "item:minecraft:diamond" for b in values(ctx.frame("wall")["buttons"])), 30)
        before_order = ctx.count_items("storage_output", "diamond")
        ctx.click("wall", "item:minecraft:diamond")
        ctx.click("wall", "order:1:minecraft:diamond")
        ctx.wait(lambda: ctx.count_items("storage_output", "diamond") - before_order == 1, 120)
        single_order = ctx.count_items("storage_output", "diamond") - before_order == 1
        ctx.navigate("pocket", "generic")
        ctx.power("pocket", "reboot")
        survived = ctx.wait(lambda: ctx.lua("pocket", 'return GATEB_FRAME and GATEB_FRAME.role') == "generic", 30)
        ctx.record("C3-pocket-reboot-frame.json", ctx.frame("pocket"))
        ctx.screenshot("C3-client-after.png")
        return evaluate(ctx.record("C3-observations.json", {"all_screens_reached": all(reached),
             "setups_and_returns": all(setups), "generic_survives_reboot": bool(survived),
             "coordinates_fit": bool(coordinates) and all(coordinates), "single_order_delivery": single_order, "real_photos": all(photos) if len(photos) == 14 else None}))
    finally:
        ctx.cli("client", ctx.run, "stop")
