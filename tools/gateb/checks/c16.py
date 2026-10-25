"""Exercise server-triggered pinned updates through the native worker loop."""
import hashlib
import json
from urllib.error import URLError
from urllib.request import Request, urlopen

from .model import Blocked, Criteria
from . import update_fixture

TITLE = "Ten simultaneous pinned worker updates at 20 TPS"
CRITERIA = ("simultaneous_updates", "budget_refused_unchanged", "ancestry_refused_unchanged", "paired_lease_recovery")


def evaluate(data):
    criteria = Criteria()
    criteria.require(data.get("worker_count", 0) >= 10, "At least ten native turtle workers")
    criteria.require(data.get("tick_rate") == 20, "Pinned updates run at 20 TPS")
    for name in CRITERIA:
        criteria.require(data.get(name), name.replace("_", " "))
    return criteria.finish(data)


def rate_limit(ctx, phase):
    try:
        request = Request("https://api.github.com/rate_limit", headers={"User-Agent": "gateb-c16", "Accept": "application/vnd.github+json"})
        # No Authorization header or gh credentials. This is the host's shared quota.
        with urlopen(request, timeout=20) as response:
            payload = json.load(response)
        core = payload["resources"]["core"]
        if type(core["remaining"]) is not int or not 0 <= core["remaining"] <= 60 or core["limit"] != 60:
            raise ValueError("Expected the unauthenticated 60-call core quota")
    except (OSError, URLError, ValueError, KeyError, TypeError) as error:
        ctx.record(f"C16-budget-{phase}.json", {"error": str(error)})
        raise Blocked("C16 cannot verify the host's unauthenticated GitHub API quota") from error
    return ctx.record(f"C16-budget-{phase}.json", {"remaining": core["remaining"], "limit": core["limit"], "reset": core.get("reset")})


def admit_budget(ctx):
    before = rate_limit(ctx, "before")
    if before["remaining"] < 40:
        raise Blocked(f"C16 requires at least 40 unauthenticated GitHub API calls; {before['remaining']} remain")
    return before


def trace(ctx, name):
    result = ctx.request("files", computer=ctx.computer(name), path=".gateb/c16-trace.json")
    return json.loads(result.get("content") or "{}")


def status(ctx, names):
    ids = [ctx.computer(name) for name in names]
    return ctx.lua("server", '''local out={};for _,id in ipairs(IDS) do
      out[tostring(id)]={update=SO.workerUpdate(id),lease=SO.mods.lease.peek(id),paired=SO.pair.key(id)~=nil}
      end;return out'''.replace("IDS", "{" + ",".join(map(str, ids)) + "}")) or {}


def idle(rows, count):
    return len(rows) == count and all(row.get("paired") and row.get("lease")
        and not any(row["lease"].get(k) for k in ("open", "probing", "uncertain", "lost"))
        and (row.get("update") or {}).get("running") for row in rows.values())


def dispatch(ctx, names):
    ids = ",".join(str(ctx.computer(name)) for name in names)
    return ctx.record("C16-dispatch.json", ctx.lua("server", '''local out={};local started=SO.now()
      for _,id in ipairs({IDS}) do local rid,why=SO.updateWorker(id)
        out[tostring(id)]={rid=rid,reason=why} end
      return {workers=out,span_game_ms=SO.now()-started}'''.replace("IDS", ids)))


def park_round(ctx, names, label):
    ids = ",".join(str(ctx.computer(name)) for name in names)
    sent = ctx.lua("server", '''local out={};for _,id in ipairs({IDS}) do
      local rid,why=SO.mods.lease.send(id,{{op="inspectDown",park=true}},{owner="gateb-c16",ms=15000,recover=true})
      out[tostring(id)]={lease=rid,reason=why} end;return out'''.replace("IDS", ids)) or {}
    def complete():
        rows = status(ctx, names)
        if idle(rows, len(names)) and all(row["lease"].get("last", {}).get("status") == "reported"
                                        and row["lease"]["last"].get("ok") is True for row in rows.values()):
            return rows
        return None
    rows = ctx.wait(complete, 45)
    ctx.record(f"C16-{label}-leases.json", {"sent": sent, "settled": rows})
    return bool(rows) and len(sent) == len(names) and all(v.get("lease") for v in sent.values())


def fingerprint(ctx, name):
    marker = ctx.request("files", computer=ctx.computer(name), path=".so-revision").get("content", "").strip()
    return {**ctx.integrity(name), "revision": marker, "journal": ctx.read_store(name, "so-journal")}


def unchanged(before, after):
    # A refusal may save only the API cooldown in the role config.
    return all(before.get(k) == after.get(k) for k in ("files", "pairing", "revision", "journal"))


def refusal(ctx, name, previous, budget=False):
    before = fingerprint(ctx, name)
    start = len(trace(ctx, name).get("events", []))
    if budget:
        remaining = getattr(ctx, "c16_fake_remaining", 0)
        if type(remaining) is not int or not 0 <= remaining < 3:
            raise Blocked("C16 fake remaining must be 0, 1 or 2 after the first API response")
        ctx.lua(name, f'''local h=assert(fs.open('/.gateb/c16-fake-remaining','w'));h.write('{remaining}');h.close();return true''')
        dispatch(ctx, [name])
    else:
        ident = ctx.computer(name)
        # Equal ancestry must reach the worker. The public server API refuses it
        # locally, so use the server's real authenticated transport for this probe.
        ctx.lua("server", f'''local id={ident};local key=assert(SO.pair.key(id))
          local m=SO.proto.build(key,'worker.update',{{revision={json.dumps(previous)}}})
          return rednet.send(id,SO.proto.encode(m),'so')''')
    kind = "budget" if budget else "ancestry"
    def refused():
        events = trace(ctx, name).get("events", [])[start:]
        if any(e["kind"] == ("reboot" if budget else "err") for e in events):
            return events
        return None
    events = ctx.wait(refused, 60) or []
    if budget:
        ctx.wait(lambda: trace(ctx, name).get("boots", 0) >= 2, 45)
    after = fingerprint(ctx, name)
    terminal = next((e["terminal"] for e in events if e["kind"] == "reboot"), None) if budget else ctx.terminal(name)
    text = " ".join(line.get("text", "") for line in (terminal or {}).get("lines", []))
    if budget:
        refused_ok = any(e["kind"] == "fake_budget" for e in events) and "Update API refused" in text
        refused_ok &= not any(e["kind"] == "api" for e in events)
    else:
        refused_ok = any(e["kind"] == "err" and e.get("text") == "invalid revision" for e in events)
        refused_ok &= "invalid revision" in text and not any(e["kind"] in ("handoff", "reboot", "api") for e in events)
    ctx.record(f"C16-{kind}-refusal.json", {"before": before, "after": after, "events": events, "terminal": terminal})
    return bool(refused_ok and unchanged(before, after))


def updated(ctx, name, previous, before):
    after = fingerprint(ctx, name)
    events = trace(ctx, name).get("events", [])[before["events"]:]
    ordered = False
    accepted = handed_off = rebooted = None
    for event in events:
        if event["kind"] == "ack" and event.get("revision") == ctx.commit and event.get("state") == "accepted":
            accepted = event["boot"]
        elif event["kind"] == "handoff" and accepted == event["boot"] and event.get("revision") == ctx.commit:
            handed_off = event["boot"]
        elif event["kind"] == "reboot" and handed_off == event["boot"]:
            rebooted = event["boot"]
        elif event["kind"] == "hello" and rebooted is not None and event["boot"] > rebooted and event.get("revision") == ctx.commit:
            ordered = True
    exact = bool(after["files"]) and all(hashlib.sha256(update_fixture.git("show", f"{ctx.commit}:{path}")).hexdigest() == digest
                                        for path, digest in after["files"].items())
    hello = any(e["kind"] == "hello" and e.get("revision") == ctx.commit for e in events)
    ack = any(e["kind"] == "ack" and e.get("revision") == ctx.commit and e.get("state") == "accepted" for e in events)
    handoff = any(e["kind"] == "handoff" and e.get("revision") == ctx.commit and e.get("running") == previous for e in events)
    api = [e for e in events if e["kind"] == "api"]
    ctx.record(f"C16-{name}-update.json", {"before": before, "after": after, "events": events, "exact": exact})
    return bool(ordered and ack and handoff and hello and exact and after["revision"] == ctx.commit
                and len(api) == 4 and after["pairing"] == before["fingerprint"]["pairing"]
                and after["journal"] == before["fingerprint"]["journal"])


def run(ctx):
    try:
        admit_budget(ctx)
        if ctx.tick_rate != 20:
            raise Blocked("C16 requires 20 TPS")
        previous = update_fixture.baseline(ctx.commit)
        names = update_fixture.prepare(ctx, previous)
        if len(names) < 10:
            raise Blocked("C16 requires at least ten native turtle workers in one world")
        if not ctx.wait(lambda: idle(status(ctx, names), len(names)), 90):
            raise Blocked("C16 fixture workers did not pair and become idle")
        if not park_round(ctx, names, "before"):
            raise Blocked("C16 fixture did not complete the initial park leases")
        # A report closes the server lease, but the worker retains its 15-second
        # deadline. Allow that deadline and the next 30-second hello to pass so
        # the real idle guard can confirm unassignment before the update probes.
        ctx.sleep(46)
        ancestry = refusal(ctx, names[0], previous)
        budget = refusal(ctx, names[0], previous, budget=True)
        # Clear only the test's saved cooldown and HTTP injection. A fresh server
        # boot clears the in-memory awaiting-reboot request from the refused update.
        ctx.lua(names[0], '''fs.delete('/.gateb/c16-fake-remaining')
          local s=dofile('/so-store.lua');local cfg=s.readConfig('so-worker.cfg')
          cfg.updateApiRetryAt=nil;assert(s.saveConfig('so-worker.cfg',cfg));return true''')
        ctx.power("server", "reboot")
        if not ctx.wait(lambda: idle(status(ctx, names), len(names)), 90):
            raise Blocked("C16 server did not recover its fixture peers")
        # Recheck immediately before the ten real four-call update attempts.
        quota = rate_limit(ctx, "dispatch")
        if quota["remaining"] < 40:
            raise Blocked("C16 quota fell below 40 before simultaneous dispatch")
        before = {name: {"fingerprint": fingerprint(ctx, name), "events": len(trace(ctx, name).get("events", []))} for name in names}
        sent = dispatch(ctx, names)
        def complete():
            rows = status(ctx, names)
            return rows if len(rows) == len(names) and all((row.get("update") or {}).get("state") == "complete"
                and row["update"].get("running") == ctx.commit for row in rows.values()) else None
        completed = ctx.wait(complete, 180)
        ctx.record("C16-post-update-server.json", completed or status(ctx, names))
        proofs = [updated(ctx, name, previous, before[name]) for name in names]
        simultaneous = bool(sent and sent["span_game_ms"] <= 50 and len(sent["workers"]) == len(names)
                            and all(v.get("rid") for v in sent["workers"].values()) and completed and all(proofs))
        recovery = park_round(ctx, names, "after")
        return evaluate(ctx.record("C16-observations.json", {"worker_count": len(names), "tick_rate": ctx.tick_rate,
            "simultaneous_updates": simultaneous, "budget_refused_unchanged": budget,
            "ancestry_refused_unchanged": ancestry, "paired_lease_recovery": recovery,
            "baseline": previous, "target": ctx.commit, "budget_mode": "HTTP 403 with configurable remaining header"}))
    finally:
        rate_limit(ctx, "after")
