from .model import Criteria, Blocked, values
from .visual import check

TITLE = "Pocket and physical monitor navigation"


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
        if not ctx.wait(lambda: ctx.frame("pocket"), 180):
            raise Blocked("Pocket did not become available after client login")
        if getattr(ctx, "linked_install", None):
            ctx.linked_install()
        for name in ("pocket", "wall"):
            for role in ("mining", "lumber", "generic", "ar", "map", "shop", "status"):
                frame = ctx.navigate(name, role)
                ctx.record(f"C3-{name}-{role}.json", {"frame": frame, "screen": ctx.request("monitors", computer=ctx.computer(name)) if name == "wall" else ctx.terminal(name)})
                reached.append(frame.get("role") == role)
                if role == "mining":
                    text = "\n".join(r.get("text", "") for r in values(frame["rows"]))
                    coordinates.extend(",".join(map(str, ctx.manifest["computers"][str(ctx.computer(n))]["pos"])) in text for n in ("miner1", "miner2"))
                if role in ("mining", "lumber"):
                    setup = ctx.click(name, "setup")
                    setups.append(any("back" in b.get("id", "") for b in values(setup["buttons"])))
                    ctx.click(name, "mine-back" if role == "mining" else "lumber-back")
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
        survived = ctx.wait(lambda: ctx.frame("pocket").get("role") == "generic", 30)
        return evaluate(ctx.record("C3-observations.json", {"all_screens_reached": all(reached),
             "setups_and_returns": all(setups), "generic_survives_reboot": bool(survived),
             "coordinates_fit": bool(coordinates) and all(coordinates), "single_order_delivery": single_order, "real_photos": all(photos) if len(photos) == 14 else None}))
    finally:
        ctx.cli("client", ctx.run, "stop")
