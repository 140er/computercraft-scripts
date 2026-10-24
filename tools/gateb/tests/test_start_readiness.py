import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks.model import Blocked
from checks.readiness import SNAPSHOT, start_job


class Startup:
    def __init__(self, readings):
        self.readings = iter(readings)
        self.starts = 0
        self.records = {}

    def lua(self, name, code):
        if '.input({text="start"})' in code:
            self.starts += 1
        return next(self.readings)

    def wait(self, predicate, seconds):
        for _ in range(3):
            result = predicate()
            if result:
                return result
        return None

    def record(self, name, value):
        self.records[name] = value
        return value


READY = {"ready": True, "disk_ready": True, "running": False}
MISSING = {"ready": False, "disk_ready": True, "running": False, "alert": {"text": "fuel missing"}}


class StartReadinessTests(unittest.TestCase):
    def test_delayed_fuel_reports_precede_start(self):
        ctx = Startup([MISSING, MISSING, READY, {**READY, "running": True}])
        start_job(ctx, "mining")
        self.assertEqual(ctx.starts, 1)
        self.assertTrue(ctx.records["mining-start-1-readiness.json"]["ready"])

    def test_readiness_refusal_waits_again_and_retries_once(self):
        ctx = Startup([READY, MISSING, MISSING, READY, {**READY, "running": True}])
        start_job(ctx, "lumber")
        self.assertEqual(ctx.starts, 2)
        self.assertEqual(ctx.records["lumber-start-1-result.json"]["alert"]["text"], "fuel missing")

    def test_persistent_readiness_failure_never_starts(self):
        ctx = Startup([MISSING] * 3)
        with self.assertRaisesRegex(Blocked, "readiness did not arrive"):
            start_job(ctx, "mining")
        self.assertEqual(ctx.starts, 0)
        self.assertIn("mining-start-1-readiness.json", ctx.records)

    def test_second_readiness_refusal_stops(self):
        ctx = Startup([READY, MISSING, READY, MISSING])
        with self.assertRaisesRegex(Blocked, "START refused"):
            start_job(ctx, "mining")
        self.assertEqual(ctx.starts, 2)

    def test_disk_and_unexplained_refusals_are_not_retried(self):
        for refusal in ({**MISSING, "disk_ready": False}, READY):
            ctx = Startup([READY, refusal])
            with self.subTest(refusal=refusal), self.assertRaisesRegex(Blocked, "START refused"):
                start_job(ctx, "lumber")
            self.assertEqual(ctx.starts, 1)

    @unittest.skipUnless(shutil.which("lua5.2"), "Lua 5.2 is unavailable")
    def test_snapshot_reads_product_checks_and_requires_every_worker(self):
        source = '''local fuel,uncertain,lost,paired,disk=10000,false,false,true,true
local passed,total=9,9
local snapshot=assert(load(CODE))
SO={mods={display={screen=function(role) return {render=function(w,h,session)
  assert(w==120 and h==80 and session[role].page=="setup")
  local rows={};for i=1,h do rows[i]={text=string.rep(" ",61)} end
  rows[3].text=rows[3].text.."READY ------ "..passed.."/"..total
  rows[4].text=rows[4].text.."* fuel #4 10000"
  return {rows=rows}
end} end},state={canStart=function() return disk end,get=function() return nil end},
lease={status=function() return {uncertain=uncertain,lost=lost} end}},
pair={key=function() return paired and "present" or nil end}}
local mod={turtleView=function() return {["4"]={fuel=10000,pose={}},["5"]={fuel=fuel,pose={}}} end,
mapView=function() return {running=false} end}
SO.mods.mine=mod;SO.mods.lumber=mod
assert(snapshot().ready and snapshot().total==9 and #snapshot().checks==1)
fuel=nil;assert(not snapshot().ready)
fuel=0;assert(not snapshot().ready)
fuel=10000;uncertain=true;assert(not snapshot().ready)
uncertain=false;lost=true;assert(not snapshot().ready)
lost=false;paired=false;assert(not snapshot().ready)
paired=true;disk=false;assert(not snapshot().ready)
disk=true;passed=8;assert(not snapshot().ready)
passed=9;total=0;assert(not snapshot().ready)
'''
        for role in ("mining", "lumber"):
            code = SNAPSHOT.replace("ROLE", json.dumps(role))
            result = subprocess.run(["lua5.2", "-"], input=source.replace("CODE", json.dumps(code)), text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
