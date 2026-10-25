"""Native C3 and C13 photos: pocket screen, settled frames, cameras and candidate collection."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from checks import c3, c13, photos
from checks.model import Blocked, Verdict


class Keys:
    def __init__(self): self.events = []
    def press(self, name): self.events.append(name)
    def click(self, x, y, button=1): self.events.append(("click", x, y, button))


class Client:
    """A native client whose screenshots are scripted as states: world, pocket, menu, loading."""
    def __init__(self, states, output, manifest=None):
        self.states, self.output, self.run = list(states), Path(output), "private"
        self.native_input, self.commands, self.evidence, self.manifest = Keys(), [], [], manifest or {}
        self.shots, self.last = 0, None
        self.output.mkdir(parents=True, exist_ok=True)

    def shot(self):
        self.shots += 1
        self.last = self.states.pop(0) if len(self.states) > 1 else self.states[0]
        path = self.output / f"shot-{self.shots}.png"
        path.write_text(self.last)
        return path

    def keep(self, source, name):
        (self.output / name).write_bytes(Path(source).read_bytes())
        self.evidence.append(name)

    def sleep(self, seconds): pass

    def record(self, name, value):
        (self.output / name).write_text(json.dumps(value))
        self.evidence.append(name)
        return value

    def command(self, text):
        self.commands.append(text)
        if text.endswith(" Pos"): return {"output": "GateBTester has the following entity data: [-1.5d, 64.0d, -4.5d]"}
        if text.endswith(" Rotation"): return {"output": "GateBTester has the following entity data: [0.0f, 10.0f]"}
        return {"output": ""}


def probes(test):
    """Read the scripted state back from each fake screenshot."""
    state = lambda p: Path(p).read_text()
    for name, fn in (("pocket_open", lambda p: state(p) == "pocket"), ("menu_open", lambda p: state(p) == "menu"),
                     ("loading", lambda p: state(p) == "loading"), ("changed", lambda a, b, area=None: 0.0 if state(a) == state(b) else 1.0)):
        patcher = patch.object(photos, name, side_effect=fn)
        patcher.start(); test.addCleanup(patcher.stop)


class PocketScreenTests(unittest.TestCase):
    def setUp(self):
        probes(self)
        self.dir = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.dir)

    def test_pocket_is_held_and_used_until_its_bezel_shows(self):
        ctx = Client(["world", "world", "pocket"], self.dir)
        photos.open_pocket(ctx)
        self.assertEqual(ctx.commands, ["gamemode creative GateBTester"])
        self.assertEqual(ctx.native_input.events, ["Escape", "1", ("click", 640, 360, 3)])
        photos.open_pocket(ctx)
        self.assertEqual(ctx.commands.count("gamemode creative GateBTester"), 1)

    def test_pause_menu_is_dismissed_before_using_the_pocket(self):
        ctx = Client(["menu", "pocket"], self.dir)
        photos.open_pocket(ctx)
        self.assertEqual(ctx.native_input.events, ["Escape"])

    def test_missing_bezel_blocks(self):
        with self.assertRaisesRegex(Blocked, "pocket bezel not visible"):
            photos.open_pocket(Client(["world"], self.dir), attempts=3)

    def test_close_screens_leaves_the_world_in_view(self):
        ctx = Client(["pocket", "menu", "world"], self.dir)
        photos.close_screens(ctx)
        self.assertEqual(ctx.native_input.events, ["Escape", "Escape"])


class SettledFrameTests(unittest.TestCase):
    def setUp(self):
        probes(self)
        self.dir = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.dir)

    def test_loading_frames_are_skipped_until_two_frames_agree(self):
        ctx = Client(["loading", "loading", "world", "world"], self.dir)
        shot = photos.settled(ctx, "C13-layers-before.png", pocket=False)
        self.assertEqual(Path(shot).read_text(), "world")
        self.assertEqual(ctx.shots, 4)

    def test_changing_frames_never_settle(self):
        class Moving(Client):
            def shot(self):
                path = super().shot(); path.write_text(f"world {self.shots}"); return path
        with patch.object(photos, "pocket_open", return_value=False), \
             self.assertRaisesRegex(Blocked, "did not settle for C13-stability-0.png"):
            photos.settled(Moving(["world"], self.dir), "C13-stability-0.png", pocket=False, seconds=0.05)

    def test_pocket_photos_ignore_motion_outside_the_pocket(self):
        # The pocket camera faces the sky: drifting clouds, the item list and the minimap
        # change every frame around a pocket screen that holds still (smoke run, C3-pocket-mining).
        areas = []
        def changed(a, b, area=None):
            areas.append(area)
            return 0.0 if area == photos.POCKET_AREA else 0.06
        with patch.object(photos, "changed", side_effect=changed):
            photos.settled(Client(["pocket"], self.dir), "C3-pocket-mining.png", pocket=True)
            self.assertEqual(areas, [photos.POCKET_AREA])
            with self.assertRaisesRegex(Blocked, "did not settle"):
                photos.settled(Client(["world"], self.dir), "C3-wall-mining.png", pocket=False, seconds=0.05)
        self.assertIsNone(areas[-1])

    def test_timeout_retains_last_three_samples_and_full_image_diff(self):
        ctx = Client(["world 1", "world 2", "world 3", "world 4"], self.dir)
        with patch.object(photos, "pocket_open", return_value=False), \
             patch.object(photos.time, "monotonic", side_effect=[0, 0, 1, 2, 3, 4]), \
             patch.object(photos, "diff_mask", side_effect=lambda a, b, out: Path(out).write_text("diff")):
            with self.assertRaisesRegex(Blocked, "did not settle"):
                photos.settled(ctx, "wall.png", False, seconds=4)
        for i in range(1, 4):
            self.assertEqual((self.dir / f"wall-settle-{i}.png").read_text(), f"world {i+1}")
        self.assertEqual((self.dir / "wall-settle-diff.png").read_text(), "diff")
        details = json.loads((self.dir / "wall-settle.json").read_text())
        self.assertEqual(details["area"], None)
        self.assertEqual([s["reason"] for s in details["samples"]], ["motion"] * 3)
        self.assertIn("wall-settle-diff.png", ctx.evidence)

    def test_wall_region_ignores_external_motion_but_detects_wall_motion(self):
        area = (416, 272, 432, 216)
        ctx = Client(["world"], self.dir)
        with patch.object(photos, "changed", side_effect=lambda a, b, area=None: 0 if area else .2) as changed:
            photos.settled(ctx, "wall.png", False, area=area)
        self.assertEqual(changed.call_args.args[2], area)
        with patch.object(photos, "changed", return_value=.03), \
             patch.object(photos.time, "monotonic", side_effect=[0, 0, 1, 2]), \
             patch.object(photos, "diff_mask", side_effect=lambda a, b, out: Path(out).write_text("diff")):
            with self.assertRaisesRegex(Blocked, "did not settle"):
                photos.settled(ctx, "wall.png", False, seconds=2, area=area)
        details = json.loads((self.dir / "wall-settle.json").read_text())
        self.assertEqual(details["area"], list(area))
        self.assertEqual(details["limit"], .02)

    def test_probe_rejections_are_retained_when_loading_never_clears(self):
        ctx = Client(["loading"], self.dir)
        with patch.object(photos.time, "monotonic", side_effect=[0, 0, 1, 2]), \
             patch.object(photos, "diff_mask", side_effect=lambda a, b, out: Path(out).write_text("diff")):
            with self.assertRaisesRegex(Blocked, "did not settle"):
                photos.settled(ctx, "loading.png", False, seconds=2)
        details = json.loads((self.dir / "loading-settle.json").read_text())
        self.assertEqual([s["reason"] for s in details["samples"]], ["loading", "loading"])

    def test_diff_failure_keeps_samples_and_original_blocked_finding(self):
        ctx = Client(["world 1", "world 2"], self.dir)
        with patch.object(photos, "pocket_open", return_value=False), \
             patch.object(photos.time, "monotonic", side_effect=[0, 0, 1, 2]), \
             patch.object(photos, "diff_mask", side_effect=Blocked("Diff unavailable")):
            with self.assertRaisesRegex(Blocked, "Native screenshot did not settle for wall.png"):
                photos.settled(ctx, "wall.png", False, seconds=2)
        details = json.loads((self.dir / "wall-settle.json").read_text())
        self.assertEqual(details["diff_error"], "Diff unavailable")
        self.assertEqual(len(details["samples"]), 2)

    def test_a_closed_pocket_is_reopened_for_a_pocket_photo(self):
        ctx = Client(["world", "pocket", "pocket", "pocket"], self.dir)
        with patch.object(photos, "open_pocket", wraps=photos.open_pocket) as opened:
            self.assertEqual(Path(photos.settled(ctx, "C3-pocket-map.png", pocket=True)).read_text(), "pocket")
        self.assertEqual(opened.call_count, 1)


class TakeTests(unittest.TestCase):
    def setUp(self):
        probes(self)
        self.dir = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.dir)

    def test_reviewed_mode_still_blocks_on_a_missing_reference(self):
        ctx = Client(["world"], self.dir / "out")
        with self.assertRaisesRegex(Blocked, "No reviewed deterministic pixel reference for C3-wall-map.png"):
            photos.take(ctx, "C3-wall-map.png", "tp GateBTester -1.5 64 -4.5 0 10")
        self.assertIn("tp GateBTester -1.5 64 -4.5 0 10", ctx.commands)
        self.assertTrue((ctx.output / "C3-wall-map.png").exists())

    def test_reviewed_mode_returns_the_comparison(self):
        ctx = Client(["world"], self.dir / "out")
        with patch.object(photos, "check", return_value=True) as compared:
            self.assertIs(photos.take(ctx, "C3-wall-map.png", "view"), True)
        compared.assert_called_once_with(ctx, "C3-wall-map.png")

    def test_collect_mode_writes_photo_and_camera_and_gives_no_credit(self):
        ctx = Client(["pocket"], self.dir / "out")
        ctx.collect = self.dir / "candidates"
        with patch.object(photos, "check") as compared:
            self.assertIsNone(photos.take(ctx, "C3-pocket-map.png", "tp GateBTester -1.5 64 -4.5 -90 -90", pocket=True))
        compared.assert_not_called()
        self.assertEqual((ctx.collect / "C3-pocket-map.png").read_text(), "pocket")
        camera = json.loads((ctx.collect / "C3-pocket-map.png.camera.json").read_text())
        self.assertEqual(camera["view"], "tp GateBTester -1.5 64 -4.5 -90 -90")
        self.assertIn("-4.5d", camera["pos"]["output"])
        self.assertIn("10.0f", camera["rotation"]["output"])
        self.assertEqual(ctx.candidates, ["C3-pocket-map.png"])

    def test_photo_prepare_commands_run_once(self):
        ctx = Client(["world"], self.dir / "out", {"photo_prepare": ["clone -1 64 -2 -1 64 -2 -10 64 -6 replace move"]})
        ctx.collect = self.dir / "candidates"
        photos.take(ctx, "a.png", "view"); photos.take(ctx, "b.png", "view")
        self.assertEqual(ctx.commands.count("clone -1 64 -2 -1 64 -2 -10 64 -6 replace move"), 1)
        self.assertLess(ctx.commands.index("clone -1 64 -2 -1 64 -2 -10 64 -6 replace move"), ctx.commands.index("view"))

    def test_credit_needs_every_verdict(self):
        self.assertIsNone(photos.credit([]))
        self.assertIsNone(photos.credit([True, None]))
        self.assertIs(photos.credit([True, False]), False)
        self.assertIs(photos.credit([True, True]), True)


@unittest.skipUnless(shutil.which("convert") and shutil.which("compare"), "ImageMagick unavailable")
class ImageProbeTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.dir)

    def image(self, name, *draw):
        path = self.dir / name
        subprocess.run(["convert", "-size", "1280x720", "xc:#5b8731", *draw, str(path)], check=True)
        return path

    def test_probes_read_bezel_menu_loading_and_motion(self):
        world = self.image("world.png")
        pocket = self.image("pocket.png", "-fill", "#e6e080", "-draw", "rectangle 392,120 407,519",
                            "-draw", "rectangle 922,120 937,519")
        menu = self.image("menu.png", "-fill", "#6f6f6f", "-draw", "rectangle 340,195 939,234")
        loading = self.image("loading.png", "-fill", "#bb00bb", "-draw", "rectangle 640,0 1279,359")
        self.assertTrue(photos.pocket_open(pocket)); self.assertFalse(photos.pocket_open(world))
        self.assertTrue(photos.menu_open(menu)); self.assertFalse(photos.menu_open(world))
        self.assertTrue(photos.loading(loading)); self.assertFalse(photos.loading(world))
        self.assertEqual(photos.changed(world, world), 0)
        self.assertAlmostEqual(photos.changed(world, loading), .25, places=2)

    def test_motion_outside_the_pocket_area_is_not_counted(self):
        still = self.image("still.png", "-fill", "#0b111c", "-draw", "rectangle 426,84 905,635")
        clouds = self.image("clouds.png", "-fill", "#0b111c", "-draw", "rectangle 426,84 905,635",
                            "-fill", "white", "-draw", "rectangle 0,0 380,719", "-draw", "rectangle 960,0 1279,300")
        self.assertGreater(photos.changed(still, clouds), .1)
        self.assertEqual(photos.changed(still, clouds, photos.POCKET_AREA), 0)
        text = self.image("text.png", "-fill", "#0b111c", "-draw", "rectangle 426,84 905,635",
                          "-fill", "white", "-draw", "rectangle 450,90 860,110")
        self.assertGreater(photos.changed(still, text, photos.POCKET_AREA), 0)

    def test_wall_region_contains_all_wall_edges_and_ignores_surroundings(self):
        still = self.image("wall-still.png")
        outside = self.image("wall-outside.png", "-fill", "white", "-draw", "rectangle 0,0 400,200")
        self.assertGreater(photos.changed(still, outside), .02)
        self.assertEqual(photos.changed(still, outside, photos.WALL_AREA), 0)
        width, height, x, y = photos.WALL_AREA
        for i, (px, py) in enumerate(((x, y), (x+width-1, y), (x, y+height-1), (x+width-1, y+height-1))):
            edge = self.image(f"wall-edge-{i}.png", "-fill", "white", "-draw", f"point {px},{py}")
            self.assertGreater(photos.changed(still, edge, photos.WALL_AREA), 0)

    def test_diff_mask_shows_changes_outside_the_settle_region(self):
        still = self.image("before.png")
        changed = self.image("after.png", "-fill", "white", "-draw", "rectangle 0,0 20,20")
        mask = self.dir / "diff.png"
        photos.diff_mask(still, changed, mask)
        size = subprocess.check_output(["identify", "-format", "%wx%h", str(mask)], text=True)
        self.assertEqual(size, "1280x720")
        def pixel(x, y):
            return float(subprocess.check_output(["convert", str(mask), "-crop", f"1x1+{x}+{y}",
                                                  "-format", "%[fx:mean]", "info:"], text=True))
        self.assertEqual(pixel(0, 0), 1)
        self.assertEqual(pixel(500, 300), 0)



class CameraTests(unittest.TestCase):
    def test_c13_prefers_the_ar_camera_then_the_wall_camera(self):
        class Ctx: manifest = {"client_views": {"ar": "ar view", "wall": "wall view"}}
        self.assertEqual(c13.views(Ctx()), "ar view")
        Ctx.manifest = {"client_views": {"wall": "wall view"}}
        self.assertEqual(c13.views(Ctx()), "wall view")
        Ctx.manifest = {"client_views": {"pocket": "x"}}
        with self.assertRaisesRegex(Blocked, "client_views.ar or client_views.wall"):
            c13.views(Ctx())

    def test_c13_takes_its_five_photos_from_its_camera(self):
        taken = []
        class Ctx:
            manifest = {"client_views": {"ar": "ar view"}, "fixtures": {"goggles": {
                "linked_player_in_template": True, "verify_command": "v", "expected_turtles": 3}}}
            run = "private"
            def mining(self, start=True): taken.append(("mining", start))
            def lumber(self, start=True): taken.append(("lumber", start))
            def cli(self, *a, **k):
                if a[-1] == "start": taken.append("client")
                return {}
            def command(self, text): return {"output": "GATEB_GOGGLES_LINKED"}
            def record(self, name, value): return value
            def frame(self, name): return {"role": "ar", "buttons": [{"id": "turtles"}]}
            def wait(self, predicate, seconds=30): return predicate()
            def lua(self, name, code): return 3
            def navigate(self, name, role): return {"role": role}
            def read_store(self, computer, path): return {"turtles": len(taken) < 4}
            def click(self, name, ident): pass
            def power(self, name, action): pass
            def sleep(self, seconds): pass
        with patch.object(c13.camera, "take", side_effect=lambda ctx, name, view, pocket=False: taken.append((name, view, pocket))):
            verdict = c13.run(Ctx())
        # The jobs are assigned but not started before the client joins, so the AR layers have turtles to draw.
        self.assertEqual(taken[:3], [("mining", False), ("lumber", False), "client"])
        self.assertEqual(taken[3:], [("C13-layers-before.png", "ar view", False), ("C13-layers-toggled.png", "ar view", False)] +
                         [(f"C13-stability-{i}.png", "ar view", False) for i in range(3)])
        # Candidates earn no credit: the visual evidence is missing, never passed.
        self.assertEqual(verdict.status, "blocked")
        self.assertIn("Missing evidence: real photos", verdict.findings)

    def c3_context(self, taken, stock_after=0):
        class Ctx:
            manifest = {"client_views": {"pocket": "pocket view", "wall": "wall view"},
                        "computers": {"4": {"name": "miner1", "pos": [0, 0, 0]}, "5": {"name": "miner2", "pos": [1, 0, 0]}}}
            run, polls = "private", 0
            def mining(self, start=True): taken.append("mining")
            lumber = mining
            def cli(self, *a, **k): return {}
            def frame(self, name):
                self.polls += 1
                text = "storage room not found" if self.polls <= stock_after else "diamond 64"
                return {"role": "shop", "rows": [{"text": " > DIAMOND"}, {"text": text}], "buttons": [{"id": "item:minecraft:diamond"}, {"id": "order:1:minecraft:diamond"}]}
            def wait(self, predicate, seconds=30):
                for _ in range(5):
                    if predicate(): return True
                return None
            def screenshot(self, name): pass
            def navigate(self, name, role): return {"role": role, "rows": [], "buttons": []}
            def record(self, name, value): return value
            def request(self, *a, **k): return {}
            def terminal(self, name): return {}
            def computer(self, name): return 4
            def power(self, name, action): taken.append(("power", name, action))
            def type_text(self, name, text): pass
            def click(self, name, ident): pass
            def count_items(self, fixture, suffix): return 0
            def lua(self, name, code): return "generic"
        return Ctx()

    def run_c3(self, ctx, taken):
        with patch.object(c3, "coordinates_of", return_value=[True, True]), \
             patch.object(c3, "page", return_value=({}, True)), \
             patch.object(c3.camera, "take", side_effect=lambda ctx, name, view, pocket=False: taken.append((name, view, pocket))):
            return c3.run(ctx)

    def test_c3_powers_the_storage_room_before_the_shop_photos(self):
        taken = []
        self.run_c3(self.c3_context(taken, stock_after=3), taken)
        self.assertEqual(taken[0], ("power", "storage", "on"))
        self.assertIn("C3-pocket-shop.png", [t[0] for t in taken if isinstance(t, tuple)])

    def test_c3_blocks_when_the_shop_never_reaches_its_storage_room(self):
        taken = []
        with self.assertRaisesRegex(Blocked, "Shop on pocket shows no storage room"):
            self.run_c3(self.c3_context(taken, stock_after=100), taken)
        self.assertNotIn("C3-pocket-shop.png", [t[0] for t in taken if isinstance(t, tuple)])

    def test_c3_taps_the_wall_item_only_once_the_find_frame_arrives(self):
        taken, clicks = [], []
        ctx = self.c3_context(taken)
        items = {"role": "shop", "rows": [{"text": " DIAMOND .... 32"}],
                 "buttons": [{"id": "item:minecraft:coal", "y": 7}, {"id": "item:minecraft:diamond", "y": 8}]}
        frame, typed = ctx.frame, []
        def stale_until_polled(name):
            if typed and typed[0] > 0:
                typed[0] -= 1
                return items
            return frame(name)
        def type_text(name, text): typed.append(2)
        ctx.frame, ctx.type_text = stale_until_polled, type_text
        ctx.click = lambda name, ident: clicks.append((ident, ctx.frame(name) is items))
        self.run_c3(ctx, taken)
        self.assertIn(("item:minecraft:diamond", False), clicks)
        self.assertNotIn(("item:minecraft:diamond", True), clicks)

    def test_stocked_reads_the_shop_notice(self):
        self.assertFalse(c3.stocked({"rows": {"1": {"text": " ! storage room not found"}}}))
        self.assertTrue(c3.stocked({"rows": [{"text": " diamond ........ 64"}]}))

    def test_c3_opens_the_pocket_only_for_pocket_photos_and_never_passes_candidates(self):
        taken = []
        class Ctx:
            manifest = {"client_views": {"pocket": "pocket view", "wall": "wall view"},
                        "computers": {"4": {"name": "miner1", "pos": [0, 0, 0]}, "5": {"name": "miner2", "pos": [1, 0, 0]}}}
            run = "private"
            def mining(self, start=True): pass
            lumber = mining
            def cli(self, *a, **k): return {}
            def frame(self, name): return {"role": "generic", "rows": [{"text": " > DIAMOND"}], "buttons": [{"id": "item:minecraft:diamond"}, {"id": "order:1:minecraft:diamond"}]}
            def wait(self, predicate, seconds=30): return predicate()
            def screenshot(self, name): pass
            def navigate(self, name, role): return {"role": role, "rows": [], "buttons": []}
            def record(self, name, value): return value
            def request(self, *a, **k): return {}
            def terminal(self, name): return {}
            def computer(self, name): return 4
            def power(self, name, action): pass
            def type_text(self, name, text): pass
            def click(self, name, ident): pass
            def count_items(self, fixture, suffix): return 0
            def lua(self, name, code): return "generic"
        with patch.object(c3, "coordinates_of", return_value=[True, True]), \
             patch.object(c3, "page", return_value=({}, True)), \
             patch.object(c3.camera, "take", side_effect=lambda ctx, name, view, pocket=False: taken.append((name, view, pocket))):
            verdict = c3.run(Ctx())
        self.assertEqual(len(taken), 14)
        self.assertTrue(all(pocket == (view == "pocket view") and name.startswith(f"C3-{view.split()[0]}-")
                            for name, view, pocket in taken))
        self.assertIn("Missing evidence: real photos", verdict.findings)


class CandidateResultTests(unittest.TestCase):
    def execute(self, verdict, collect, candidates):
        class Ctx:
            commit, run, tick_rate, evidence, output = "a" * 40, "private", 20, [], Path(tempfile.mkdtemp())
            def command(self, text): pass
            def record(self, name, value): return value
        ctx = Ctx(); ctx.collect = collect
        def check(c):
            if candidates: c.candidates = list(candidates)
            return verdict
        with patch.object(run, "load", return_value=type("Check", (), {"run": staticmethod(check)})):
            result = run.execute(ctx, "C3", Path("."), prepare=False)
        shutil.rmtree(ctx.output)
        return result

    def test_candidates_never_pass_and_say_pending_review(self):
        result = self.execute(Verdict("pass"), Path("/tmp/candidates"), ["C3-wall-map.png"])
        self.assertEqual(result.status, "blocked")
        self.assertEqual(result.findings[0], "Candidates collected, pending review: 1 photos in /tmp/candidates")
        self.assertEqual(result.metrics["candidates"], ["C3-wall-map.png"])
        blocked = self.execute(Verdict("blocked", ["Missing evidence: real photos"]), Path("/tmp/c"), ["a.png"])
        self.assertEqual(blocked.findings[1:], ["Missing evidence: real photos"])

    def test_failures_stay_failures(self):
        self.assertEqual(self.execute(Verdict("fail", ["setups and returns"]), Path("/tmp/c"), ["a.png"]).status, "fail")

    def test_without_the_flag_results_are_unchanged(self):
        self.assertEqual(self.execute(Verdict("pass"), None, ["a.png"]).status, "pass")

    def test_flag_is_parsed(self):
        with patch.object(run, "resolve", return_value="a" * 40), patch("builtins.print") as out:
            self.assertEqual(run.main(["--checks", "C3,C13", "--collect-photos", "/tmp/x", "--plan"]), 0)
        self.assertEqual(json.loads(out.call_args.args[0])["checks"], ["C3", "C13"])


if __name__ == "__main__":
    unittest.main()
