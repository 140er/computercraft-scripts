import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks.c10 import ready_for_outage


class OutageReadinessTests(unittest.TestCase):
    def state(self):
        frame = {"rot": 0, "ox": 0, "oy": 0, "oz": 0}
        journal = {"id": "initialized", "park": False,
                   "pose": {"x": 0, "y": 0, "z": -1, "f": 0},
                   "moves": [{"op": "forward", "ok": True}]}
        return {"workers": {k: copy.deepcopy(journal) for k in ("4", "5", "6")},
                "mine": {"turtles": {k: {"frame": frame} for k in ("4", "5")}},
                "lumber": {"turtle": {"frame": frame}}}

    def test_per_worker_lumber_frame_is_ready_for_outage(self):
        state = self.state()
        turtle = state["lumber"].pop("turtle")
        state["lumber"]["turtles"] = {"6": {"turtle": turtle}}
        self.assertTrue(ready_for_outage(state))
        state["lumber"]["turtles"]["6"]["turtle"].pop("frame")
        self.assertFalse(ready_for_outage(state))

    def test_each_worker_needs_a_real_retreat_path(self):
        row = self.state()
        self.assertTrue(ready_for_outage(row))
        for moves in ([], [{"op": "turnLeft", "ok": True}], [{"op": "forward", "ok": False}]):
            with self.subTest(moves=moves):
                bad = copy.deepcopy(row)
                bad["workers"]["6"]["moves"] = moves
                self.assertFalse(ready_for_outage(bad))

    def test_missing_journal_pose_frame_or_active_worker_prevents_cut(self):
        for field in ("id", "pose"):
            row = self.state();row["workers"]["5"].pop(field)
            self.assertFalse(ready_for_outage(row))
        row = self.state();row["workers"]["5"]["park"] = True
        self.assertFalse(ready_for_outage(row))
        row = self.state();row["mine"]["turtles"]["5"].pop("frame")
        self.assertFalse(ready_for_outage(row))
        row = self.state();row["workers"].pop("5")
        self.assertFalse(ready_for_outage(row))

    def test_lua_table_movement_history_is_supported(self):
        row = self.state()
        for journal in row["workers"].values():
            journal["moves"] = {"1": {"op": "forward", "ok": True}}
        self.assertTrue(ready_for_outage(row))
