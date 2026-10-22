import hashlib
import subprocess
from .model import Criteria

TITLE = "Normal install and reboot"


def evaluate(d):
    c = Criteria()
    c.require(d.get("normal_http_install"), "Normal HTTP installer used on all six roles")
    c.require(d.get("install_errors") == [] if "install_errors" in d else None, "No initial install error, including successful retries")
    c.require(d.get("exact_files"), "Installed role files match the exact requested commit")
    c.require(d.get("rebooted_roles", 0) == 6, "All six roles survive native reboot")
    return c.finish(d)


def run(ctx):
    install = ctx.cli("install", ctx.run, ctx.commit, "--mode", "http", timeout=300)
    names = ("server", "wall", "pocket", "miner1", "miner2", "lumber")
    exact, rebooted = True, 0
    for name in names:
        for path, digest in ctx.integrity(name)["files"].items():
            source = subprocess.run(["git", "show", f"{ctx.commit}:{path}"], capture_output=True)
            exact &= source.returncode == 0 and hashlib.sha256(source.stdout).hexdigest() == digest
        ctx.power(name, "reboot")
        if ctx.wait(lambda: bool(ctx.terminal(name).get("lines")), 30): rebooted += 1
        ctx.record(f"C1-{name}-terminal.json", ctx.terminal(name))
    return evaluate(ctx.record("C1-observations.json", {"normal_http_install": install.get("mode") == "http",
                    "install_errors": install.get("errors"), "exact_files": exact, "rebooted_roles": rebooted}))
