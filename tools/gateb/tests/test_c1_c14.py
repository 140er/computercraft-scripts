import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks import c1, c14
from checks.context import Context, HTTP_UPDATE, pinned_http_update, wait_http_update
from checks.model import Blocked


class ClientTests(unittest.TestCase):
    def run_c1(self, active=(), ready=True, install_error=False):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            ctx = Context(SimpleNamespace(status=lambda: dict.fromkeys(active)), "world", {}, temp, "a" * 40)
            def frame(name):
                calls.append(("frame", name))
                if not ready:
                    raise Blocked("Pocket offline")
                return {"role": "generic"}
            def install(*args):
                calls.append(("install",))
                if install_error:
                    raise RuntimeError("Install failed")
                return "installed"
            with patch.object(c1.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=ctx.commit)), \
                    patch.object(ctx, "cli", side_effect=lambda *args, **kw: calls.append(args)), \
                    patch.object(ctx, "frame", side_effect=frame), \
                    patch.object(ctx, "wait", side_effect=lambda fn, seconds: fn()), \
                    patch.object(c1, "install_roles", side_effect=install):
                if not ready or install_error:
                    with self.assertRaises(RuntimeError):
                        c1.run(ctx)
                else:
                    self.assertEqual(c1.run(ctx), "installed")
        return calls

    def test_standalone_starts_client_before_pocket_and_stops_it(self):
        self.assertEqual(self.run_c1(), [("client", "world", "start"), ("frame", "pocket"),
                                         ("install",), ("client", "world", "stop")])

    def test_linked_run_keeps_the_existing_c3_client(self):
        self.assertEqual(self.run_c1(("world:client", "world:xvfb")), [("frame", "pocket"), ("install",)])

    def test_partial_client_is_repaired_and_cleaned_up(self):
        for active in (("world:client",), ("world:xvfb",)):
            with self.subTest(active=active):
                self.assertEqual(self.run_c1(active), self.run_c1())

    def test_client_cleanup_on_readiness_or_install_failure(self):
        for options in ({"ready": False}, {"install_error": True}):
            with self.subTest(options=options):
                calls = self.run_c1(**options)
                self.assertEqual(calls[-1], ("client", "world", "stop"))
                if options.get("ready") is False:
                    self.assertNotIn(("install",), calls)


class UpdateContext:
    commit = "a" * 40

    def __init__(self, **changes):
        self.jobs, self.records, self.reboots, self.integrities = [], {}, [], 0
        self.transport = {"requests": 2, "failures": 0, "running": True, "program": "/display.lua"}
        self.job_state, self.revision, self.payload = "running", self.commit, b"display contents"
        self.exact, self.paired, self.unchanged, self.terminated = True, True, True, True
        self.boots, self.staged, self.cancelled = [True, True], True, True
        self.__dict__.update(changes)

    def computer(self, name): return 2
    def terminal(self, name): return {"lines": [{"text": "Press P"}]}
    def record(self, name, value): self.records[name] = value; return value
    def power(self, name, action): self.reboots.append((name, action))
    def frame(self, name): return {"role": "generic" if self.boots.pop(0) else None}
    def lua(self, name, code): return self.transport
    def wait(self, predicate, seconds): return predicate()

    def integrity(self, name):
        self.integrities += 1
        files = {"display.lua": hashlib.sha256(self.payload).hexdigest()}
        if self.integrities == 2 and not self.unchanged:
            files["display.lua"] = "interrupted write"
        if self.integrities == 3 and not self.exact:
            files["display.lua"] = "wrong hash"
        return {"files": files, "pairing": {"fingerprint": "changed" if self.integrities == 3 and not self.paired else "original"}}

    def request(self, op, **kwargs):
        if op == "lua_async":
            self.jobs.append(kwargs["code"])
            return {"job": str(len(self.jobs))}
        if op == "files": return {"content": self.revision if kwargs["path"] != ".so-new/update.lua" or self.staged else ""}
        if op == "lua_job":
            if kwargs["job"] == "1":
                return {"state": "failed" if self.cancelled else "running", "error": "Terminated" if self.terminated else "Other error"}
            return {"state": self.job_state}
        return {}


class UpdateTests(unittest.TestCase):
    def run_c14(self, ctx):
        with patch.object(c14.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=ctx.payload)):
            return c14.run(ctx)

    def test_running_role_with_exact_files_passes_without_job_exit(self):
        ctx = UpdateContext()
        self.assertEqual(self.run_c14(ctx).status, "pass")
        self.assertEqual(ctx.jobs, [pinned_http_update(ctx.commit)] * 2)
        self.assertEqual(ctx.reboots, [("wall", "reboot")] * 2)
        proof = ctx.records["C14-full-update.json"]
        self.assertTrue(proof["role_running"])
        self.assertEqual(proof["job"]["state"], "running")

    def test_every_other_c14_assertion_remains_required(self):
        for changes in ({"exact": False}, {"revision": "b" * 40}, {"paired": False},
                        {"unchanged": False}, {"terminated": False},
                        {"boots": [False, True]}, {"boots": [True, False]},
                        {"transport": {"requests": 0, "failures": 0, "running": True, "program": "/display.lua"}},
                        {"transport": {"requests": 2, "failures": 1, "running": True, "program": "/display.lua"}},
                        {"transport": {"requests": 2, "failures": 0, "running": True, "program": "/worker.lua"}},
                        {"job_state": "failed"}, {"job_state": "done"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.run_c14(UpdateContext(**changes)).status, "fail")

    def test_staging_and_native_cancellation_are_still_required(self):
        for changes, reason in (({"staged": False}, "No real HTTP staging"),
                                ({"cancelled": False}, "Native terminate")):
            with self.subTest(changes=changes), self.assertRaisesRegex(Blocked, reason):
                self.run_c14(UpdateContext(**changes))

    def test_installer_still_running_is_not_a_running_role(self):
        ctx = UpdateContext(transport={"requests": 2, "failures": 0})
        self.assertIsNone(wait_http_update(ctx, "wall", {"job": "2"}, "/display.lua", 120))
        self.assertEqual(self.run_c14(ctx).status, "fail")

    @unittest.skipUnless(shutil.which("lua5.2"), "Lua 5.2 unavailable")
    def test_live_transport_and_role_entry_before_the_event_loop_returns(self):
        source = '''http={get=function() return {getResponseCode=function() return 200 end} end}
          shell={run=function(program,action)
            if program=="install" then
              assert(action=="update");http.get("payload")
              print("Install rolled back: simulated failure")
              return shell.run("/display.lua")
            end
            assert(program=="/display.lua")
            assert(http.get==savedGet and print==savedPrint and shell.run==savedRun)
            coroutine.yield("role-event")
            return true
          end}
          savedGet=http.get;savedPrint=print;savedRun=shell.run
          GATEB_HTTP_UPDATE={requests=99,running=true,program="/worker.lua"}
          GATEB_FRAME={role="stale"}
          local co=coroutine.create(assert(load(CODE)))
          local ok,event=coroutine.resume(co)
          assert(ok,event);assert(event=="role-event" and coroutine.status(co)=="suspended")
          assert(GATEB_HTTP_UPDATE.program=="/display.lua" and GATEB_HTTP_UPDATE.running)
          assert(GATEB_HTTP_UPDATE.requests==1 and GATEB_HTTP_UPDATE.failures==1)
          assert(GATEB_FRAME==nil)
          local resumed,result=coroutine.resume(co)
          assert(resumed and result.ran and not result.running)
        '''.replace("CODE", json.dumps(HTTP_UPDATE))
        done = subprocess.run(["lua5.2", "-"], input=source, text=True, capture_output=True)
        self.assertEqual(done.returncode, 0, done.stderr)


if __name__ == "__main__": unittest.main()
