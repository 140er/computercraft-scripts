import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from checks.context import Context
from checks.model import Result


class RepeatTests(unittest.TestCase):
    def test_repeats_keep_failures_and_reset_between_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            ctx = Context(None, 'fixture', {}, directory, 'a' * 40)
            attempts = [Result('C8', ctx.commit, status, '', seconds, 20, [], {}, [], ctx.run)
                        for status, seconds in [('pass', 1), ('fail', 3), ('pass', 2)]]
            with patch.object(run, 'execute', side_effect=attempts) as execute:
                result = run.execute_repeated(ctx, 'C8', Path(directory), reset=False)
            self.assertEqual(result.status, 'fail')
            self.assertEqual(result.metrics['wall_seconds_spread'], 2)
            self.assertTrue(result.metrics['flaky'])
            self.assertEqual([c.kwargs['reset'] for c in execute.call_args_list], [False, True, True])
            self.assertEqual(len({c.args[0].output for c in execute.call_args_list}), 3)
            self.assertEqual(len(result.metrics['attempts']), 3)

    def test_blocked_and_unanimous_results(self):
        for statuses, expected in [(['pass'] * 3, 'pass'), (['blocked', 'pass', 'pass'], 'blocked')]:
            with tempfile.TemporaryDirectory() as directory:
                ctx = Context(None, 'fixture', {}, directory, 'a' * 40)
                attempts = [Result('C10', ctx.commit, status, '', 1, 20, [], {}, [], ctx.run) for status in statuses]
                with patch.object(run, 'execute', side_effect=attempts):
                    result = run.execute_repeated(ctx, 'C10', Path(directory))
                self.assertEqual(result.status, expected)

    def test_other_checks_run_once(self):
        with patch.object(run, 'execute', return_value='sentinel') as execute:
            self.assertEqual(run.execute_repeated(None, 'C9', Path('.')), 'sentinel')
            execute.assert_called_once()
