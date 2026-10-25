import copy
from contextlib import contextmanager
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks import c2, c2_repair as repair
from checks.model import Blocked


def state(server=1, phase="live"):
    return dict(server=server, phase=phase, inputs=0, digits=0,
                peers={str(server): "aabbccddeeffaabb"}, stores={"so-keys": "aabbccdd"})


class MockWorld:
    tick_rate = 20
    run = "private"
    commit = "a" * 40

    def __init__(self, defect=None):
        self.states = {n: state() for n in repair.CLIENTS}
        self.records, self.events, self.photos, self.reboots = {}, [], [], []
        self.defect = defect

    def cli(self, *args, **kwargs):
        self.events.append(args)

    def computer(self, name):
        return {"server": 1, "probe": 10, "wall": 2, "pocket": 3}[name]

    def record(self, name, value):
        self.records[name] = copy.deepcopy(value)
        return value

    def wait(self, predicate, seconds):
        return predicate()

    def terminal(self, name):
        return {"lines": [{"text": "REPAIR"}]}

    def lua(self, name, code):
        if code == "return os.clock() >= 2":
            return True
        if code == repair.SNAPSHOT:
            return copy.deepcopy(self.states[name])
        if "cfg.repairServer=true" in code:
            self.events.append((name, "flag"))
            return True
        if "os.queueEvent('monitor_touch'" in code:
            # The real driver emits two cells per batch for this mocked physical monitor.
            for x in (1, 2):
                self.request("input", computer=2, event="monitor_touch", args=["left", x, 1])
            return True
        if code == "return SO.pair.invite()":
            return "123456"
        if "local k=SO.pair.key" in code:
            return "wrong" if self.defect == "server-key" else "aabbccddeeffaabb"
        if code == "GATEB_FRAME=nil;return true":
            return True
        raise AssertionError(code)

    def request(self, op, **kw):
        if op == "monitors":
            return {"left": {"width": 2, "height": 1}}
        name = "wall" if kw["computer"] == 2 else "pocket"
        if op == "frame":
            return None if self.defect == "frame" else {"rows": [{"text": "STATUS"}]}
        assert op == "input"
        s = self.states[name]
        kind, args = kw["event"], kw["args"]
        self.events.append((name, kind, args))
        s["inputs"] += 1
        if kind == "monitor_touch":
            if not s.get("step"):
                s.update(step=1, readonly=True)
            elif s.get("readonly"):
                s.pop("step", None); s.pop("readonly", None)
            elif self.defect == "touch-step":
                s["step"] += 1
            if self.defect == "touch-key":
                s["stores"]["so-keys"] += "x"
            if self.defect == "touch-digits":
                s["digits"] += 1
            if self.defect == "touch-server":
                s["server"] = s.get("server", 1) + 1
            if self.defect == "touch-readonly":
                s.update(step=2, readonly=False)
            return
        if s.get("readonly"):
            s["readonly"] = False
            return
        if kind == "char" and args[0] == "x":
            s.pop("step", None)
            return
        if kind == "char" and args[0] == "r":
            s["step"] = 1
        elif kind == "key" and args[0] == 257:
            s["step"] += 1
            if s["step"] == 3:
                s.pop("server", None); s["digits"] = 2
            elif s["step"] == 4:
                s["digits"] = 0
        elif kind == "key" and args[0] == 259:
            if self.defect == "backspace-swallowed":
                attempts = sum(e[:2] == (name, "key") and e[2][0] == 259 for e in self.events)
                if attempts > 9:
                    raise AssertionError("Candidate clearing exceeded nine Backspace attempts")
            else:
                s["digits"] -= 1
        elif kind == "paste":
            s["digits"] += len(args[0])
        elif kind == "char" and args[0].isdigit():
            s["digits"] += 1
            if s["digits"] == 6:
                count = s["inputs"]
                s.clear(); s.update(state(10), inputs=count)
                if self.defect == "old-peer":
                    s["peers"]["1"] = "old"

    def power(self, name, action):
        assert action == "reboot"
        self.reboots.append(name)
        if self.defect == "reboot-key":
            self.states[name]["peers"]["10"] = "different"


@contextmanager
def mocked_observer(ctx):
    yield


def mocked_replace(ctx):
    for s in ctx.states.values():
        s["phase"] = "stale"
    ctx.events.append(("replacement", 1, 10))
    return 1, 10


def mocked_photo(ctx, name, label):
    assert ctx.states[name]["digits"] == 0
    ctx.photos.append((name, label))
    return f"{name}-{label}.png"


class RepairTests(unittest.TestCase):
    def drive(self, ctx):
        with patch.object(repair, "observed_clients", mocked_observer), \
             patch.object(repair, "replace_server", mocked_replace), \
             patch.object(repair, "photo", mocked_photo):
            return repair.run(ctx)

    def test_ready_waits_for_delayed_observer_after_reboot(self):
        ctx = MockWorld()
        ctx.power("wall", "reboot")
        replies = [None, False, state(phase="stale"), state()]
        polls = []
        def lua(name, code):
            self.assertEqual((name, code), ("wall", repair.SNAPSHOT))
            return replies.pop(0)
        def wait(predicate, seconds):
            self.assertEqual(seconds, 60)
            for _ in range(4):
                polls.append(True)
                result = predicate()
                if result:
                    return result
        ctx.lua, ctx.wait = lua, wait
        result = repair.ready(ctx, "wall", lambda s: s["phase"] == "live", "Wall not ready")
        self.assertEqual(result["phase"], "live")
        self.assertEqual(len(polls), 4)

    def test_ready_reports_missing_observer_only_after_wait_expires(self):
        ctx = MockWorld()
        polls = []
        ctx.lua = lambda *args: None
        def wait(predicate, seconds):
            self.assertEqual(seconds, 60)
            for _ in range(3):
                polls.append(True)
                self.assertIsNone(predicate())
            return None
        ctx.wait = wait
        with self.assertRaisesRegex(Blocked, "Wall not ready at deadline"):
            repair.ready(ctx, "wall", lambda s: s["phase"] == "live", "Wall not ready at deadline")
        self.assertEqual(len(polls), 3)

    def test_swallowed_candidate_backspace_blocks_and_stops_client(self):
        ctx = MockWorld("backspace-swallowed")
        with self.assertRaisesRegex(Blocked, "wall candidate Backspace did not reduce digit count"):
            self.drive(ctx)
        backspaces = [e for e in ctx.events if e[:2] == ("wall", "key") and e[2][0] == 259]
        self.assertEqual(len(backspaces), 1)
        self.assertEqual(ctx.events[-1], ("client", "private", "stop"))

    def test_candidate_clearing_stops_after_nine_progressing_attempts(self):
        ctx = MockWorld()
        ctx.states["wall"].update(phase="stale", step=3, digits=10)
        with self.assertRaisesRegex(Blocked, "wall candidate did not clear within nine Backspace attempts"):
            repair.clear_candidate(ctx, "wall")
        self.assertEqual(ctx.states["wall"]["digits"], 1)
        self.assertEqual(len(ctx.events), 9)

    def test_candidate_clearing_accepts_maximum_length_id(self):
        ctx = MockWorld()
        ctx.states["wall"].update(phase="stale", step=3, digits=9)
        repair.clear_candidate(ctx, "wall")
        self.assertEqual(ctx.states["wall"]["digits"], 0)
        self.assertEqual(len(ctx.events), 9)

    def test_mock_world_drives_every_phase_and_reboots_both_clients(self):
        ctx = MockWorld()
        result = self.drive(ctx)
        self.assertEqual(result.status, "pass", result.findings)
        self.assertEqual(set(result.metrics["attacks"]), set(repair.PHASES))
        self.assertEqual(ctx.reboots, ["wall", "pocket"])
        self.assertEqual(len(ctx.photos), 4)
        self.assertEqual(ctx.events[0], ("client", "private", "start"))
        self.assertEqual(ctx.events[-1], ("client", "private", "stop"))
        self.assertEqual(sum(e[1] == "flag" for e in ctx.events), 2)
        for name in repair.CLIENTS:
            digits = [e[2][0] for e in ctx.events if e[:2] == (name, "char") and e[2][0].isdigit()]
            self.assertEqual("".join(digits), "123456")
        saved = json.dumps(ctx.records)
        self.assertNotIn("123456", saved)
        self.assertIn('"digits": 3', saved)

    def test_failure_findings_from_mocked_world(self):
        for defect in ("server-key", "reboot-key", "frame", "touch-step", "touch-key",
                       "touch-digits", "touch-server", "touch-readonly"):
            with self.subTest(defect=defect):
                self.assertEqual(self.drive(MockWorld(defect)).status, "fail")
        with self.assertRaises(Blocked):
            self.drive(MockWorld("old-peer"))

    def test_wall_attacks_detect_step_key_digit_and_server_changes(self):
        for defect in ("touch-step", "touch-key", "touch-digits", "touch-server"):
            ctx = MockWorld(defect)
            ctx.states["wall"].update(phase="stale", step=3)
            self.assertFalse(repair.wall_attack(ctx, "candidate")["stable"])
        good = self.drive(MockWorld()).metrics
        for phase in repair.PHASES:
            bad = copy.deepcopy(good)
            bad["attacks"][phase]["stable"] = False
            self.assertEqual(repair.evaluate(bad).status, "fail")

    def test_evaluator_rejects_missing_evidence_and_stale_peer(self):
        good = self.drive(MockWorld()).metrics
        for field in ("initial", "success", "reboot", "server_fingerprint", "frame", "photos"):
            bad = copy.deepcopy(good)
            del bad["clients"]["wall"][field]
            self.assertEqual(repair.evaluate(bad).status, "fail", field)
        for field, value in (("tick_rate", 80), ("new_server", 1)):
            bad = copy.deepcopy(good); bad[field] = value
            self.assertEqual(repair.evaluate(bad).status, "fail")
        bad = copy.deepcopy(good)
        bad["clients"]["pocket"]["success"]["peers"]["1"] = "old"
        self.assertEqual(repair.evaluate(bad).status, "fail")

    def test_opt_in_dispatch_and_20_tps_guard(self):
        with patch.dict("os.environ", {"GATEB_C2_REPAIR": "1"}), patch.object(repair, "run", return_value="repair"):
            self.assertEqual(c2.run(object()), "repair")
        ctx = MockWorld(); ctx.tick_rate = 80
        with self.assertRaises(Blocked):
            repair.run(ctx)

    def test_observer_loader_captures_real_entry_without_writing_source(self):
        script = '''local source = 'local C={digits="",phase="stale",server=1,pair={list=function() return {} end}}\\n'
          .. 'C.fixInput=function(...) return ... end;C.loop=function() end;C.loop()\\n'
          fs={open=function(path,mode) assert(mode=="r");if path~="/display.lua" then return nil end;return {readAll=function() return source end,close=function() end} end}
          local loader=assert(loadfile("tools/gateb/c2_repair_loader.lua"))()
          local env=setmetatable({}, {__index=_G})
          assert(loader("/display.lua",env))()
          assert(env.GATEB_REPAIR().server==1)
          assert(env.GATEB_REPAIR().digits==0)
          assert(env.GATEB_REPAIR().inputs==0)
          assert(not env.GATEB_REPAIR().keys)
          source="return true"
          assert(not pcall(loader,"/display.lua",env))
        '''
        result = subprocess.run(["lua5.2", "-"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_replacement_copies_pinned_programs_without_old_credentials(self):
        import world
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            class Runtime:
                def computer_disk(self, run, cid): return root / str(cid)
                def run(self, run): return root
                def manifest(self, run):
                    return {"computers": {"1": {"role": "server"}, "10": {"role": "display"}}}
            ctx = MockWorld(); ctx.runtime = Runtime()
            source, spare = root / "1", root / "10"
            source.mkdir(); spare.mkdir()
            for file in ("so-server.lua", ".so-files", ".so-revision"):
                (source / file).write_text("pinned")
            (source / "so-keys").write_text("old credential fixture")
            (spare / "so-keys").write_text("probe credential fixture")
            powers = []
            ctx.power = lambda name, action: powers.append((name, action))
            ctx.lua = lambda *args: True
            with patch.object(world, "installer_manifest", return_value=["so-server.lua"]):
                self.assertEqual(repair.replace_server(ctx), (1, 10))
            self.assertFalse((spare / "so-keys").exists())
            self.assertEqual((spare / "so-server.lua").read_text(), "pinned")
            self.assertEqual(ctx.manifest["computers"]["10"]["role"], "server")
            self.assertEqual(powers, [("server", "off"), ("probe", "off"), ("probe", "on")])

    def test_observed_clients_restores_runtime_loader_after_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            class Runtime:
                def computer_disk(self, run, cid):
                    return Path(tmp) / str(cid)
                def instrument(self, disk, role):
                    disk.mkdir(parents=True, exist_ok=True)
                    (disk / "gateb-bridge.lua").write_text("local fn,why=loadfile('/'..assert(programs[role]),env)")
                    return "boot"
            ctx = MockWorld(); ctx.runtime = Runtime(); ctx.run = "private"
            original = ctx.runtime.instrument
            def power(name, action):
                ctx.runtime.instrument(ctx.runtime.computer_disk(ctx.run, ctx.computer(name)), "display")
            ctx.power = power
            with self.assertRaisesRegex(RuntimeError, "stop"):
                with repair.observed_clients(ctx):
                    bridge = (Path(tmp) / "2/gateb-bridge.lua").read_text()
                    self.assertIn("gateb-c2-repair-loader.lua", bridge)
                    raise RuntimeError("stop")
            self.assertEqual(ctx.runtime.instrument, original)


if __name__ == "__main__":
    unittest.main()
