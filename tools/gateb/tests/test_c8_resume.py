import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks.c8 import resume_stats, evaluate


def sample(seconds, *, repaired=True, holder=None, x=0, facing=0):
    worker = {"dropRetry": {"tries": 5}} if not repaired else {}
    miners = {"4": worker, "5": {}}
    if holder:
        miners[holder]["lane"] = {"cells": []}
    return {"game_ms": seconds * 1000, "mine": {"turtles": miners},
            "workers": {"4": {"pose": {"x": x, "y": 64, "z": 5, "f": facing}}}}


class ResumeTests(unittest.TestCase):
    def verdict(self, rows):
        stats = resume_stats(rows, "4", 0)
        fault = {"alerts": 1, "parked": True, "retry_game_seconds": [60], **stats}
        return evaluate({"ore": fault, "fuel": copy.deepcopy(fault)}).status

    def test_refill_then_one_long_pass_and_prompt_resume(self):
        rows = [sample(0, repaired=False), sample(60, holder="5"),
                sample(160, holder="5", facing=1), sample(190, holder="4"),
                sample(200, holder="4", x=1)]
        stats = resume_stats(rows, "4", 0)
        self.assertEqual(stats["lane_wait_game_seconds"], 130)
        self.assertEqual(stats["resume_after_lane_game_seconds"], 10)
        self.assertEqual(stats["resume_game_seconds"], 200)
        self.assertEqual(self.verdict(rows), "pass")

    def test_free_lane_starts_deadline_before_grant(self):
        rows = [sample(0, repaired=False), sample(60, holder="5"), sample(100), sample(132, holder="4", x=1)]
        self.assertEqual(self.verdict(rows), "fail")
        rows[-1] = sample(129, holder="4", x=1)
        self.assertEqual(self.verdict(rows), "pass")

    def test_turns_and_missing_grant_do_not_count_as_resume(self):
        for holder in (None, "4", "5"):
            with self.subTest(holder=holder):
                self.assertEqual(self.verdict([sample(0), sample(400, holder=holder, facing=1)]), "fail")

    def test_stuck_holder_and_second_pass_fail(self):
        rows = [sample(0, holder="5"), sample(301, holder="4", x=1)]
        self.assertEqual(self.verdict(rows), "fail")
        rows = [sample(0, holder="5"), sample(10), sample(15, holder="5"), sample(20, holder="4", x=1)]
        self.assertEqual(self.verdict(rows), "fail")

    def test_movement_during_continuous_contention_has_no_lane_credit(self):
        rows = [sample(0, holder="5"), sample(200, holder="5", x=1)]
        self.assertIsNone(resume_stats(rows, "4", 0)["lane_available_game_ms"])
        self.assertEqual(self.verdict(rows), "fail")

    def test_movement_before_repair_does_not_count(self):
        rows = [sample(0, repaired=False), sample(30, repaired=False, x=1), sample(60, x=1)]
        self.assertIsNone(resume_stats(rows, "4", 0)["resume_game_seconds"])
        self.assertEqual(self.verdict(rows), "fail")

    def test_repair_still_has_a_deadline(self):
        rows = [sample(0, repaired=False), sample(91, holder="4", x=1)]
        self.assertEqual(self.verdict(rows), "fail")
