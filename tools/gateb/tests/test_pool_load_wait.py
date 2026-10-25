import contextlib
import fcntl
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keeper
import run
import world
from checks.context import Context
from checks.model import Blocked
from test_load_wait import Clock


class PoolLoadWaitTests(unittest.TestCase):
    def pool(self, loads, race=False):
        clock = Clock()
        active = {}
        cleanups = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runtime = world.Runtime(root / "runtime")
            ctx = Context(None, "", {}, root / "report", "a" * 40)
            ctx.load_wait_timeout = 12
            refused = False

            def clone(name): runtime.run(name).mkdir(parents=True)

            def serve(name, timeout):
                nonlocal refused
                if race and name == "fixture-2" and not refused:
                    refused = True
                    raise keeper.LoadAdmissionRefused("Pool admission refused: load1=11.00 must be below 8; MemAvailable=16.00 GiB must exceed 8 GiB")
                active[name] = 1
                return {}

            def sleep(seconds):
                # Polling must leave both the run lock and cleanup available.
                with runtime.lock_path("fixture-2").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if race:
                    self.assertEqual(cleanups, ["fixture-2"])
                clock.sleep(seconds)

            def command(argv, **kwargs):
                self.assertEqual(argv[-2:], ["--load-wait-timeout", "12"])
                self.assertGreaterEqual(kwargs["timeout"], 24)
                output = io.StringIO()
                with patch.object(world, "Runtime", return_value=runtime), \
                     patch.object(sys, "argv", argv[1:]), contextlib.redirect_stdout(output):
                    code = world.main()
                return SimpleNamespace(returncode=code, stdout=output.getvalue())

            with patch.object(runtime, "status", side_effect=lambda: dict(active)), \
                 patch.object(runtime, "clone", side_effect=clone), \
                 patch.object(runtime, "_serve", side_effect=serve), \
                 patch.object(runtime, "_stop", side_effect=lambda name: cleanups.append(name)), \
                 patch.object(runtime, "state", return_value={"port": 25600}), \
                 patch.object(world.Path, "read_text", return_value="MemAvailable: 16777216 kB\n"), \
                 patch.object(world.os, "getloadavg", side_effect=[(v, 0, 0) for v in loads]), \
                 patch.object(world.time, "monotonic", side_effect=clock.monotonic), \
                 patch.object(world.time, "sleep", side_effect=sleep), \
                 patch("checks.context.admit") as locks, \
                 patch("checks.context.subprocess.run", side_effect=command):
                try:
                    ctx.cli("pool", "up", "2", "--prefix", "fixture", timeout=384)
                    error = None
                except Blocked as exc:
                    error = str(exc)
            locks.assert_called_once_with(check_load=False)
            report = run.merge_results([], [], ctx.commit, clock.now)
            report["startup_load_wait_seconds"] = ctx.load_wait_seconds
            report["pool_load_waits"] = ctx.pool_load_waits
            run.write_report(report, ctx.output)
            saved = json.loads((ctx.output / "report.json").read_text())
            markdown = (ctx.output / "report.md").read_text()
        return active, error, clock.sleeps, saved, markdown

    def test_second_world_waits_then_starts_and_wait_is_reported(self):
        active, error, sleeps, report, markdown = self.pool([7, 11, 9, 7.99])
        self.assertIsNone(error)
        self.assertEqual(set(active), {"fixture-1", "fixture-2"})
        self.assertEqual(sleeps, [5, 5])
        self.assertEqual(report["startup_load_wait_seconds"], 10)
        self.assertEqual(report["pool_load_waits"], [
            {"run": "fixture-1", "load_wait_seconds": 0},
            {"run": "fixture-2", "load_wait_seconds": 10}])
        self.assertIn("Pool startup load wait 10.00 seconds", markdown)

    def test_second_world_times_out_and_failed_wait_is_reported(self):
        active, error, sleeps, report, _ = self.pool([7, 11, 10, 9, 8])
        self.assertEqual(set(active), {"fixture-1"})
        self.assertIn("load1=8.00 must be below 8", error)
        self.assertEqual(sleeps, [5, 5, 2])
        self.assertEqual(report["startup_load_wait_seconds"], 12)
        self.assertEqual(report["pool_load_waits"][1]["load_wait_seconds"], 12)

    def test_keeper_race_retries_after_cleanup_and_outside_run_lock(self):
        active, error, sleeps, report, _ = self.pool([7, 7, 7], race=True)
        self.assertIsNone(error)
        self.assertEqual(set(active), {"fixture-1", "fixture-2"})
        self.assertEqual(sleeps, [5])
        self.assertEqual(report["startup_load_wait_seconds"], 5)

    def test_admitted_check_skips_keeper_load_but_preserves_memory_guard(self):
        gib = 1024 * 1024
        keeper.admit(3 * gib, 16 * gib, 11, True, load_admitted=True)
        with self.assertRaisesRegex(RuntimeError, "MemAvailable=8.00"):
            keeper.admit(3 * gib, 8 * gib, 11, True, load_admitted=True)
        with self.assertRaisesRegex(RuntimeError, "at least 3 GiB"):
            keeper.admit(3 * gib, 2 * gib, 11, False, load_admitted=True)

    def test_keeper_load_refusal_type_survives_socket_response(self):
        response = {"ok": False, "error": "Pool admission refused", "error_type": "LoadAdmissionRefused"}
        with patch.object(keeper.socket, "socket") as socket:
            socket.return_value.__enter__.return_value.recv.return_value = json.dumps(response).encode() + b"\n"
            with self.assertRaises(keeper.LoadAdmissionRefused):
                keeper.call(Path("/unused"), {"op": "start"})
