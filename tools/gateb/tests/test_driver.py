import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from checks import IDS, load
from checks.context import Context, sanitize
from checks.lua_data import parse
from checks.mining import analyze
from checks.model import Result, own_path

FIXTURES = Path(__file__).parent / "fixtures"
PROOF = {k: True for k in ("zero_forced_chunks", "native_unloaded", "helpers_disabled", "pending_inputs_absent", "no_input_after_return")}
PASS = {
    "C1": {"normal_http_install": True, "install_errors": [], "exact_files": True, "rebooted_roles": 6},
    "C2": {"paired_clients": 5, "bad_attempts": 5, "invitation_burned": True, "probe_unpaired": True, "server_prompt_restored": True},
    "C3": {k: True for k in ("all_screens_reached", "setups_and_returns", "coordinates_fit", "generic_survives_reboot", "single_order_delivery", "real_photos")},
    "C4": {"settled_seconds": 10, "verified_before_anchor": True, "server_poses_match": True, "display_poses_match": True},
    "C5": {"range_samples": 0, "collisions": 0, "errors": [], "completed_miners": ["4", "5"], "handoff_game_seconds": 29},
    "C6": {"logs_delivered": 19, "replanted": 4, "dug_count": 28, "unsafe_digs": []},
    "C8": {kind: {"alerts": 1, "parked": True, "retry_game_seconds": [60.3, 60.9], "resume_game_seconds": 56.3} for kind in ("ore", "fuel")},
    "C9": {"off_seconds": 183.4, "no_motion": True, "stale_seconds": 7.83, "recovery_seconds": 12.86, "new_recovery_parks": True},
    "C10": {"off_seconds": 204.5, "active_workers": True, "outside_own_path": [], "collisions": [], "duplicate_digs": [], "movement_recovery_seconds": {"4":5.11,"5":5.11,"6":5.11}, "worker_count": 3, "outage_samples": 10, "retreat_observed": True},
    "C11": {**PROOF, "active_mid_batch": True, "parked_poses_preserved": True, "healthy_after_return": True, "unloaded_seconds": 130.72, "sample_count": 5, "state_changes": [], "movement_recovery_seconds": {"6":12.21}, "active_count": 1},
    "C12": {"stock_visible_seconds": 10.78, "search_filtered": True, "delivered_delta": 16, "stock_delta": -16},
    "C13": {k: True for k in ("linked_goggles", "labels_boxes_headings_aligned", "no_overlap", "stable_frames", "hud_matches_server", "native_layer_removal", "layers_persist", "real_photos")},
    "C14": {k: True for k in ("real_http_staging", "native_interruption", "old_files_unchanged", "pairing_unchanged", "old_role_rebooted", "full_update_exact", "final_rebooted")},
}
PASS["C7"] = {**PASS["C5"], "game_seconds": 1800, "ore_delivered": True, "fuel_trip": True, "ore_trip": True, "server_errors": 0}
FAIL = {"C1": ("install_errors", ["initial TLS failure"]), "C2": ("probe_unpaired", False),
        "C3": ("coordinates_fit", False), "C4": ("verified_before_anchor", False), "C5": ("range_samples", 1),
        "C6": ("unsafe_digs", [[4,63,5]]), "C7": ("game_seconds", 1799),
        "C8": ("ore", {"alerts":2,"parked":True,"retry_game_seconds":[60],"resume_game_seconds":30}),
        "C9": ("no_motion", False), "C10": ("outside_own_path", [{"worker":"4","pos":[99,99,99]}]),
        "C11": ("no_input_after_return", False), "C12": ("delivered_delta", 15),
        "C13": ("stable_frames", False), "C14": ("old_files_unchanged", False)}


class SelectionTests(unittest.TestCase):
    def test_named_modules(self):
        expected = {
            "so-mod-mine.lua": ["C5", "C7", "C8", "C10"],
            "so-mine-plan.lua": ["C5", "C7", "C8", "C10"],
            "so-mod-lease.lua": ["C5", "C7", "C8", "C10"],
            "display.lua": ["C3", "C4"], "so-mod-display.lua": ["C3", "C4"],
            "so-ui.lua": ["C3", "C4"], "screens/mining.lua": ["C3", "C4"],
            "so-mod-ar.lua": ["C13"], "install.lua": ["C1", "C14"],
            "update.lua": ["C1", "C14"], "worker.lua": ["C1", "C9", "C11"],
            "so-lumber-plan.lua": ["C6"], "so-mod-shop.lua": ["C12"], "so-pair.lua": ["C2"]}
        for path, checks in expected.items():
            with self.subTest(path=path): self.assertEqual(run.select_checks([path]), checks)

    def test_shared_code_is_conservative(self):
        self.assertEqual(run.select_checks(["so-store.lua"]), list(IDS))
        self.assertEqual(run.select_checks(["docs/PROTOCOL.md", "tests/test_worker.lua", "tools/gateb/run.py"]), [])
        self.assertEqual(run.select_checks(["so-mod-ar.lua", "so-mod-shop.lua"]), ["C12", "C13"])

    def test_speed_gate_and_mixed_rates(self):
        with patch.object(run, "resolve", return_value="a"*40), patch.object(run, "tick_scaled", return_value=True), patch("builtins.print") as output:
            self.assertEqual(run.main(["--checks", "C5,C9,C10,C11,C14", "--tick-rate", "80", "--plan"]), 0)
            plan = json.loads(output.call_args.args[0])
            self.assertEqual(plan["tick_rates"], {"C5":80,"C9":20,"C10":20,"C11":20,"C14":20})
        with patch.object(run, "resolve", return_value="a"*40), patch.object(run, "tick_scaled", return_value=False), patch("sys.stderr"), self.assertRaises(SystemExit):
            run.main(["--checks", "C7", "--tick-rate", "80", "--plan"])

    def test_changed_and_explicit_union(self):
        with patch.object(run, "resolve", return_value="a"*40), patch.object(run, "git", return_value="so-mod-ar.lua\0"), patch("builtins.print") as output:
            run.main(["--changed", "base..tip", "--checks", "C3", "--plan"])
            self.assertEqual(json.loads(output.call_args.args[0])["checks"], ["C3","C13"])


class ResultTests(unittest.TestCase):
    def result(self, check="C3", status="pass", commit="a"*40):
        return Result(check, commit, status, "2026-10-22T20:00:00Z", 3.5, 20, [], {}, ["sample.json"], "private-1")

    def test_merge_missing_and_mixed_outcomes(self):
        report = run.merge_results([self.result()], ["C3","C5"], "a"*40, 7)
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(report["counts"], {"pass":1,"fail":0,"blocked":1})
        self.assertEqual(report["checks"][1]["status"], "blocked")
        report = run.merge_results([self.result(status="fail"), self.result("C5", "blocked")], ["C3","C5"], "a"*40, 7)
        self.assertEqual(report["status"], "fail")

    def test_refuse_duplicate_and_wrong_build(self):
        with self.assertRaises(ValueError): run.merge_results([self.result(),self.result()], ["C3"], "a"*40, 0)
        with self.assertRaises(ValueError): run.merge_results([self.result(commit="b"*40)], ["C3"], "a"*40, 0)

    def test_report_keeps_scope_and_evidence(self):
        report = run.merge_results([self.result()], ["C3"], "a"*40, 3.5)
        with tempfile.TemporaryDirectory() as temp:
            run.write_report(report, temp)
            text = (Path(temp)/"report.md").read_text()
            self.assertIn("C3/C3-result.json", text)
            self.assertIn("Unselected checks", text)
            self.assertIn("a"*40, text)

    def test_no_checks_is_not_a_gate_pass(self):
        self.assertEqual(run.merge_results([], [], "a"*40, 0)["status"], "not_run")


class CriterionTests(unittest.TestCase):
    def test_every_check_pass_and_fail(self):
        for check in IDS:
            with self.subTest(check=check):
                self.assertEqual(load(check).evaluate(copy.deepcopy(PASS[check])).status, "pass")
                bad = copy.deepcopy(PASS[check]); field, value = FAIL[check]; bad[field] = value
                self.assertEqual(load(check).evaluate(bad).status, "fail")

    def test_missing_visual_proof_blocks(self):
        for check in ("C3", "C13"):
            data = copy.deepcopy(PASS[check]); data["real_photos"] = None
            self.assertEqual(load(check).evaluate(data).status, "blocked")

    def test_all_fourteen_recorded_verdicts(self):
        recorded = json.loads((FIXTURES/"recorded-criteria.json").read_text())
        for row in recorded["checks"]:
            with self.subTest(check=row["check"]):
                self.assertEqual(load(row["check"]).evaluate(row["observations"]).status, row["expected"])

    def test_recorded_results(self):
        for check in ("C6","C9","C12"):
            data = json.loads((FIXTURES/f"recorded-{check}.json").read_text())
            self.assertEqual(load(check).evaluate(data["observations"]).status, "pass")

    def test_recorded_range_failure(self):
        data = json.loads((FIXTURES/"recorded-range.json").read_text())
        stats = analyze(data["rows"], [4,5])
        self.assertGreater(stats["range_samples"], 0)
        self.assertEqual(load("C5").evaluate(stats).status, "fail")

    def test_recorded_unload_and_replay_rejection(self):
        data = json.loads((FIXTURES/"recorded-unload.json").read_text())
        stats = load("C11").analyze(data["rows"], data["unloaded"], data["returned"], PROOF)
        self.assertEqual(load("C11").evaluate(stats).status, "pass")
        stats["no_input_after_return"] = False
        self.assertEqual(load("C11").evaluate(stats).status, "fail")
        rows = copy.deepcopy(data["rows"])
        rows[1]["workers"]["6"]["pose"]["x"] += 1
        stats = load("C11").analyze(rows, data["unloaded"], data["returned"], PROOF)
        self.assertEqual(load("C11").evaluate(stats).status, "fail")

    def test_lane_handoff_wait_starts_after_exit(self):
        cell = {"x":0,"y":48,"z":0}
        rows = []
        for epoch, x, second_lane in ((0,0,False),(90,0,False),(100,1,False),(129,1,True)):
            rows.append({"epoch":epoch,"mine":{"turtles":{"4":{"pose":{**cell,"x":x},"lane":{"cells":[cell]},"counted":0},"5":{"pose":{**cell,"x":2},"counted":1,**({"lane":{"cells":[cell]}} if second_lane else {})}}}})
        stats = analyze(rows, [4,5])
        self.assertEqual(stats["handoff_game_seconds"], 29)
        self.assertEqual(load("C5").evaluate(stats).status, "pass")
        rows[-1]["epoch"] = 132
        self.assertEqual(load("C5").evaluate(analyze(rows,[4,5])).status, "fail")

    def test_outage_requires_actual_motion(self):
        data = copy.deepcopy(PASS["C10"]); data["movement_recovery_seconds"] = {"4":1,"5":1}
        self.assertEqual(load("C10").evaluate(data).status, "fail")

    def test_two_workers_cannot_redig_the_same_cell(self):
        frame={"rot":0,"ox":0,"oy":0,"oz":0}
        def journal(x): return {"id":"old","park":False,"pose":{"x":x,"y":0,"z":0,"f":0},"moves":[],"dug":[]}
        before={"mine":{"turtles":{"4":{"frame":frame},"5":{"frame":frame}}},"lumber":{"turtle":{"frame":frame}},"workers":{"4":journal(0),"5":journal(1),"6":journal(2)}}
        row=copy.deepcopy(before);row["epoch"]=1
        row["workers"]["4"]["dug"]=[{"x":4,"y":0,"z":0}]
        later=copy.deepcopy(row);later["epoch"]=2
        later["workers"]["5"]["dug"]=[{"x":4,"y":0,"z":0}]
        stats=load("C10").analyze(before,[row,later],0,181)
        self.assertEqual(stats["duplicate_digs"],[{"worker":"5","pos":(4,0,0)}])

    def test_own_path_ignores_failed_moves(self):
        journal = {"pose":{"x":0,"y":0,"z":0,"f":0},"moves":{"1":{"op":"forward","ok":False},"2":{"op":"forward","ok":True}}}
        self.assertEqual(own_path(journal,{"rot":0,"ox":0,"oy":0,"oz":0}), {(0,0,0),(0,0,1)})


class BoundaryTests(unittest.TestCase):
    def test_lua_data_is_not_executable(self):
        data = parse('{schema=1,generation=3,value={pose={x=-5,y=64,z=3},moves={{op="forward",ok=true}},["a b"]="x\\n"}}')
        self.assertEqual(data["value"]["moves"]["1"]["op"], "forward")
        self.assertEqual(data["value"]["a b"], "x\n")
        for attack in ('os.execute("bad")', '{x=function() end}', '{} extra'):
            with self.assertRaises(ValueError): parse(attack)

    def test_secrets_removed_before_evidence(self):
        data = sanitize({"pairing_code":"123456","key":"a"*64,"text":"Pair code: 123456 server 1","commit":"b"*40})
        self.assertNotIn("123456", json.dumps(data))
        self.assertNotIn("a"*64, json.dumps(data))
        self.assertEqual(data["commit"], "b"*40)

    def test_anchor_needs_native_facing(self):
        class Runtime:
            def request(self, run, request, timeout):
                return {"pos":[1,2,3]} if request["op"] == "turtle" else {}
        with tempfile.TemporaryDirectory() as temp:
            ctx = Context(Runtime(), "test", {"computers":{"4":{"name":"miner1"}}}, temp, "a"*40)
            from checks.model import Blocked
            with self.assertRaises(Blocked): ctx.anchor("miner1", "mining")


if __name__ == "__main__":
    unittest.main()
