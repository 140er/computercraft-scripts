import hashlib
from contextlib import ExitStack
import subprocess
from .model import Criteria, Blocked, pocket_frame
from .context import HTTP_UPDATE, wait_http_update

TITLE = "Normal install and reboot"


def evaluate(d):
    c = Criteria()
    c.require(d.get("normal_http_install"), "Normal HTTP installer used on all six roles")
    c.require(d.get("install_errors") == [] if "install_errors" in d else None, "No initial install error, including successful retries")
    c.require(d.get("exact_files"), "Installed role files match the exact requested commit")
    c.require(d.get("rebooted_roles", 0) == 6, "All six roles survive native reboot")
    return c.finish(d)


def run(ctx):
    names = ("server", "wall", "pocket", "miner1", "miner2", "lumber")
    current = subprocess.run(["git", "ls-remote", "origin", "refs/heads/server-only"], capture_output=True, text=True)
    if current.returncode or not current.stdout.split() or current.stdout.split()[0] != ctx.commit:
        raise Blocked("Normal HTTP installer must resolve the exact requested server-only tip")
    with ExitStack() as cleanup:
        status = ctx.runtime.status()
        if not all(ctx.run + suffix in status for suffix in (":client", ":xvfb")):
            cleanup.callback(ctx.cli, "client", ctx.run, "stop")
            ctx.cli("client", ctx.run, "start", timeout=180)
        pocket_frame(ctx)
        return install_roles(ctx, names)


def install_roles(ctx, names):
    exact, rebooted, errors, transports = True, 0, [], {}
    for name in names:
        ctx.wait(lambda: bool(ctx.terminal(name).get("lines")), 30)
        job = ctx.request("lua_async", computer=ctx.computer(name), code=HTTP_UPDATE)
        program = "/so-server.lua" if name == "server" else "/display.lua" if name in ("wall", "pocket") else "/worker.lua"
        finished = wait_http_update(ctx, name, job, program, 180)
        if not finished:
            ctx.request("lua_cancel", computer=ctx.computer(name), job=job["job"])
            errors.append(f"{name} HTTP installation timed out")
            continue
        transport = finished["transport"]
        files = ctx.integrity(name)["files"]
        transports[name] = transport
        if not finished["role_running"] or transport.get("failures") != 0 or transport.get("requests", 0) < len(files):
            errors.append(f"{name} normal HTTP installation failed")
        for path, digest in files.items():
            source = subprocess.run(["git", "show", f"{ctx.commit}:{path}"], capture_output=True)
            exact &= source.returncode == 0 and hashlib.sha256(source.stdout).hexdigest() == digest
        ctx.power(name, "reboot")
        def healthy():
            if name == "server":
                return ctx.lua("server", "return SO and SO.mods and SO.mods.state ~= nil")
            if name in ("wall", "pocket"):
                return bool(ctx.frame(name).get("role"))
            ident = ctx.computer(name)
            return ctx.lua("server", f'local m=SO.mods.state.get("machines/{ident}"); local l=SO.mods.lease.status({ident}); return m and (m.role=="turtle" or m.role=="worker") and l and not l.lost and (SO.now and SO.now() or os.epoch("utc"))-(l.seen or 0)<30000')
        if ctx.wait(healthy, 30): rebooted += 1
        ctx.record(f"C1-{name}-terminal.json", ctx.terminal(name))
    return evaluate(ctx.record("C1-observations.json", {"normal_http_install": len(transports) == 6,
                    "install_errors": errors, "exact_files": exact, "rebooted_roles": rebooted,
                    "http_transports": transports}))
