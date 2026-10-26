from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks.context import Context
from checks.model import Blocked, values


FRAME_ERROR = "Runtime must expose the latest received view.frame as GATEB_FRAME"
FRAME = {"role": "shop", "buttons": [{"id": "item:minecraft:diamond", "x": 1, "y": 1}]}


class FrameWaitTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.ctx = Context(None, "test", {"computers": {"3": {"name": "pocket"}}},
                           directory.name, "a" * 40)
        self.now = 0
        self.sleeps = []
        self.monotonic = patch("checks.context.time.monotonic", side_effect=lambda: self.now).start()
        self.addCleanup(patch.stopall)
        patch("checks.context.time.sleep", side_effect=self.sleep).start()
        self.ctx.request = Mock()

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def stock(self):
        frame = self.ctx.frame("pocket")
        return frame if any(b.get("id", "").startswith("item:") for b in values(frame["buttons"])) else None

    def test_stock_predicate_retries_until_first_frame_arrives(self):
        self.ctx.request.side_effect = [None, {}, {"buttons": []}, FRAME]
        self.assertEqual(self.ctx.wait(self.stock, 2), FRAME)
        self.assertEqual(self.now, 1.5)

    def test_missing_frame_blocks_only_at_wait_timeout(self):
        self.ctx.request.return_value = None
        with self.assertRaisesRegex(Blocked, FRAME_ERROR):
            self.ctx.wait(self.stock, 2)
        self.assertEqual(self.now, 2)
        self.assertEqual(self.ctx.request.call_count, 5)

    def test_frame_arriving_at_deadline_can_satisfy_predicate(self):
        self.ctx.request.side_effect = [None, None, FRAME]
        self.assertEqual(self.ctx.wait(self.stock, 1), FRAME)
        self.assertEqual(self.now, 1)

    def test_received_frame_without_stock_keeps_normal_timeout(self):
        empty_stock = {"role": "shop", "buttons": [{"id": "tab:items"}]}
        self.ctx.request.side_effect = [None, empty_stock, empty_stock]
        self.assertIsNone(self.ctx.wait(self.stock, 1))
        self.assertEqual(self.now, 1)

    def test_direct_frame_caller_still_gets_blocked(self):
        self.ctx.request.return_value = None
        with self.assertRaisesRegex(Blocked, FRAME_ERROR):
            self.ctx.frame("pocket")
        self.assertEqual(self.now, 0)

    def test_click_waits_for_first_frame_before_sending_input(self):
        updated = {**FRAME, "rev": 2}
        frames = iter([None, {}, FRAME, updated])
        def request(op, **kwargs):
            if op == "frame":
                return next(frames)
            if op == "input":
                self.assertEqual(self.now, .5)
            return {"width": 26, "height": 20}
        self.ctx.request.side_effect = request
        self.assertEqual(self.ctx.click("pocket", "item:minecraft:diamond"), updated)
        self.ctx.request.assert_any_call("input", computer=3, event="mouse_click", args=[1, 1, 1])

    def test_click_without_first_frame_blocks_after_three_seconds(self):
        self.ctx.request.return_value = None
        with self.assertRaisesRegex(Blocked, FRAME_ERROR):
            self.ctx.click("pocket", "item:minecraft:diamond")
        self.assertEqual(self.now, 3)
        self.assertTrue(all(call.args == ("frame",) for call in self.ctx.request.call_args_list))

    def test_received_frame_with_missing_button_blocks_immediately(self):
        self.ctx.request.return_value = FRAME
        with self.assertRaisesRegex(Blocked, "Visible absent button absent"):
            self.ctx.click("pocket", "absent")
        self.assertEqual(self.now, 0)

    def test_unrelated_runtime_errors_keep_normal_retry_behavior(self):
        self.ctx.request.side_effect = RuntimeError("runtime unavailable")
        self.assertIsNone(self.ctx.wait(self.stock, 1))
        self.assertEqual(self.now, 1)


if __name__ == "__main__":
    unittest.main()
