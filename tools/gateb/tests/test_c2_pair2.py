import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks import c2


def observations():
    attempts = [dict(ok=False, reason="wrong code", sender=60000 + max(0, n-2),
                     live=n < 9, messages=["pair2", "pair2"]) for n in range(10)]
    return dict(paired_clients=5, attempts=attempts, minute_limited=True, sender_limited=True,
                probe_unpaired=True, success=dict(ok=True, messages=["pair2", "pair2"]),
                server_key_saved=True, server_prompt_restored=True)


class Pair2Tests(unittest.TestCase):
    def test_evidence_rejects_early_burn_wrong_count_and_legacy_clients(self):
        good = observations()
        self.assertEqual(c2.evaluate(good).status, "pass")
        for field in ("minute_limited", "sender_limited", "probe_unpaired", "server_key_saved"):
            bad = copy.deepcopy(good); bad[field] = False
            self.assertEqual(c2.evaluate(bad).status, "fail")
        for index in range(9):
            bad = copy.deepcopy(good); bad["attempts"][index]["live"] = False
            self.assertEqual(c2.evaluate(bad).status, "fail")
        for reason in ("busy", "timeout", "no code"):
            bad = copy.deepcopy(good); bad["attempts"][0]["reason"] = reason
            self.assertEqual(c2.evaluate(bad).status, "fail")
        for target in ("success", "attempts"):
            bad = copy.deepcopy(good)
            (bad[target] if target == "success" else bad[target][0])["messages"] = ["pair"]
            self.assertEqual(c2.evaluate(bad).status, "fail")
        bad = copy.deepcopy(good)
        for a in bad["attempts"]: a["sender"] = 60000
        self.assertEqual(c2.evaluate(bad).status, "fail")

    def test_driver_observes_rejections_waits_and_pairs_probe(self):
        class Context:
            manifest = {"computers": {str(i): {} for i in range(1, 8)}}
            clock = 0
            attempts = 0
            guesses = 0
            waits = 0
            def computer(self, name): return 1 if name == "server" else 7
            def lua(self, name, code):
                if "local n=0" in code: return 5
                if 'return SO.pair.invite()' == code: return "123456"
                if "return assert(load(" in code:
                    self.attempts += 1
                    if self.attempts == 13:
                        self.assert_success_code = '("123456",1,7)' in code
                        return dict(ok=True, reason="", messages=["pair2", "pair2"])
                    busy = self.attempts in (3, 5)
                    if not busy: self.guesses += 1
                    return dict(ok=False, reason="busy" if busy else "wrong code",
                                messages=["pair2"] if busy else ["pair2", "pair2"])
                if "pending() ~= nil" in code: return self.guesses < 10
                return True
            def record(self, name, value): return value
            def terminal(self, name): return {"lines": [{"text": "Press P to pair"}]}
            def game_clock(self): self.clock += 61000; return self.clock
            def wait(self, predicate, seconds): self.waits += 1; return predicate()
        ctx = Context()
        # Three wrong codes by the first sender plus seven distinct senders,
        # two budget rejections, then one successful native-probe join.
        self.assertEqual(c2.run(ctx).status, "pass")
        self.assertEqual(ctx.waits, 2)
        self.assertTrue(ctx.assert_success_code)

    @unittest.skipUnless(shutil.which("lua5.2"), "Lua 5.2 unavailable")
    def test_native_sender_adapter_keeps_globals_and_closes_channel(self):
        source = '''local fn=assert(load(SOURCE))
          local realID=os.getComputerID
          os.getComputerID=function() return 7 end
          local opened,closed,wire
          local modem={isOpen=function() return false end,
            open=function(c) opened=c end,close=function(c) closed=c end,
            transmit=function(c,r,m) wire=m end}
          peripheral={find=function() return modem end}
          os.pullEvent=function()
            return "modem_message","left",60000,1,
              {nRecipient=60000,nSender=1,sProtocol="so",message={t="err"}}
          end
          local realLoad=loadfile
          loadfile=function(path,mode,env)
            if path=="so-proto.lua" then return function() return {} end end
            if path=="so-store.lua" then return function() return {} end end
            return function() return {open=function() end,join=function(code,server)
              assert(env.os.getComputerID()==60000 and os.getComputerID()==7)
              env.rednet.send(server,{t="pair2",from=60000},"so")
              local event,id,msg,protocol=env.os.pullEvent("rednet_message")
              assert(event=="rednet_message" and id==server and msg.t=="err" and protocol=="so")
              return nil,"wrong code" end} end
          end
          local result=fn("000000",1,60000)
          assert(result.reason=="wrong code" and not result.ok)
          assert(opened==60000 and closed==60000)
          assert(wire.nSender==60000 and wire.nRecipient==1 and wire.message.t=="pair2")
          assert(result.messages[1]=="pair2")
          loadfile=realLoad;os.getComputerID=realID
        '''.replace("SOURCE", json.dumps(c2.ATTEMPT))
        done = subprocess.run(["lua5.2", "-"], input=source, text=True, capture_output=True)
        self.assertEqual(done.returncode, 0, done.stderr)


if __name__ == "__main__": unittest.main()
