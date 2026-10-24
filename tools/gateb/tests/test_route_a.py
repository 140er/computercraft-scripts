"""C2, C3 and C13 against the route A server terminal, mining tabs and template goggles."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks import c2, c3, c13
from checks.context import sanitize
from checks.model import Blocked

DOTS = "·" * 11
NORMAL = [" SO SERVER #1  ------------- up 0h02 ", f" leases {DOTS} 0   pair {DOTS} -      ",
          " [P] pair    [R] roles   [L] log     "]


def terminal(lines):
    return {"width": 37, "height": len(lines), "lines": [{"text": t} for t in lines]}


class ServerPromptTests(unittest.TestCase):
    def test_route_a_footer_counts_only_without_a_live_code(self):
        self.assertTrue(c2.prompt_restored(terminal(NORMAL)))
        live = [NORMAL[0], NORMAL[1].replace("-     ", "574698"), NORMAL[2]]
        self.assertFalse(c2.prompt_restored(terminal(live)))
        code = [NORMAL[0], " PAIR CODE ---------------------- ", " [P] new code  [Esc] cancel "]
        self.assertFalse(c2.prompt_restored(terminal(code)))
        self.assertFalse(c2.prompt_restored(terminal(NORMAL[:2])))

    def test_legacy_prompts_still_count(self):
        self.assertTrue(c2.prompt_restored(terminal(["Press P to pair"])))
        self.assertTrue(c2.prompt_restored(terminal(["[P] pair a client"])))

    def test_evidence_redacts_the_pair_leader_code(self):
        text = sanitize(NORMAL[1].replace("-     ", "574698"))
        self.assertNotIn("574698", text)
        self.assertIn("[redacted]", text)
        self.assertIn("pair rejected 60000", sanitize("13:15:04 so-server: pair rejected 60000"))


def tab_row(width, active):
    """ MINING   main   setup  with the active tab on colour 7."""
    bg = ["f"] * width
    for x in {"main": range(10, 16), "setup": range(17, 24)}[active]:
        bg[x-1] = "7"
    return {"text": " MINING   main   setup    ", "bg": "".join(bg), "fg": "0" * width}


class Pocket:
    """A pocket mining screen with route A tabs, list rows and turtle details."""
    def __init__(self, legacy=False, coordinates_in_list=False):
        self.legacy, self.listed = legacy, coordinates_in_list
        self.page, self.turtle, self.clicks, self.records = "main", None, [], {}
        self.manifest = {"computers": {"4": {"name": "miner1", "pos": [-5, 64, 3], "kind": "turtle"},
                                       "5": {"name": "miner2", "pos": [-7, 64, 3], "kind": "turtle"}}}

    def computer(self, name):
        return next(int(k) for k, v in self.manifest["computers"].items() if v["name"] == name)

    def frame(self, name):
        if self.turtle:
            pos = ",".join(map(str, self.manifest["computers"][str(self.turtle)]["pos"]))
            return {"role": "mining", "rows": [{"text": f" #{self.turtle}"}, {"text": f" POS {pos} S"}],
                    "buttons": [{"id": "turtle-back", "x": 1, "y": 20, "w": 26, "h": 1}]}
        if self.legacy:
            buttons = [{"id": "mine-back" if self.page == "setup" else "setup", "x": 1, "y": 18, "w": 10, "h": 1}]
            return {"role": "mining", "rows": [{"text": "MINING"}], "buttons": buttons}
        rows = {str(i + 1): {"runs": [[26, "0", "f"]], "text": ""} for i in range(20)}
        rows["1"] = tab_row(26, self.page)
        buttons = [{"id": "tab:main", "x": 10, "y": 1, "w": 6, "h": 1},
                   {"id": "tab:setup", "x": 17, "y": 1, "w": 7, "h": 1}]
        if self.page == "main":
            for i, ident in enumerate((4, 5)):
                at = " " + ",".join(map(str, self.manifest["computers"][str(ident)]["pos"])) if self.listed else ""
                rows[str(11 + i)] = {"text": f" > {ident}  stopped{at}", "bg": "f" * 26}
                buttons.append({"id": f"turtle:{ident}", "x": 2, "y": 11 + i, "w": 24, "h": 1})
        return {"role": "mining", "rows": rows, "buttons": buttons}

    def click(self, name, ident):
        self.clicks.append(ident)
        if ident in ("tab:setup", "setup"): self.page = "setup"
        elif ident in ("tab:main", "tab:overview", "mine-back"): self.page = "main"
        elif ident.startswith("turtle:"): self.turtle = int(ident[7:])
        elif ident == "turtle-back": self.turtle = None
        return self.frame(name)

    def record(self, name, value):
        self.records[name] = value
        return value


class MiningPageTests(unittest.TestCase):
    def test_active_tab_reads_bg_strings_and_runs(self):
        frame = Pocket().frame("pocket")
        self.assertEqual(c3.active_tab(frame), "tab:main")
        frame["rows"]["1"] = {"runs": [[16, "0", "f"], [7, "0", "7"], [3, "0", "f"]], "text": ""}
        self.assertEqual(c3.active_tab(frame), "tab:setup")
        frame["rows"]["1"] = {"runs": [[26, "0", "f"]], "text": ""}
        self.assertIsNone(c3.active_tab(frame))

    def test_route_a_tabs_open_setup_and_return(self):
        ctx = Pocket()
        setup, opened = c3.page(ctx, "pocket", "mining", "setup")
        self.assertTrue(opened)
        self.assertEqual(c3.active_tab(setup), "tab:setup")
        _, returned = c3.page(ctx, "pocket", "mining", "main")
        self.assertTrue(returned)
        self.assertEqual(ctx.clicks, ["tab:setup", "tab:main"])

    def test_tab_that_does_not_switch_page_fails(self):
        ctx = Pocket()
        ctx.click = lambda name, ident: ctx.frame(name)
        self.assertFalse(c3.page(ctx, "pocket", "mining", "setup")[1])

    def test_legacy_setup_and_back_buttons_still_work(self):
        ctx = Pocket(legacy=True)
        self.assertTrue(c3.page(ctx, "pocket", "mining", "setup")[1])
        self.assertTrue(c3.page(ctx, "pocket", "mining", "main")[1])
        self.assertEqual(ctx.clicks, ["setup", "mine-back"])

    def test_missing_tab_blocks(self):
        ctx = Pocket()
        ctx.frame = lambda name: {"role": "mining", "rows": [], "buttons": [{"id": "start", "x": 1, "y": 1}]}
        with self.assertRaisesRegex(Blocked, "Visible setup tab absent on pocket mining"):
            c3.page(ctx, "pocket", "mining", "setup")

    def test_narrow_list_reads_coordinates_from_turtle_details(self):
        ctx = Pocket()
        found = c3.coordinates_of(ctx, "pocket", ctx.frame("pocket"), ("miner1", "miner2"))
        self.assertEqual(found, [True, True])
        self.assertEqual(ctx.clicks, ["turtle:4", "turtle-back", "turtle:5", "turtle-back"])
        self.assertIn("C3-pocket-mining-turtle-4.json", ctx.records)

    def test_wide_list_coordinates_need_no_details(self):
        ctx = Pocket(coordinates_in_list=True)
        self.assertEqual(c3.coordinates_of(ctx, "pocket", ctx.frame("pocket"), ("miner1", "miner2")), [True, True])
        self.assertEqual(ctx.clicks, [])

    def test_wrong_coordinates_fail(self):
        ctx = Pocket()
        frame = ctx.frame("pocket")
        ctx.manifest["computers"]["5"]["pos"] = [1, 2, 3]
        original = ctx.frame
        def details(name):
            f = original(name)
            if ctx.turtle == 5: f["rows"][1]["text"] = " POS -7,64,3 S"
            return f
        ctx.frame = details
        self.assertEqual(c3.coordinates_of(ctx, "pocket", frame, ("miner1", "miner2")), [True, False])


LINKED = "[13:21:21] [Server thread/INFO] [minecraft/MinecraftServer]: [Not Secure] [GateBTester] {}\n"


class World:
    """Native console replies for a player who holds, wears or lacks linked goggles."""
    def __init__(self, held=True, worn=False, fixtures=None):
        self.held, self.worn, self.commands, self.output = held, worn, [], Path(tempfile.mkdtemp())
        self.manifest = {"computers": {"4": {"name": "miner1", "kind": "turtle"}, "5": {"name": "miner2", "kind": "turtle"},
                                       "6": {"name": "lumber", "kind": "turtle"}, "3": {"name": "pocket", "kind": "pocket"},
                                       "1": {"name": "server", "kind": "computer"}},
                         "fixtures": fixtures or {"ar": {"kind": "cc_ar:ar_controller", "pos": [0, 64, 1]}}}
        self.run, self.records = "private", {}

    def computer(self, name):
        return next(int(k) for k, v in self.manifest["computers"].items() if v["name"] == name)

    def fixture(self, name):
        if name not in self.manifest["fixtures"]: raise Blocked(f"Template has no fixture {name}")
        return self.manifest["fixtures"][name]

    def command(self, text):
        self.commands.append(text)
        if text.endswith("say GATEB_PLAYER_READY"): return {"output": LINKED.format("GATEB_PLAYER_READY")}
        if text.startswith("item replace") and self.held: self.held, self.worn = False, True
        if "Slot:8b" in text and self.held: return {"output": LINKED.format("GATEB_GOGGLES_HELD")}
        if "Slot:103b" in text and self.worn and "x:0.0d,y:64.0d,z:1.0d" in text:
            return {"output": LINKED.format("GATEB_GOGGLES_LINKED")}
        return {"output": "[Server] <completion>\n"}

    def wait(self, predicate, seconds=30): return predicate()
    def frame(self, name): return {"role": "pocket", "buttons": [{"id": "x"}]}
    def cli(self, *args, **kwargs): return {}
    def lua(self, name, code): return 3
    def navigate(self, name, role): return {"role": role}
    def read_store(self, computer, path): return {}
    def screenshot(self, name): (self.output / name).write_bytes(b"")

    def record(self, name, value):
        self.records[name] = value
        return value


class GogglesTests(unittest.TestCase):
    def test_template_goggles_are_worn_and_verified_natively(self):
        world = World()
        goggles = c13.provision(world)
        self.assertTrue(any(c == "item replace entity GateBTester armor.head from entity GateBTester hotbar.8" for c in world.commands))
        self.assertIn('Slot:103b,id:"cc_ar:ar_goggles"', goggles["verify_command"])
        self.assertIn("x:0.0d,y:64.0d,z:1.0d", goggles["verify_command"])
        self.assertEqual(goggles["expected_turtles"], 3)
        self.assertTrue(c13.said(world.command(goggles["verify_command"])["output"], "GATEB_GOGGLES_LINKED"))

    def test_already_worn_goggles_need_no_swap(self):
        world = World(held=False, worn=True)
        c13.provision(world)
        self.assertFalse(any(c.startswith("item replace") for c in world.commands))

    def test_player_without_linked_goggles_blocks(self):
        with self.assertRaisesRegex(Blocked, "holds no goggles linked"):
            c13.provision(World(held=False))

    def test_goggles_linked_elsewhere_do_not_count(self):
        world = World(fixtures={"ar": {"pos": [5, 64, 1]}})
        goggles = c13.provision(world)
        self.assertFalse(c13.said(world.command(goggles["verify_command"])["output"], "GATEB_GOGGLES_LINKED"))

    def test_echoed_command_text_does_not_prove_linking(self):
        self.assertFalse(c13.said("Unknown command: say GATEB_GOGGLES_LINKED", "GATEB_GOGGLES_LINKED"))

    def test_manifest_fixture_still_replaces_native_setup(self):
        fixture = {"linked_player_in_template": True, "verify_command": "custom", "expected_turtles": 3}
        world = World(fixtures={"goggles": fixture})
        self.assertIs(c13.provision(world), fixture)
        self.assertEqual(world.commands, [])
        with self.assertRaisesRegex(Blocked, "native player"):
            c13.provision(World(fixtures={"goggles": {"verify_command": "x"}}))

    def test_run_passes_the_goggles_gate_and_records_the_link(self):
        world = World()
        world.manifest["client_views"] = {"wall": "tp GateBTester 0 64 0"}
        def take(ctx, name, view, pocket=False):
            ctx.screenshot(name)
            return c13.camera.check(ctx, name)
        with patch.object(c13.camera, "take", side_effect=take), self.assertRaises(Blocked) as raised:
            c13.run(world)
        # Without reviewed pixel references the check stops at the first photo, not at goggles.
        self.assertIn("pixel reference", str(raised.exception))
        self.assertTrue(world.records["C13-native-goggles-link.json"]["linked"])


class PocketReadyTests(unittest.TestCase):
    def test_waits_through_frames_not_yet_received(self):
        from checks.model import pocket_frame
        class Late:
            calls = 0
            def frame(self, name):
                self.calls += 1
                if self.calls < 3: raise Blocked("Runtime must expose the latest received view.frame as GATEB_FRAME")
                return {"role": "pocket", "buttons": [{"id": "x"}]}
            def wait(self, predicate, seconds):
                for _ in range(5):
                    if predicate(): return predicate()
        self.assertEqual(pocket_frame(Late())["role"], "pocket")
        class Never(Late):
            def frame(self, name): raise Blocked("no frame")
        with self.assertRaisesRegex(Blocked, "Pocket did not become available"):
            pocket_frame(Never())


if __name__ == "__main__":
    unittest.main()
