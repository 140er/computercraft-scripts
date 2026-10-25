"""Opt-in C2 replacement evidence. Select with GATEB_C2_REPAIR=1 and --checks C2."""
from contextlib import contextmanager
import json
from pathlib import Path
import shutil

from .model import Blocked, Criteria

CLIENTS = ("wall", "pocket")
PHASES = ("readonly", "change", "confirm-change", "candidate", "code", "partial-code")
OBSERVER = Path(__file__).resolve().parents[1] / "c2_repair_loader.lua"
SNAPSHOT = "return GATEB_REPAIR and GATEB_REPAIR()"


def snapshot(ctx, name):
    result = ctx.lua(name, SNAPSHOT)
    if not isinstance(result, dict):
        raise Blocked(f"C2 repair observer unavailable on {name}")
    return result


def ready(ctx, name, predicate, message, seconds=60):
    result = ctx.wait(lambda: (lambda s: s if predicate(s) else None)(snapshot(ctx, name)), seconds)
    if not result:
        raise Blocked(message)
    return result


def event(ctx, name, kind, *args):
    before = snapshot(ctx, name)["inputs"]
    ctx.request("input", computer=ctx.computer(name), event=kind, args=list(args))
    return ready(ctx, name, lambda s: s["inputs"] > before, f"{name} did not consume {kind}")


@contextmanager
def native_client(ctx):
    ctx.cli("client", ctx.run, "start", timeout=180)
    try:
        if not ctx.wait(lambda: ctx.lua("pocket", "return os.clock() >= 2"), 60):
            raise Blocked("Pocket did not become available after native client login")
        yield
    finally:
        ctx.cli("client", ctx.run, "stop", timeout=60)


@contextmanager
def observed_clients(ctx):
    """Add an observer to the runtime loader, retaining the pinned application files."""
    runtime = ctx.runtime
    original = runtime.instrument
    targets = {runtime.computer_disk(ctx.run, ctx.computer(n)).resolve() for n in CLIENTS}

    def instrument(disk, role):
        proof = original(disk, role)
        disk = Path(disk)
        if disk.resolve() in targets:
            shutil.copy2(OBSERVER, disk / "gateb-c2-repair-loader.lua")
            bridge = disk / "gateb-bridge.lua"
            source = bridge.read_text()
            entry = "local fn,why=loadfile('/'..assert(programs[role]),env)"
            if source.count(entry) != 1:
                raise Blocked("C2 repair observer needs the runtime bridge role loader")
            bridge.write_text(source.replace(entry,
                "local fn,why=dofile('/gateb-c2-repair-loader.lua')('/'..assert(programs[role]),env)"))
        return proof

    runtime.instrument = instrument
    try:
        for name in CLIENTS:
            ctx.power(name, "reboot")
            ready(ctx, name, lambda s: s["phase"] == "live", f"{name} was not initially paired")
        yield
    finally:
        runtime.instrument = original


def replace_server(ctx):
    """Use the spare native computer with fresh state, never the old server's keys."""
    from world import installer_manifest
    old, new = ctx.computer("server"), ctx.computer("probe")
    if old == new:
        raise Blocked("Replacement server must have a new computer id")
    ctx.power("server", "off")
    ctx.power("probe", "off")
    source = ctx.runtime.computer_disk(ctx.run, old)
    target = ctx.runtime.computer_disk(ctx.run, new)
    shutil.rmtree(target)
    target.mkdir(parents=True)
    for relative in [*installer_manifest(source, "server"), ".so-files", ".so-revision"]:
        dest = target / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, dest)
    # The spare now boots the server role. Its native id and physical block are unchanged.
    manifest = ctx.runtime.manifest(ctx.run)
    manifest["computers"][str(new)]["role"] = "server"
    (ctx.runtime.run(ctx.run) / "manifest.json").write_text(json.dumps(manifest))
    ctx.manifest = manifest
    ctx.power("probe", "on")
    if not ctx.wait(lambda: ctx.lua("probe", "return SO and SO.pair and SO.mods and SO.mods.display ~= nil"), 60):
        raise Blocked("Replacement server did not boot")
    return old, new


def capture(ctx, name, label):
    # Never capture the invitation or entered digits. Snapshots expose lengths and hashes only.
    state = snapshot(ctx, name)
    if state["digits"]:
        return ctx.record(f"C2R-{name}-{label}.json", {"state": state})
    screens = {"terminal": ctx.terminal(name)}
    if name == "wall":
        screens["monitors"] = ctx.request("monitors", computer=ctx.computer(name))
    return ctx.record(f"C2R-{name}-{label}.json", {"state": state, "screens": screens})


def photo(ctx, name, label):
    from . import photos
    if name == "pocket":
        photos.open_pocket(ctx)
    else:
        photos.close_screens(ctx)
        pos = ctx.fixture("wall")["pos"]
        ctx.command(f"tp {photos.PLAYER} {pos[0] + 1.5} {pos[1]} {pos[2] - 4} 0 0")
    path = f"C2R-{name}-{label}.png"
    ctx.keep(photos.settled(ctx, path, name == "pocket"), path)
    return path


def wall_attack(ctx, label):
    before = snapshot(ctx, "wall")
    monitors = ctx.request("monitors", computer=ctx.computer("wall"))
    if not monitors:
        raise Blocked("C2 repair needs a physical wall monitor")
    # Small batches stay below the native event queue limit.
    for monitor, size in monitors.items():
        cells = [(x, y) for y in range(1, size["height"] + 1) for x in range(1, size["width"] + 1)]
        for offset in range(0, len(cells), 32):
            batch = cells[offset:offset + 32]
            count = snapshot(ctx, "wall")["inputs"]
            ctx.lua("wall", "local cells=textutils.unserializeJSON(" + json.dumps(json.dumps(batch)) +
                    ");for _,p in ipairs(cells) do os.queueEvent('monitor_touch'," + json.dumps(monitor) +
                    ",p[1],p[2]) end;return true")
            ready(ctx, "wall", lambda s: s["inputs"] >= count + len(batch), "Wall did not consume monitor taps")
    after = snapshot(ctx, "wall")
    fields = ("server", "peers", "stores", "digits")
    stable = all(before.get(k) == after.get(k) for k in fields)
    # Read-only taps may close/reopen the view; local repair must keep its exact phase.
    if label != "readonly":
        stable = stable and before.get("step") == after.get("step") and not after.get("readonly")
    return ctx.record(f"C2R-wall-{label}-attack.json", {"before": before, "after": after, "stable": stable})


def repaired(state, new, old):
    return (state.get("phase") == "live" and state.get("server") == new
            and set(state.get("peers", {})) == {str(new)} and str(old) not in state["peers"])


def evaluate(d):
    c = Criteria()
    old, new = d.get("old_server"), d.get("new_server")
    c.require(d.get("tick_rate") == 20, "Repair runs at 20 TPS")
    c.require(isinstance(old, int) and isinstance(new, int) and old != new, "Replacement has a different id")
    for name in CLIENTS:
        row = d.get("clients", {}).get(name, {})
        c.require(row.get("initial", {}).get("phase") == "live" and
                  row.get("initial", {}).get("server") == old and
                  str(old) in row.get("initial", {}).get("peers", {}), f"{name} initially paired to old server")
        success, reboot = row.get("success", {}), row.get("reboot", {})
        c.require(repaired(success, new, old), f"{name} local REPAIR succeeds with only the new peer")
        c.require(repaired(reboot, new, old) and success.get("peers") == reboot.get("peers"),
                  f"{name} reboot retains the new fingerprint")
        c.require(row.get("server_fingerprint") == success.get("peers", {}).get(str(new))
                  and bool(row.get("server_fingerprint")), f"{name} key matches replacement server")
        c.require(bool(row.get("frame")), f"{name} receives a fresh authenticated frame")
        c.require(len(row.get("photos", [])) == 2, f"{name} repair and reboot photos saved")
    attacks = d.get("attacks", {})
    for phase in PHASES:
        c.require(attacks.get(phase, {}).get("stable") is True, f"Public wall taps cannot advance {phase} or change trust")
    return c.finish(d)


def run(ctx):
    if ctx.tick_rate != 20:
        raise Blocked("C2 repair requires 20 TPS")
    d = {"tick_rate": ctx.tick_rate, "commit": ctx.commit, "clients": {}, "attacks": {}}
    with native_client(ctx), observed_clients(ctx):
        for name in CLIENTS:
            d["clients"][name] = {"initial": capture(ctx, name, "initial")["state"]}
        old, new = replace_server(ctx)
        d.update(old_server=old, new_server=new)
        for name in CLIENTS:
            ready(ctx, name, lambda s: s["phase"] != "live", f"{name} never noticed old server outage")
            if ctx.lua(name, '''local s=dofile("so-store.lua");local cfg=s.read("so-display.cfg") or {}
              cfg.repairServer=true;local h=assert(fs.open("so-display.cfg","w"))
              h.write(textutils.serialize(cfg));h.close();return true''') is not True:
                raise Blocked(f"Cannot enable repairServer on {name}")
        monitors = ctx.request("monitors", computer=ctx.computer("wall"))
        if not monitors:
            raise Blocked("C2 repair needs a physical monitor")
        event(ctx, "wall", "monitor_touch", next(iter(monitors)), 1, 1)
        d["attacks"]["readonly"] = wall_attack(ctx, "readonly")
        # Close the read-only view before starting terminal-authorized repair.
        if snapshot(ctx, "wall").get("step"):
            event(ctx, "wall", "char", "x")
            event(ctx, "wall", "char", "x")
        for name in CLIENTS:
            event(ctx, name, "char", "r")
            for label, step in (("change", 1), ("confirm-change", 2), ("candidate", 3), ("code", 4)):
                ready(ctx, name, lambda s: s.get("step") == step, f"{name} did not reach repair phase {step}")
                if step == 3:
                    # Confirm the actual replacement id even if discovery suggested another server.
                    while snapshot(ctx, name)["digits"]:
                        event(ctx, name, "key", 259, False)
                    event(ctx, name, "paste", str(new))
                capture(ctx, name, label)
                if name == "wall":
                    d["attacks"][label] = wall_attack(ctx, label)
                if step < 4:
                    event(ctx, name, "key", 257, False)
            row = d["clients"][name]
            row["photos"] = [photo(ctx, name, "repair")]
            invitation = ctx.wait(lambda: ctx.lua("probe", "return SO.pair.invite()"), 60)
            if not isinstance(invitation, str) or len(invitation) != 6 or not invitation.isdigit():
                raise Blocked("Replacement did not issue a six-digit invitation")
            for index, digit in enumerate(invitation):
                event(ctx, name, "char", digit)
                if name == "wall" and index == 2:
                    d["attacks"]["partial-code"] = wall_attack(ctx, "partial-code")
            row["success"] = ready(ctx, name, lambda s: repaired(s, new, old), f"{name} REPAIR did not succeed")
            row["server_fingerprint"] = ctx.lua("probe", f'''local k=SO.pair.key({ctx.computer(name)})
              return k and SO.proto.hex(SO.proto.sha256(k)):sub(1,16)''')
            # Clear the observer's previous frame before reboot, so cached data cannot pass.
            ctx.lua(name, "GATEB_FRAME=nil;return true")
            ctx.power(name, "reboot")
            row["reboot"] = ready(ctx, name, lambda s: repaired(s, new, old), f"{name} lost the replacement after reboot")
            row["frame"] = ctx.wait(lambda: ctx.request("frame", computer=ctx.computer(name)), 30)
            capture(ctx, name, "reboot")
            row["photos"].append(photo(ctx, name, "reboot"))
    return evaluate(ctx.record("C2R-observations.json", d))
