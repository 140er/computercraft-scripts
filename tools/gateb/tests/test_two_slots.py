import fcntl
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keeper
import run
from world import Runtime
from checks import admission
from checks.context import Context
from checks.model import Blocked, Verdict


def checking(home, check, entered, release):
    with admission.visual_check(home, check):
        entered.set()
        release.wait(5)


class TwoSlotTests(unittest.TestCase):
    def test_two_slots_share_admission_but_each_has_one_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            with admission.reserve_local_slot(home), admission.reserve_slot(home, "A"), \
                 admission.reserve_local_slot(home), admission.reserve_slot(home, "B"):
                for slot in ("A", "B"):
                    with self.assertRaises(admission.Refused):
                        with admission.reserve_slot(home, slot):
                            self.fail("Duplicate slot owner admitted")
                with (home / "test-suite-local-2.lock").open("a") as suite:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(suite, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with admission.reserve_slot(home, "A"):
                pass

    def test_two_worlds_per_slot_and_third_refused(self):
        children = {}
        for key in ("slot-A-first-1", "slot-A-first-2", "slot-B-second-1", "slot-B-second-2"):
            keeper.admit_world(children, key)
            children[key] = 1
            children[key + ":client"] = 2
        for slot in ("A", "B"):
            with self.assertRaisesRegex(keeper.AdmissionRefused, "at most 2 worlds"):
                keeper.admit_world(children, f"slot-{slot}-third-1")
        keeper.admit_world(children, "slot-A-first-1")
        del children["slot-A-first-2"]
        keeper.admit_world(children, "slot-A-next-1")

    def test_old_keeper_refused_until_it_becomes_idle(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = Runtime(temp, slot="A")
            with patch.object(keeper, "call", side_effect=[{}, RuntimeError("Unknown keeper operation")]), \
                 patch("world.subprocess.Popen") as start:
                with self.assertRaisesRegex(keeper.AdmissionRefused, "idle before upgrading"):
                    runtime.ensure_keeper()
                start.assert_not_called()
            with patch.object(keeper, "call", side_effect=[{}, {"worlds_per_slot": 2}]):
                self.assertEqual(runtime.ensure_keeper(), {})

    def test_other_driver_is_not_a_full_suite(self):
        locks = "1: FLOCK ADVISORY READ 999999 00:01:42 0 EOF"
        slots = {(0, 1, 42): "test-suite-local-2.lock"}
        for args in (["python3", "/other/tools/gateb/run.py", "--slot", "B"],
                     ["python3", "/other/tools/gateb/run.py"]):
            self.assertIsNone(admission.full_local_suite(locks, slots, lambda pid: args))
        self.assertIsNotNone(admission.full_local_suite(locks, slots, lambda pid: ["cc-test"]))
        self.assertIsNotNone(admission.full_local_suite(locks, slots, lambda pid: ["cc-test", "--shards", "2", "/repo/tools/gateb/run.py"]))
        self.assertIsNotNone(admission.full_local_suite(locks, slots, lambda pid: []))

    def test_visual_waits_for_running_check_and_pauses_new_checks(self):
        # Fork before taking locks, so children do not inherit a parent's flock.
        mp = multiprocessing.get_context("spawn")
        for check in ("C3", "C13"):
            with self.subTest(check=check), tempfile.TemporaryDirectory() as temp:
                home = Path(temp)
                visual_entered, visual_release = mp.Event(), mp.Event()
                next_entered, next_release = mp.Event(), mp.Event()
                visual = mp.Process(target=checking, args=(home, check, visual_entered, visual_release))
                reader = mp.Process(target=checking, args=(home, "C6", next_entered, next_release))
                try:
                    with admission.visual_check(home, "C5"):
                        visual.start()
                        deadline = time.monotonic() + 5
                        with (home / "visual-turn.lock").open("a") as turn:
                            while True:
                                try:
                                    fcntl.flock(turn, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                    fcntl.flock(turn, fcntl.LOCK_UN)
                                except BlockingIOError:
                                    break
                                self.assertLess(time.monotonic(), deadline, "Visual check did not queue")
                                time.sleep(.01)
                        self.assertFalse(visual_entered.is_set())
                        reader.start()
                        self.assertFalse(next_entered.wait(.1))
                    self.assertTrue(visual_entered.wait(5))
                    self.assertFalse(next_entered.wait(.1))
                    visual_release.set()
                    self.assertTrue(next_entered.wait(5))
                    next_release.set()
                finally:
                    visual_release.set()
                    next_release.set()
                    for process in (visual, reader):
                        if process.pid:
                            process.join(5)
                            if process.is_alive():
                                process.terminate()
                                process.join(5)
                self.assertEqual((visual.exitcode, reader.exitcode), (0, 0))

    def test_ordinary_checks_can_overlap(self):
        with tempfile.TemporaryDirectory() as temp:
            with admission.visual_check(temp, "C5"), admission.visual_check(temp, "C6"):
                pass

    def test_slot_option_env_and_world_limit(self):
        with patch.object(run, "resolve", return_value="a" * 40), patch("builtins.print") as output:
            with patch.dict(os.environ, {"GATEB_SLOT": "B"}):
                self.assertEqual(run.main(["--checks", "C3", "--plan"]), 0)
            self.assertEqual(json.loads(output.call_args.args[0])["slot"], "B")
            run.main(["--checks", "C3", "--slot", "A", "--plan"])
            self.assertEqual(json.loads(output.call_args.args[0])["slot"], "A")
            with patch("sys.stderr"), self.assertRaises(SystemExit):
                run.main(["--checks", "C3", "--worlds", "3", "--plan"])
            with patch.dict(os.environ, {"GATEB_SLOT": "invalid"}), patch("sys.stderr"), self.assertRaises(SystemExit):
                run.main(["--checks", "C3", "--plan"])
        with tempfile.TemporaryDirectory() as temp:
            runtime = Runtime(temp, slot="B")
            with self.assertRaisesRegex(ValueError, "at most 2"):
                runtime.pool("up", 3)
            with self.assertRaisesRegex(ValueError, "slot-B"):
                runtime._serve("slot-A-other-1")

    def test_context_passes_slot_and_home_and_preserves_retry_type(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = SimpleNamespace(slot="B", home=Path(temp) / "runtime")
            ctx = Context(runtime, "slot-B-test-1", {}, Path(temp) / "out", "a" * 40)
            packet = {"ok": False, "retryable": True, "error": "Slot is busy"}
            with patch("checks.context.subprocess.run", return_value=SimpleNamespace(returncode=1, stdout=json.dumps(packet))) as command:
                with self.assertRaises(admission.Refused):
                    ctx.cli("clone", ctx.run)
                self.assertEqual(command.call_args.args[0][2:6], ["--slot", "B", "--home", str(runtime.home)])

    def test_default_reports_are_unique_and_slot_tagged(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(run.Path, "home", return_value=Path(temp)), \
             patch.object(run, "resolve", return_value="a" * 40), patch.object(run, "git", return_value="tools/tool.py\0"), \
             patch.object(run, "write_report") as report:
            for slot in ("A", "B", "A"):
                self.assertEqual(run.main(["--changed", "base..head", "--slot", slot]), 0)
            paths = [call.args[1] for call in report.call_args_list]
            self.assertEqual(len(set(paths)), 3)
            self.assertEqual([path.name[:7] for path in paths], ["slot-A-", "slot-B-", "slot-A-"])

    def test_refused_check_is_retryable_but_real_block_is_not(self):
        with tempfile.TemporaryDirectory() as temp:
            ctx = Context(None, "fixture", {}, temp, "a" * 40)
            for error in (admission.Refused("Admission refused"), Blocked("Missing photo")):
                with patch.object(ctx, "command"), patch.object(run, "load", side_effect=error):
                    result = run.execute(ctx, "C3", Path(temp), prepare=False)
                self.assertEqual(result.metrics["retryable"], isinstance(error, admission.Refused))

    def test_driver_exit_codes_and_tagged_worlds(self):
        class FakeContext(Context):
            def cli(self, *args, **kwargs):
                if args[0] == "pool":
                    self.assert_slot(args[args.index("--prefix") + 1])
                if args[0] == "install":
                    return {"sha": self.commit, "errors": []}
                return {}
            def assert_slot(self, prefix):
                if not prefix.startswith("slot-B-driver-"):
                    raise AssertionError(prefix)
            def command(self, *args): pass
            def request(self, *args, **kwargs): return {}
            def wait(self, *args): return True

        for verdict, expected in ((admission.Refused("Busy"), 75), (Blocked("Missing pixels"), 1),
                                  (Verdict("fail", ["Real failure"]), 1), (Verdict("pass"), 0)):
            with self.subTest(verdict=verdict), tempfile.TemporaryDirectory() as temp:
                runtime = SimpleNamespace(home=Path(temp) / "runtime", release_stopped_port=lambda name: None)
                def check(ctx):
                    if isinstance(verdict, Exception):
                        raise verdict
                    return verdict
                with patch.object(run, "admit"), patch.object(run, "reserve_local_slot"), \
                     patch.object(run, "runtime_class", return_value=lambda: runtime), \
                     patch.object(run, "Context", FakeContext), patch.object(run, "resolve", return_value="a" * 40), \
                     patch.object(run, "load", return_value=SimpleNamespace(run=check, TITLE="Fixture")):
                    self.assertEqual(run.main(["--slot", "B", "--checks", "C5", "--output", temp]), expected)
                report = json.loads((Path(temp) / "report.json").read_text())
                self.assertEqual(report["slot"], "B")
                self.assertTrue(report["checks"][0]["world"].startswith("slot-B-driver-"))


class RetryTests(unittest.TestCase):
    def wrapper(self, results, expired=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "count").write_text("0")
            fake = root / "python3"
            cases = "\n".join(f"{index}) exit {code};;" for index, code in enumerate(results, 1))
            fake.write_text('#!/bin/sh\nn=$(cat "$COUNT_PATH"); n=$((n+1)); echo "$n" > "$COUNT_PATH"\ncase "$n" in\n' + cases + '\n*) exit 99;;\nesac\n')
            fake.chmod(0o755)
            (root / "sleep").write_text('#!/bin/sh\necho slept >> "$SLEEP_PATH"\n')
            (root / "sleep").chmod(0o755)
            if expired:
                (root / "date").write_text('#!/bin/sh\n[ "$(cat "$COUNT_PATH")" -eq 0 ] && echo 100 || echo 1900\n')
                (root / "date").chmod(0o755)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "COUNT_PATH": str(root / "count"), "SLEEP_PATH": str(root / "sleeps")}
            wrapper = Path(run.__file__).with_name("gateb-retry.sh")
            done = subprocess.run(["sh", str(wrapper), "--slot", "B", "--checks", "C3"], env=env, capture_output=True, text=True, timeout=5)
            return done.returncode, int((root / "count").read_text()), (root / "sleeps").exists()

    def test_refusal_retried_then_success(self):
        self.assertEqual(self.wrapper([75, 0]), (0, 2, True))

    def test_real_check_failure_and_configuration_error_pass_through(self):
        for code in (1, 2):
            self.assertEqual(self.wrapper([code]), (code, 1, False))
        self.assertEqual(self.wrapper([75, 1]), (1, 2, True))

    def test_refusal_stops_at_deadline(self):
        self.assertEqual(self.wrapper([75], expired=True), (75, 1, False))
