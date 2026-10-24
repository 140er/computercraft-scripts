import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from checks import c14
from checks.context import pinned_http_update


class UpdatePinTests(unittest.TestCase):
    def test_rejects_non_commit_pin(self):
        for ref in ("server-only", "a" * 39, '";error("bad")'):
            with self.assertRaises(ValueError): pinned_http_update(ref)

    @unittest.skipUnless(shutil.which("lua5.2"), "Lua 5.2 unavailable")
    def test_resolver_is_pinned_payload_http_and_cleanup_remain_real(self):
        for terminate in (False, True):
            source = '''local requests={}
              http={get=function(url,headers,binary)
                assert(not url:find("branches/server-only",1,true))
                requests[#requests+1]=url;assert(binary==true)
                return {getResponseCode=function() return 200 end,
                  readAll=function() return "payload" end,close=function() end}
              end}
              local saved=http.get;local savedPrint=print
              shell={run=function(program,action)
                assert(program=="install" and action=="update")
                local r=http.get("https://api.github.com/repos/140er/computercraft-scripts/branches/server-only")
                local body=r.readAll();r.close()
                assert(body=='{"commit":{"sha":"SHA"}}')
                http.get("https://raw.githubusercontent.com/140er/computercraft-scripts/SHA/update.lua",nil,true)
                if TERMINATE then error("Terminated") end
                return true
              end}
              local ok,result=pcall(assert(load(CODE)))
              assert(http.get==saved and print==savedPrint)
              assert(#requests==1)
              if TERMINATE then assert(not ok and result:find("Terminated"))
              else assert(ok and result.ran and result.requests==2 and result.failures==0) end
            '''.replace("SHA", "a"*40).replace("TERMINATE", str(terminate).lower()).replace("CODE", json.dumps(pinned_http_update("a"*40)))
            done = subprocess.run(["lua5.2", "-"], input=source, text=True, capture_output=True)
            self.assertEqual(done.returncode, 0, done.stderr)

    def test_both_update_jobs_use_commit_under_test(self):
        class Context:
            commit = "b" * 40
            jobs = []
            def computer(self, name): return 2
            def integrity(self, name): return {"files": {}, "pairing": {}}
            def terminal(self, name): return {"lines": [{"text": "Press P"}]}
            def record(self, name, value): return value
            def power(self, *args): pass
            def frame(self, name): return {"role": "generic"}
            def lua(self, name, code): return {"requests": 1, "failures": 0, "program": "/display.lua", "running": True}
            def wait(self, predicate, seconds): return predicate()
            def request(self, op, **kwargs):
                if op == "lua_async":
                    self.jobs.append(kwargs["code"]); return {"job": str(len(self.jobs))}
                if op == "files": return {"content": self.commit}
                if op == "lua_job": return {"state": "failed", "error": "Terminated"} if kwargs["job"] == "1" else {"state": "running"}
                return {}
        ctx = Context()
        self.assertEqual(c14.run(ctx).status, "pass")
        self.assertEqual(ctx.jobs, [pinned_http_update(ctx.commit)] * 2)


if __name__ == "__main__": unittest.main()
