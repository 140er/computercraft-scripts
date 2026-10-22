import hashlib
import subprocess
import time
from .model import Criteria, Blocked

TITLE = "Interrupted HTTP update and recovery"


def evaluate(d):
    c = Criteria()
    for name in ("real_http_staging", "native_interruption", "old_files_unchanged", "pairing_unchanged", "old_role_rebooted", "full_update_exact", "final_rebooted"):
        c.require(d.get(name), name.replace("_", " "))
    return c.finish(d)


def run(ctx):
    before = ctx.integrity("wall")
    update_code = '''local original=http.get;local requests,failures=0,0
      http.get=function(...) requests=requests+1;local r,e,f=original(...)
        if not r or r.getResponseCode()~=200 then failures=failures+1 end;return r,e,f end
      local ok,ran=pcall(shell.run,"install","update");http.get=original
      if not ok then error(ran) end
      return {ran=ran,requests=requests,failures=failures}'''
    job = ctx.request("lua_async", computer=ctx.computer("wall"), code=update_code)
    def staged():
        result = ctx.request("files", computer=ctx.computer("wall"), path=".so-new/update.lua")
        return bool(result.get("content"))
    if not ctx.wait(staged, 90):
        raise Blocked("No real HTTP staging observed; update not interrupted")
    ctx.request("lua_cancel", computer=ctx.computer("wall"), job=job["job"])
    status = ctx.wait(lambda: ctx.request("lua_job", computer=ctx.computer("wall"), job=job["job"]).get("state") in ("done", "failed"), 30)
    if not status:
        raise Blocked("Native terminate did not stop the updater")
    interrupted = ctx.request("lua_job", computer=ctx.computer("wall"), job=job["job"])
    terminal = ctx.terminal("wall")
    native_interruption = "Terminated" in (str(interrupted.get("error", "")) + " ".join(l["text"] for l in terminal["lines"]))
    ctx.record("C14-interrupted-terminal.json", terminal)
    after_interrupt = ctx.integrity("wall")
    ctx.power("wall", "reboot")
    old_boot = ctx.wait(lambda: ctx.frame("wall").get("role") is not None, 30)
    full = ctx.request("lua_async", computer=ctx.computer("wall"), code=update_code)
    complete = ctx.wait(lambda: ctx.request("lua_job", computer=ctx.computer("wall"), job=full["job"]).get("state") in ("done", "failed"), 120)
    full_job = ctx.request("lua_job", computer=ctx.computer("wall"), job=full["job"])
    transport = (full_job.get("values") or [{}])[0]
    after_full = ctx.integrity("wall")
    exact = True
    for path, digest in after_full["files"].items():
        source = subprocess.run(["git", "show", f"{ctx.commit}:{path}"], capture_output=True)
        exact &= source.returncode == 0 and hashlib.sha256(source.stdout).hexdigest() == digest
    revision = ctx.request("files", computer=ctx.computer("wall"), path=".so-revision").get("content", "").strip()
    ctx.power("wall", "reboot")
    final_boot = ctx.wait(lambda: ctx.frame("wall").get("role") is not None, 30)
    return evaluate(ctx.record("C14-observations.json", {"real_http_staging": True, "native_interruption": native_interruption,
       "old_files_unchanged": before["files"] == after_interrupt["files"],
       "pairing_unchanged": before["pairing"] == after_interrupt["pairing"] == after_full["pairing"],
       "old_role_rebooted": bool(old_boot), "full_update_exact": bool(complete) and revision == ctx.commit and exact and transport.get("requests", 0) >= len(after_full["files"]) and transport.get("failures") == 0,
       "final_rebooted": bool(final_boot)}))
