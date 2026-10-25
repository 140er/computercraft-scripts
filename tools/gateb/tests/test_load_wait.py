import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from checks.admission import admit
from checks.context import Context
from checks.model import Verdict


class Clock:
    def __init__(self):
        self.now = 0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class LoadWaitTests(unittest.TestCase):
    def execute(self, loads, timeout=300):
        clock = Clock()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proc = root / "proc"
            proc.mkdir()
            (proc / "locks").write_text("")
            ctx = Context(None, "fixture", {}, root / "C5", "a" * 40)
            ctx.load_wait_timeout = timeout
            check = SimpleNamespace(run=lambda ctx: Verdict("pass"), TITLE="Fixture")
            with patch("checks.admission.os.getloadavg", side_effect=[(v, 0, 0) for v in loads]), \
                 patch("checks.admission.time.monotonic", side_effect=clock.monotonic), \
                 patch("checks.admission.time.sleep", side_effect=clock.sleep), \
                 patch.object(run, "admit", side_effect=lambda **kw: admit(proc, root, **kw)), \
                 patch.object(ctx, "cli", side_effect=[{}, {}, {"sha": ctx.commit, "errors": []}]) as cli, \
                 patch.object(ctx, "request", return_value={}), \
                 patch.object(ctx, "wait", return_value=True), \
                 patch.object(ctx, "command"), patch.object(run, "load", return_value=check):
                with patch.object(check, "run", wraps=check.run) as native_check:
                    result = run.execute(ctx, "C5", root)
                    ran = native_check.call_count
            report = run.merge_results([result], ["C5"], ctx.commit, clock.now)
            run.write_report(report, root)
            saved = json.loads((root / "report.json").read_text())
            markdown = (root / "report.md").read_text()
            evidence = json.loads((root / "C5" / "load-wait.json").read_text())
            return result, ran, cli.call_count, clock.sleeps, saved, markdown, evidence

    def test_load_drops_after_polls_then_check_runs_and_reports_wait(self):
        result, ran, _, sleeps, report, markdown, evidence = self.execute([11, 9, 8, 7.99])
        self.assertEqual(result.status, "pass")
        self.assertEqual(ran, 1)
        self.assertEqual(sleeps, [5, 5, 5])
        self.assertEqual(report["checks"][0]["metrics"]["load_wait_seconds"], 15)
        self.assertIn("load wait 15.00 seconds", markdown)
        self.assertEqual(evidence["load_wait_seconds"], 15)

    def test_high_load_times_out_without_preparation_or_check(self):
        result, ran, calls, sleeps, report, markdown, evidence = self.execute([11, 10, 9, 8], timeout=12)
        self.assertEqual(result.status, "blocked")
        self.assertEqual(result.findings, ["Native run refused: load1=8.00 must be below 8"])
        self.assertEqual((ran, calls), (0, 0))
        self.assertEqual(sleeps, [5, 5, 2])
        self.assertEqual(report["checks"][0]["metrics"]["load_wait_seconds"], 12)
        self.assertIn("load wait 12.00 seconds", markdown)
        self.assertEqual(evidence["load_wait_seconds"], 12)

    def test_low_load_runs_without_sleep(self):
        result, ran, _, sleeps, _, _, evidence = self.execute([7.99])
        self.assertEqual((result.status, ran, sleeps), ("pass", 1, []))
        self.assertEqual(evidence["load_wait_seconds"], 0)

    def test_scheduler_waits_before_startup_and_between_checks(self):
        clock = Clock()
        checked = []

        class FakeContext(Context):
            def cli(self, *args, **kwargs):
                if args[0] == "install":
                    return {"sha": self.commit, "errors": []}
                return {}

            def request(self, *args, **kwargs): return {}
            def wait(self, *args): return True
            def command(self, *args): pass

        def check(ctx):
            checked.append((ctx.output.name, clock.now, ctx.load_wait_timeout))
            return Verdict("pass")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proc = root / "proc"
            proc.mkdir()
            (proc / "locks").write_text("")
            with patch("checks.admission.os.getloadavg", side_effect=[(v, 0, 0) for v in [9, 7, 7, 10, 9, 7]]), \
                 patch("checks.admission.time.monotonic", side_effect=clock.monotonic), \
                 patch("checks.admission.time.sleep", side_effect=clock.sleep), \
                 patch.object(run, "admit", side_effect=lambda **kw: admit(proc, root, **kw)), \
                 patch.object(run, "Context", FakeContext), patch.object(run, "reserve_local_slot"), \
                 patch.object(run, "runtime_class", return_value=lambda: SimpleNamespace(release_stopped_port=lambda world: None)), \
                 patch.object(run, "resolve", return_value="a" * 40), \
                 patch.object(run, "load", return_value=SimpleNamespace(run=check, TITLE="Fixture")):
                code = run.main(["--checks", "C5,C6", "--worlds", "1", "--output", temp,
                                 "--load-wait-timeout", "12"])
            report = json.loads((root / "report.json").read_text())
            markdown = (root / "report.md").read_text()
        self.assertEqual(code, 0)
        self.assertEqual(checked, [("C5", 5, 12), ("C6", 15, 12)])
        self.assertEqual(report["startup_load_wait_seconds"], 5)
        self.assertEqual([r["metrics"]["load_wait_seconds"] for r in report["checks"]], [0, 10])
        self.assertIn("Pool startup load wait 5.00 seconds", markdown)

    def test_runtime_operations_use_the_configured_timeout_and_record_wait(self):
        with tempfile.TemporaryDirectory() as temp:
            ctx = Context(None, "fixture", {}, temp, "a" * 40)
            ctx.load_wait_timeout = 12
            def admission(**kwargs):
                self.assertEqual(kwargs["timeout"], 12)
                kwargs["on_wait"](5)
            with patch("checks.context.admit", side_effect=admission), \
                 patch("checks.context.subprocess.run", return_value=SimpleNamespace(returncode=0, stdout='{"result": {}}')):
                ctx.cli("reset", "fixture")
                ctx.cli("client", "fixture", "start")
            self.assertEqual(ctx.load_wait_seconds, 10)
            self.assertEqual(json.loads((Path(temp) / "load-wait.json").read_text())["load_wait_seconds"], 10)

    def test_timeout_must_be_nonnegative(self):
        with patch("sys.stderr"), self.assertRaises(SystemExit):
            run.main(["--checks", "C5", "--load-wait-timeout", "-1"])
