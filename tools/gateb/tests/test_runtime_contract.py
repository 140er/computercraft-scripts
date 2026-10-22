import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from checks.context import Context
from checks.model import Blocked, Verdict


class ContractTests(unittest.TestCase):
    def test_admission_distinguishes_local_suites_from_parts_and_runtime(self):
        from checks.admission import full_local_suite
        locks="1: FLOCK ADVISORY WRITE 123 fd:01:456 0 EOF\n"
        slots={(253,1,456):"test-suite-local-2.lock"}
        self.assertIsNotNone(full_local_suite(locks,slots,lambda pid:["python3","cc-test"]))
        self.assertIsNone(full_local_suite(locks,slots,lambda pid:["python3","cc-test","--part","mine"]))
        slots={(253,1,456):"test-suite.lock"}
        self.assertIsNone(full_local_suite(locks,slots,lambda pid:["python3","/repo/tools/gateb/keeper.py"]))
        self.assertIsNotNone(full_local_suite(locks,slots,lambda pid:[]))

    def test_admission_refuses_high_load_before_runtime(self):
        from checks.admission import admit
        with patch("checks.admission.os.getloadavg",return_value=(8,4,2)):
            with self.assertRaisesRegex(Blocked,"load1"):
                admit()

    def test_drop_fixture_uses_stable_ids_and_checks_success(self):
        class Runtime:
            def request(self,world,request,timeout):
                self.code=request["code"];return {"values":[False]}
        runtime=Runtime()
        with tempfile.TemporaryDirectory() as temp:
            ctx=Context(runtime,"test",{"computers":{"1":{"name":"server"}},"fixtures":{"ore":{"pos":[1,2,3]}}},temp,"a"*40)
            with self.assertRaisesRegex(Blocked,"ore drop"):
                ctx.drops()
        self.assertIn("gateb_ore",runtime.code)

    def test_click_waits_for_an_observed_frame(self):
        initial={"role":"status","rev":1,"buttons":[{"id":"generic","x":1,"y":1,"w":4}]}
        updated={"role":"generic","rev":2,"buttons":initial["buttons"]}
        class Runtime:
            def request(self,world,request,timeout):
                if request["op"]=="frame": return initial
                return {"width":26,"height":20}
        with tempfile.TemporaryDirectory() as temp:
            ctx=Context(Runtime(),"test",{"computers":{"3":{"name":"pocket"}}},temp,"a"*40)
            with patch.object(ctx,"wait",return_value=updated) as wait:
                self.assertEqual(ctx.click("pocket","generic"),updated)
                wait.assert_called_once()

    def test_wall_outage_reads_the_monitor_overlay(self):
        class Runtime:
            def request(self,world,request,timeout):
                if request["op"]=="monitors": return {"left":{"lines":[{"text":"stale"}]}}
                return {"lines":[{"text":"> "}]}
        with tempfile.TemporaryDirectory() as temp:
            ctx=Context(Runtime(),"test",{"computers":{"2":{"name":"wall"}}},temp,"a"*40)
            self.assertEqual(ctx.screen_text("wall"),"stale")

    def test_native_keyboard_char_events(self):
        class Runtime:
            def __init__(self): self.requests=[]
            def request(self, world, request, timeout): self.requests.append(request); return {}
        runtime=Runtime()
        with tempfile.TemporaryDirectory() as temp:
            ctx=Context(runtime,"test",{"computers":{"2":{"name":"wall"}}},temp,"a"*40)
            ctx.type_text("wall","diamond")
        self.assertEqual([q["event"] for q in runtime.requests], ["char"]*7+["key"])
        self.assertEqual(runtime.requests[-1]["args"], [257,False])

    def test_runtime_block_preserves_the_actionable_reason(self):
        with tempfile.TemporaryDirectory() as temp:
            ctx=Context(object(),"test",{},temp,"a"*40)
            with patch("checks.context.subprocess.run",return_value=SimpleNamespace(returncode=1,stdout='{"ok":false,"error":"Template preparation did not finish"}')):
                with self.assertRaisesRegex(Blocked,"Template preparation did not finish"):
                    ctx.cli("clone","test")

    def test_tick_clock_does_not_use_minecraft_calendar(self):
        class Runtime:
            def request(self, world, request, timeout):
                self.code=request["code"]; return {"values":[1800000]}
        runtime=Runtime()
        with tempfile.TemporaryDirectory() as temp:
            ctx=Context(runtime,"test",{"computers":{"1":{"name":"server"}}},temp,"a"*40)
            self.assertEqual(ctx.game_clock(),1800000)
        self.assertIn("SO.now()",runtime.code)
        self.assertIn("os.clock()",runtime.code)
        self.assertNotIn("ingame",runtime.code)

    def test_native_unload_turn_is_not_movement(self):
        from checks.c11 import analyze
        proof={}
        worker={"id":"active","park":False,"pose":{"x":0,"y":0,"z":0,"f":0}}
        rows=[{"epoch":t,"workers":{"6":worker},"mine":{"turtles":{}}} for t in (0,121)]
        rows.append({"epoch":124,"workers":{"6":{**worker,"pose":{**worker["pose"],"f":1}}},"mine":{"turtles":{}}})
        self.assertEqual(analyze(rows,0,122,proof)["movement_recovery_seconds"],{})

    def test_failed_exact_install_does_not_run_check(self):
        calls=[]
        class FakeContext:
            run="private";commit="a"*40;tick_rate=20;evidence=[]
            def cli(self,*args,**kwargs):
                calls.append(args)
                if args[0]=="install":return {"sha":self.commit,"errors":["bad file"]}
            def record(self,*args):pass
            def command(self,*args):pass
        with patch.object(run,"admit"), patch.object(run,"load") as module:
            result=run.execute(FakeContext(),"C5",Path("/runtime"))
            self.assertEqual(result.status,"blocked")
            module.assert_not_called()

    def test_scheduler_cleans_worlds_and_keeps_other_results(self):
        calls=[]
        class FakeContext(Context):
            def cli(self,*args,**kwargs):
                calls.append(args)
                if args[0]=="install": return {"sha":self.commit,"errors":[]}
                return {}
            def request(self,op,**kwargs):return {"computers":{}}
            def lua(self,*args):return True
            def command(self,*args):pass
        class Check:
            TITLE="fixture"
            @staticmethod
            def run(ctx):
                if ctx.output.name=="C3":
                    ctx.linked_install()
                    raise Blocked("Missing reviewed pixels")
                return Verdict("pass")
        with tempfile.TemporaryDirectory() as temp, patch.object(run,"admit"), patch.object(run,"Context",FakeContext), patch.object(run,"runtime_class",return_value=lambda:object()), patch.object(run,"resolve",return_value="a"*40), patch.object(run,"load",return_value=Check):
            code=run.main(["--checks","C1,C3,C5","--output",temp,"--worlds","2"])
            report=json.loads((Path(temp)/"report.json").read_text())
        self.assertEqual(code,1)
        self.assertEqual(report["counts"],{"pass":2,"fail":0,"blocked":1})
        self.assertEqual(sum(c[0]=="reset" for c in calls),2)
        self.assertEqual(sum(c[0]=="stop" for c in calls),2)
        self.assertEqual(sum(c[:2]==("pool","up") for c in calls),1)
        self.assertTrue(any("--prefix" in c for c in calls))
        self.assertFalse(any(c[0] in ("clone","serve") for c in calls))


if __name__=="__main__":unittest.main()
