"""Provision ten paired native turtles in the driver's private world."""
import json
from pathlib import Path
import secrets
import subprocess
import tempfile

from .model import Blocked

ROOT = Path(__file__).resolve().parents[3]


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True)
    if result.returncode:
        raise Blocked("C16 cannot read the required server-only history")
    return result.stdout


def baseline(target):
    git("merge-base", "--is-ancestor", target, "origin/server-only")
    for sha in git("rev-list", "--first-parent", target + "^").decode().splitlines():
        installer = git("show", sha + ":install.lua")
        worker = git("show", sha + ":worker.lua")
        if b"worker-update" in installer and b"pinnedUpdate = true" in worker:
            git("merge-base", "--is-ancestor", sha, target)
            return sha
    raise Blocked("C16 needs a strictly older server-only ancestor with pinned worker updates")


def outside_revision(ctx):
    tip = git("rev-parse", "origin/server-only^{commit}").decode().strip()
    refs = git("for-each-ref", "--sort=-committerdate", "--format=%(objectname) %(refname)",
               "refs/remotes/origin/").decode().splitlines()
    for ref in refs:
        sha, name = ref.split(" ", 1)
        result = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", sha, tip], capture_output=True)
        if result.returncode not in (0, 1):
            raise Blocked("C16 cannot verify the ancestry probe's commit")
        if result.returncode == 1:
            ctx.record("C16-outside-ancestry.json", {"revision": sha, "ref": name, "server_only_tip": tip,
                       "method": "git merge-base --is-ancestor", "exit_code": result.returncode})
            return sha
    raise Blocked("C16 needs a real remote commit outside server-only ancestry")


def worker_files(revision):
    from world import installer_manifest
    with tempfile.TemporaryDirectory(prefix="gateb-c16-") as temp:
        source = Path(temp)
        (source / "install.lua").write_bytes(git("show", revision + ":install.lua"))
        paths = installer_manifest(source, "worker")
    tree = {}
    for entry in git("ls-tree", "-r", "-z", revision).split(b"\0"):
        if entry:
            metadata, path = entry.split(b"\t", 1)
            tree[path.decode()] = metadata.split()[:2]
    if any(tree.get(path) not in ([b"100644", b"blob"], [b"100755", b"blob"]) for path in paths):
        raise Blocked("C16 target tree lacks a regular file required by the worker role")
    return {path: git("show", revision + ":" + path) for path in paths}


def prepare(ctx, previous):
    # Use the same manifest parser and generation writer as the native runtime.
    from world import atomic
    from fixtures import store, lua

    if not ctx.run.startswith("driver-"):
        raise Blocked("C16 provisioning requires an owned driver world")
    runtime = ctx.runtime
    manifest = ctx.manifest
    names = []
    for info in manifest["computers"].values():
        if info["role"] == "worker":
            ctx.power(info["name"], "off")
    contents = worker_files(previous)
    files = list(contents)
    server_id = str(ctx.computer("server"))
    keys = {}
    commands = []
    for index in range(10):
        ident = str(100 + index)
        name = f"c16-{index + 1}"
        disk = runtime.run(ctx.run) / "world/computercraft/computer" / ident
        if ident in manifest["computers"] or disk.exists():
            raise Blocked("C16 fixture IDs 100..109 must be unused in the private world")
        pos = [12 + 2 * index, 64, -12]
        xyz = " ".join(map(str, pos))
        for command in (f"setblock {pos[0]} 63 -12 minecraft:stone",
                        f'setblock {xyz} computercraft:turtle_advanced[facing=north]'
                        + '{ComputerId:' + ident + ',On:0b,Fuel:10000,RightUpgrade:{id:"computercraft:wireless_modem_normal"},Items:[]}',
                        f"data get block {xyz} ComputerId"):
            result = ctx.command(command)
            commands.append({"command": command, "result": result})
        if f"has the following block data: {ident}" not in result.get("output", ""):
            raise Blocked("C16 native turtle placement could not be verified")
        disk.mkdir(parents=True, exist_ok=True)
        for path, content in contents.items():
            dest = disk / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(content)
        (disk / ".so-files").write_text(lua(files))
        (disk / ".so-revision").write_text(previous)
        (disk / "so-worker.cfg").write_text(lua({"remoteUpdates": True, "server": int(server_id)}))
        keys[ident] = secrets.token_hex(32)
        store(disk / "so-keys", {"keys": {server_id: keys[ident]}})
        runtime.instrument(disk, "worker")
        (disk / ".gateb/c16-hook.lua").write_bytes((ROOT / "tools/gateb/c16-hook.lua").read_bytes())
        manifest["computers"][ident] = {"name": name, "role": "worker", "kind": "turtle", "pos": pos, "facing": "north"}
        names.append(name)
    atomic(runtime.run(ctx.run) / "manifest.json", manifest)
    ctx.record("C16-native-fixture.json", {"computers": {i: v for i, v in manifest["computers"].items() if v["name"] in names},
                                           "commands": commands, "baseline": previous, "target": ctx.commit})
    # Seed private fixture keys without putting them in a request or evidence.
    seed = runtime.computer_disk(ctx.run, "server") / ".gateb/c16-pair-seed"
    seed.write_text(lua(keys))
    try:
        paired = ctx.lua("server", '''local h=assert(fs.open('/.gateb/c16-pair-seed','r'))
          local keys=textutils.unserialize(h.readAll());h.close()
          for id,key in pairs(keys) do assert(SO.pair.remember(tonumber(id),key)) end
          local s=dofile('/so-store.lua');local cfg=s.readConfig('so-server.cfg') or {}
          cfg.panelUpdates=true;assert(s.saveConfig('so-server.cfg',cfg));return true''')
        if paired is not True:
            raise Blocked("C16 fixture pairing or update opt-in failed")
    finally:
        seed.unlink(missing_ok=True)
    for name in names:
        ctx.power(name, "on")
    return names
