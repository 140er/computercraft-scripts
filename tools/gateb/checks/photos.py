"""Native C3 and C13 photos: camera, pocket screen, a settled frame, then visual credit or a candidate.

Without --collect-photos a photo earns credit only by matching its reviewed reference
(visual.check; a missing reference blocks). With it, every photo is written with its
camera to the candidate folder and earns no credit."""
import json
from pathlib import Path
import subprocess
import time

from .model import Blocked
from .visual import check

PLAYER = "GateBTester"
WIDTH, HEIGHT = 1280, 720


def fraction(path, crop, formula):
    """Share of pixels in crop (WxH+X+Y) for which the ImageMagick -fx formula holds."""
    out = subprocess.run(["convert", str(path), "-crop", crop, "+repage", "-fx", formula, "-format", "%[fx:mean]", "info:"],
                         capture_output=True, text=True, timeout=60)
    if out.returncode:
        raise Blocked("Native photo checks need ImageMagick")
    return float(out.stdout)


def changed(a, b):
    """Share of pixels that differ by more than 3% between two screenshots."""
    out = subprocess.run(["compare", "-metric", "AE", "-fuzz", "3%", str(a), str(b), "null:"],
                         capture_output=True, text=True, timeout=60)
    if out.returncode > 1:
        raise Blocked("Native photo checks need ImageMagick")
    return float(out.stderr.split()[0]) / (WIDTH * HEIGHT)


# The pocket screen's yellow bezel at both sides of the centred pocket GUI.
def pocket_open(path):
    return min(fraction(path, f"16x400+{x}+120", "r>0.75&&g>0.75&&b<0.55&&b>0.25?1:0") for x in (392, 922)) > .3


# The pause menu's grey button row.
def menu_open(path):
    return fraction(path, "600x40+340+195", "abs(r-g)<0.04&&abs(g-b)<0.04&&r>0.3&&r<0.6?1:0") > .5


# "Loading terrain" and missing textures draw the magenta and black checker.
def loading(path):
    return fraction(path, f"{WIDTH}x{HEIGHT}+0+0", "r>0.5&&g<0.1&&b>0.5?1:0") >= .01


def keys(ctx):
    if getattr(ctx, "native_input", None) is None:
        from native_input import Input
        ctx.native_input = Input((ctx.runtime.run(ctx.run) / "display").read_text().strip())
    return ctx.native_input


def open_pocket(ctx, attempts=8):
    """Hold the pocket computer (hotbar 1) and use it until its bezel shows. Spectators cannot use items."""
    if not getattr(ctx, "pocket_mode", False):
        ctx.command(f"gamemode creative {PLAYER}")
        ctx.pocket_mode = True
    for _ in range(attempts):
        shot = ctx.shot()
        if pocket_open(shot):
            return shot
        if menu_open(shot):
            keys(ctx).press("Escape"); ctx.sleep(2); continue
        keys(ctx).press("Escape"); ctx.sleep(1.5)
        if menu_open(ctx.shot()):
            keys(ctx).press("Escape"); ctx.sleep(1.5)
        keys(ctx).press("1"); ctx.sleep(.5); keys(ctx).click(WIDTH // 2, HEIGHT // 2, 3); ctx.sleep(3)
    raise Blocked("Native pocket bezel not visible")


def close_screens(ctx, attempts=4):
    """Close the pocket screen and the pause menu so the world is in view."""
    for _ in range(attempts):
        shot = ctx.shot()
        if not pocket_open(shot) and not menu_open(shot):
            return shot
        keys(ctx).press("Escape"); ctx.sleep(1.5)
    raise Blocked("Native client kept a screen open over the world")


def settled(ctx, name, pocket, seconds=90, limit=.02):
    """A screenshot with the world loaded, no menu, the pocket screen in the wanted state,
    and less than limit of its pixels changed from the previous one."""
    deadline, previous = time.monotonic() + seconds, None
    while time.monotonic() < deadline:
        shot = ctx.shot()
        if menu_open(shot):
            keys(ctx).press("Escape"); ctx.sleep(2); previous = None; continue
        if loading(shot):
            ctx.sleep(2); previous = None; continue
        if pocket_open(shot) != pocket:
            (open_pocket if pocket else close_screens)(ctx); previous = None; continue
        if previous is not None and changed(previous, shot) < limit:
            return shot
        previous = shot
        ctx.sleep(1)
    raise Blocked(f"Native screenshot did not settle for {name}")


def take(ctx, name, view=None, pocket=False):
    """Photo `name` from camera command `view`: True or False by its reviewed reference,
    or None (no credit) when collecting candidates."""
    if not getattr(ctx, "photo_prepared", False):
        # One-off world setup the reviewed cameras assume, such as clearing a block in the view.
        for command in ctx.manifest.get("photo_prepare", []):
            ctx.command(command)
        ctx.photo_prepared = True
    if view:
        ctx.command(view)
    (open_pocket if pocket else close_screens)(ctx)
    ctx.keep(settled(ctx, name, pocket), name)
    collect = getattr(ctx, "collect", None)
    if not collect:
        return check(ctx, name)
    folder = Path(collect)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_bytes((ctx.output / name).read_bytes())
    camera = {"run": ctx.run, "view": view,
              "pos": ctx.command(f"data get entity {PLAYER} Pos"),
              "rotation": ctx.command(f"data get entity {PLAYER} Rotation")}
    (folder / (name + ".camera.json")).write_text(json.dumps(camera, indent=2) + "\n")
    candidates = getattr(ctx, "candidates", None)
    if candidates is None:
        candidates = ctx.candidates = []
    candidates.append(name)
    return None


def credit(results):
    """All photos matched; None while any photo has no verdict (collecting, or none taken)."""
    if not results or any(r is None for r in results):
        return None
    return all(results)
