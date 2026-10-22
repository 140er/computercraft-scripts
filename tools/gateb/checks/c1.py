import hashlib
import subprocess
from .model import Criteria, Blocked
from .context import HTTP_UPDATE

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
    exact, rebooted, errors, transports = True, 0, [], {}
    current = subprocess.run(["git", "ls-remote", "origin", "refs/heads/server-only"], capture_output=True, text=True)
    if current.returncode or not current.stdout.split() or current.stdout.split()[0] != ctx.commit:
        raise Blocked("Normal HTTP installer must resolve the exact requested server-only tip")
    for name in names:
        ctx.wait(lambda: bool(ctx.terminal(name).get("lines")), 30)
        job = ctx.request("lua_async", computer=ctx.computer(name), code=HTTP_UPDATE)
        finished = ctx.wait(lambda: ctx.request("lua_job", computer=ctx.computer(name), job=job["job"]).get("state") in ("done", "failed"), 180)
        if not finished:
            ctx.request("lua_cancel", computer=ctx.computer(name), job=job["job"])
            errors.append(f"{name} HTTP installation timed out")
            continue
        status = ctx.request("lua_job", computer=ctx.computer(name), job=job["job"])
        transport = (status.get("values") or [{}])[0]
        files = ctx.integrity(name)["files"]
        transports[name] = transport
        if status.get("state") != "done" or transport.get("failures") != 0 or transport.get("requests", 0) < len(files):
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
            return ctx.lua("server", f'local m=SO.mods.state.get("machines/{ident}"); return m and m.role=="worker" and os.epoch("utc")-(m.seen or 0)<30000')
        if ctx.wait(healthy, 30): rebooted += 1
        ctx.record(f"C1-{name}-terminal.json", ctx.terminal(name))
    return evaluate(ctx.record("C1-observations.json", {"normal_http_install": len(transports) == 6,
                    "install_errors": errors, "exact_files": exact, "rebooted_roles": rebooted,
                    "http_transports": transports}))
