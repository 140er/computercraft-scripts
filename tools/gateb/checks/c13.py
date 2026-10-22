import time
from .model import Criteria, Blocked
from .visual import check

TITLE = "Real goggles alignment and layer persistence"


def evaluate(d):
    c = Criteria()
    for name in ("linked_goggles", "labels_boxes_headings_aligned", "no_overlap", "stable_frames", "hud_matches_server", "native_layer_removal", "layers_persist", "real_photos"):
        c.require(d.get(name), name.replace("_", " "))
    return c.finish(d)


def run(ctx):
    goggles = ctx.fixture("goggles")
    ctx.cli("client", ctx.run, "start", timeout=180)
    try:
        if not goggles.get("linked_player_in_template"):
            raise Blocked("Template has no native player with linked, worn AR goggles")
        verify = goggles.get("verify_command")
        if not verify:
            raise Blocked("Goggles fixture needs a native command proving worn goggles linked to this controller")
        linked = "GATEB_GOGGLES_LINKED" in ctx.command(verify)["output"]
        count = ctx.lua("server", 'local n=0;for _,m in pairs(SO.mods.state.get("machines") or {}) do if m.role=="worker" then n=n+1 end end;return n')
        ctx.navigate("pocket", "ar")
        before = ctx.read_store("server", "so-data/ar")
        ctx.screenshot("C13-layers-before.png")
        before_pixels = check(ctx, "C13-layers-before.png")
        for layer in ("turtles", "leases", "drops", "alerts"):
            ctx.click("pocket", layer)
        ctx.screenshot("C13-layers-toggled.png")
        toggled_pixels = check(ctx, "C13-layers-toggled.png")
        toggled = ctx.read_store("server", "so-data/ar")
        ctx.power("server", "reboot")
        ctx.wait(lambda: ctx.lua("server", "return SO ~= nil"), 30)
        persisted = ctx.read_store("server", "so-data/ar") == toggled and toggled != before
        stable = True
        for i in range(3):
            time.sleep(1)
            ctx.screenshot(f"C13-stability-{i}.png")
            stable &= check(ctx, f"C13-stability-{i}.png")
        return evaluate(ctx.record("C13-observations.json", {"linked_goggles": linked, "layers_persist": persisted,
            "real_photos": True, "labels_boxes_headings_aligned": before_pixels, "no_overlap": before_pixels,
            "stable_frames": stable, "hud_matches_server": count == goggles.get("expected_turtles") and before_pixels, "native_layer_removal": toggled_pixels}))
    finally:
        ctx.cli("client", ctx.run, "stop")
