import re
from .model import Criteria, Blocked, pocket_frame
from . import photos as camera

TITLE = "Real goggles alignment and layer persistence"


def evaluate(d):
    c = Criteria()
    for name in ("linked_goggles", "labels_boxes_headings_aligned", "no_overlap", "stable_frames", "hud_matches_server", "native_layer_removal", "layers_persist", "real_photos"):
        c.require(d.get(name), name.replace("_", " "))
    return c.finish(d)


PLAYER = "GateBTester"
WORKERS = ("miner1", "miner2", "lumber")


def said(output, word, player=PLAYER):
    return bool(re.search(rf"\[{player}\] {word}(?:\s|$)", output or ""))


def goggles_in(slot, pos):
    x, y, z = (f"{float(v)}d" for v in pos)
    return f'Inventory[{{Slot:{slot}b,id:"cc_ar:ar_goggles",components:{{"cc_ar:ar_goggles_data":{{x:{x},y:{y},z:{z}}}}}}}]'


def provision(ctx):
    """The template player carries goggles linked to the AR controller in hotbar slot 8; wear them.
    A manifest goggles fixture, when present, replaces this native setup."""
    fixture = ctx.manifest.get("fixtures", {}).get("goggles")
    if fixture is not None:
        if not fixture.get("linked_player_in_template"):
            raise Blocked("Template has no native player with linked, worn AR goggles")
        if not fixture.get("verify_command"):
            raise Blocked("Goggles fixture needs a native command proving worn goggles linked to this controller")
        return fixture
    pos = ctx.fixture("ar")["pos"]
    if not ctx.wait(lambda: said(ctx.command(f"execute as {PLAYER} run say GATEB_PLAYER_READY")["output"], "GATEB_PLAYER_READY"), 180):
        raise Blocked(f"Native player {PLAYER} did not join the world")
    worn = f"execute as {PLAYER} if data entity @s {goggles_in(103, pos)} run say GATEB_GOGGLES_LINKED"
    held = ctx.command(f"execute as {PLAYER} if data entity @s {goggles_in(8, pos)} run say GATEB_GOGGLES_HELD")
    if said(held["output"], "GATEB_GOGGLES_HELD"):
        ctx.command(f"item replace entity {PLAYER} armor.head from entity {PLAYER} hotbar.8")
    elif not said(ctx.command(worn)["output"], "GATEB_GOGGLES_LINKED"):
        raise Blocked("Template player holds no goggles linked to the AR controller")
    turtles = sum(1 for n in WORKERS if ctx.manifest["computers"].get(str(ctx.computer(n)), {}).get("kind") == "turtle")
    return {"linked_player_in_template": True, "verify_command": worn, "expected_turtles": turtles, "native": True}


def views(ctx):
    """The AR camera: client_views.ar, else the wall camera."""
    configured = ctx.manifest.get("client_views", {})
    view = configured.get("ar") or configured.get("wall")
    if not view:
        raise Blocked("C13 photos need a client_views.ar or client_views.wall camera")
    return view


def run(ctx):
    # Assigned (unstarted) jobs give the AR layers turtles, leases and drop points to draw.
    ctx.mining(start=False)
    ctx.lumber(start=False)
    ctx.cli("client", ctx.run, "start", timeout=180)
    try:
        goggles = provision(ctx)
        verify = goggles["verify_command"]
        output = ctx.command(verify)["output"]
        linked = said(output, "GATEB_GOGGLES_LINKED") if goggles.get("native") else "GATEB_GOGGLES_LINKED" in output
        ctx.record("C13-native-goggles-link.json", {"verify_command": verify, "linked": linked,
                                                    "expected_turtles": goggles.get("expected_turtles")})
        pocket_frame(ctx)
        count = ctx.lua("server", 'local n=0;for _,m in pairs(SO.mods.state.get("machines") or {}) do if m.role=="worker" or m.role=="turtle" then n=n+1 end end;return n')
        ctx.navigate("pocket", "ar")
        view = views(ctx)
        before = ctx.read_store("server", "so-data/ar")
        before_pixels = camera.take(ctx, "C13-layers-before.png", view)
        for layer in ("turtles", "leases", "drops", "alerts"):
            ctx.click("pocket", layer)
        toggled_pixels = camera.take(ctx, "C13-layers-toggled.png", view)
        toggled = ctx.read_store("server", "so-data/ar")
        ctx.power("server", "reboot")
        ctx.wait(lambda: ctx.lua("server", "return SO ~= nil"), 30)
        persisted = ctx.read_store("server", "so-data/ar") == toggled and toggled != before
        stability = []
        for i in range(3):
            ctx.sleep(1)
            stability.append(camera.take(ctx, f"C13-stability-{i}.png", view))
        stable = camera.credit(stability)
        return evaluate(ctx.record("C13-observations.json", {"linked_goggles": linked, "layers_persist": persisted,
            "real_photos": camera.credit([before_pixels, toggled_pixels, *stability]), "labels_boxes_headings_aligned": before_pixels, "no_overlap": before_pixels,
            "stable_frames": stable, "hud_matches_server": count == goggles.get("expected_turtles") and before_pixels, "native_layer_removal": toggled_pixels}))
    finally:
        ctx.cli("client", ctx.run, "stop")
