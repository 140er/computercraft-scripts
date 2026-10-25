import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from checks import c16, update_fixture
from checks.model import Blocked

OLD, TARGET, OUTSIDE = "a" * 40, "b" * 40, "c" * 40
NAMES = [f"c16-{i}" for i in range(1, 11)]


def context():
    ctx = Mock(commit=TARGET, tick_rate=20, c16_fake_remaining=0)
    ctx.record.side_effect = lambda name, value: value
    ctx.computer.side_effect = lambda name: NAMES.index(name) + 100 if name in NAMES else 1
    ctx.wait.side_effect = lambda predicate, seconds: predicate()
    return ctx


def fingerprint(revision=OLD):
    return {"files": {"worker.lua": hashlib.sha256(b"source").hexdigest()},
            "pairing": {"so-keys": "hash"}, "revision": revision, "journal": {"id": "100-1"},
            "config": {"remoteUpdates": True, "settingsSeq": 7, "autoToolSwap": False}}


def events():
    return [{"kind": "hello", "boot": 1, "revision": OLD},
            {"kind": "ack", "boot": 1, "revision": TARGET, "state": "accepted"},
            {"kind": "handoff", "boot": 1, "revision": TARGET, "running": OLD},
            *[{"kind": "api", "boot": 1} for _ in range(4)],
            {"kind": "reboot", "boot": 1},
            {"kind": "hello", "boot": 2, "revision": TARGET}]


def rows():
    return {str(i): {"paired": True, "lease": {"last": {"status": "reported", "ok": True}},
                     "update": {"state": "complete", "running": TARGET}} for i in range(100, 110)}


@pytest.mark.parametrize("criterion", c16.CRITERIA)
@pytest.mark.parametrize("passed", [True, False, None])
def test_each_criterion_through_mocked_context(criterion, passed):
    ctx = context()
    data = {"worker_count": 10, "tick_rate": 20, **dict.fromkeys(c16.CRITERIA, True)}
    data[criterion] = passed
    assert c16.evaluate(ctx.record("proof.json", data)).status == (
        "blocked" if passed is None else "pass" if passed else "fail")


@pytest.mark.parametrize("count,tps", [(9, 20), (10, 80)])
def test_requires_ten_and_normal_tps(count, tps):
    assert c16.evaluate({"worker_count": count, "tick_rate": tps,
                         **dict.fromkeys(c16.CRITERIA, True)}).status == "fail"


@pytest.mark.parametrize("remaining,allowed", [(0, False), (39, False), (40, True), (60, True)])
def test_unauthenticated_host_admission(remaining, allowed):
    ctx = context()
    body = {"resources": {"core": {"limit": 60, "remaining": remaining, "reset": 42}}}
    response = io.BytesIO(json.dumps(body).encode())
    with patch.object(c16, "urlopen", return_value=response) as http:
        if allowed:
            assert c16.admit_budget(ctx)["remaining"] == remaining
        else:
            with pytest.raises(Blocked, match="at least 40"):
                c16.admit_budget(ctx)
    req = http.call_args.args[0]
    assert req.full_url == "https://api.github.com/rate_limit"
    assert "Authorization" not in req.headers
    assert ctx.record.call_args.args[0] == "C16-budget-before.json"


@pytest.mark.parametrize("core", [{}, {"limit": 5000, "remaining": 50},
                                   {"limit": 60, "remaining": "40"}, {"limit": 60, "remaining": True}])
def test_unverifiable_quota_blocks(core):
    ctx = context()
    with patch.object(c16, "urlopen", return_value=io.BytesIO(json.dumps({"resources": {"core": core}}).encode())):
        with pytest.raises(Blocked, match="cannot verify"):
            c16.admit_budget(ctx)


def test_quota_network_error_blocks_before_provisioning():
    ctx = context()
    with patch.object(c16, "urlopen", side_effect=OSError("offline")), patch.object(update_fixture, "prepare") as prepare:
        with pytest.raises(Blocked, match="cannot verify"):
            c16.run(ctx)
    prepare.assert_not_called()


@pytest.mark.parametrize("missing", [None, "ack", "handoff", "reboot", "hello", "api"])
def test_success_needs_ack_handoff_native_reboot_new_hello_and_four_calls(missing):
    ctx = context()
    observed = events()
    if missing:
        observed = [e for e in observed if e["kind"] != missing]
    with patch.object(c16, "fingerprint", return_value=fingerprint(TARGET)), \
         patch.object(c16, "trace", return_value={"events": observed}), \
         patch.object(update_fixture, "worker_files", return_value={"worker.lua": b"source"}):
        assert c16.updated(ctx, NAMES[0], OLD, {"fingerprint": fingerprint(), "events": 0}) == (missing is None)


@pytest.mark.parametrize("mutation", ["revision", "pairing", "files", "journal", "config"])
def test_refusals_require_files_pairing_revision_and_journal_unchanged(mutation):
    before = fingerprint()
    after = copy.deepcopy(before)
    after[mutation] = "changed"
    assert not c16.unchanged(before, after)


@pytest.mark.parametrize("budget", [False, True])
@pytest.mark.parametrize("passed", [False, True])
def test_actual_refusal_observations_with_mocked_ctx(budget, passed):
    ctx = context()
    terminal = {"lines": [{"text": ("Update API refused" if budget else "Pinned revision ancestry refused") if passed else "Installed worker"}]}
    observed = ([{"kind": "fake_budget", "remaining": 0}] if budget else [
        {"kind": "ack", "revision": OUTSIDE, "state": "accepted"},
        {"kind": "handoff", "revision": OUTSIDE, "running": OLD},
        {"kind": "api", "url": f"https://api.github.com/repos/140er/computercraft-scripts/compare/{OUTSIDE}...{TARGET}"}])
    observed += [{"kind": "reboot", "terminal": terminal}, {"kind": "hello", "boot": 2, "revision": OLD}]
    with patch.object(c16, "fingerprint", return_value=fingerprint()), \
         patch.object(c16, "dispatch"), \
         patch.object(c16, "trace", side_effect=[{"events": [], "boots": 1}, {"events": observed}, {"boots": 2, "events": observed}]):
        assert c16.refusal(ctx, NAMES[0], OUTSIDE, budget) == passed
    if not budget:
        assert OUTSIDE in ctx.lua.call_args.args[1]
        assert OLD not in ctx.lua.call_args.args[1]


def test_budget_probe_rejects_non_exhausting_fake_quota():
    ctx = context()
    ctx.c16_fake_remaining = 3
    with patch.object(c16, "fingerprint", return_value=fingerprint()), patch.object(c16, "trace", return_value={}):
        with pytest.raises(Blocked, match="0, 1 or 2"):
            c16.refusal(ctx, NAMES[0], OLD, budget=True)


@pytest.mark.parametrize("criterion", [None, *c16.CRITERIA])
def test_complete_run_and_each_failure_with_mocked_ctx(criterion):
    ctx = context()
    sent = {"span_game_ms": 0, "workers": {str(i): {"rid": str(i)} for i in range(100, 110)}}
    with patch.object(c16, "rate_limit", return_value={"remaining": 60}) as quota, \
         patch.object(update_fixture, "baseline", return_value=OLD), \
         patch.object(update_fixture, "outside_revision", return_value=OUTSIDE), \
         patch.object(update_fixture, "prepare", return_value=NAMES), \
         patch.object(c16, "status", return_value=rows()), \
         patch.object(c16, "park_round", side_effect=[True, criterion != "paired_lease_recovery"]), \
         patch.object(c16, "refusal", side_effect=[criterion != "ancestry_refused_unchanged", criterion != "budget_refused_unchanged"]), \
         patch.object(c16, "fingerprint", return_value=fingerprint()), \
         patch.object(c16, "trace", return_value={}), \
         patch.object(c16, "dispatch", return_value=sent), \
         patch.object(c16, "updated", return_value=criterion != "simultaneous_updates"):
        assert c16.run(ctx).status == ("pass" if criterion is None else "fail")
    assert [call.args[1] for call in quota.call_args_list] == ["before", "dispatch", "after"]
    ctx.power.assert_called_once_with("server", "reboot")


def test_infrastructure_block_still_records_after_quota():
    ctx = context()
    with patch.object(c16, "rate_limit", return_value={"remaining": 60}) as quota, \
         patch.object(update_fixture, "baseline", side_effect=Blocked("no baseline")):
        with pytest.raises(Blocked, match="no baseline"):
            c16.run(ctx)
    assert [call.args[1] for call in quota.call_args_list] == ["before", "after"]


def test_second_quota_admission_blocks_batch():
    ctx = context()
    with patch.object(c16, "rate_limit", side_effect=[{"remaining": 40}, {"remaining": 39}, {"remaining": 39}]), \
         patch.object(update_fixture, "baseline", return_value=OLD), \
         patch.object(update_fixture, "outside_revision", return_value=OUTSIDE), \
         patch.object(update_fixture, "prepare", return_value=NAMES), \
         patch.object(c16, "status", return_value=rows()), patch.object(c16, "park_round", return_value=True), \
         patch.object(c16, "refusal", return_value=True), patch.object(c16, "dispatch") as dispatch:
        with pytest.raises(Blocked, match="fell below 40"):
            c16.run(ctx)
    dispatch.assert_not_called()


def test_baseline_is_real_older_feature_ancestor():
    with patch.object(update_fixture, "git", side_effect=[b"", (OLD + "\n").encode(), b"worker-update", b"pinnedUpdate = true", b""]) as git:
        assert update_fixture.baseline(TARGET) == OLD
    assert git.call_args_list[0].args == ("merge-base", "--is-ancestor", TARGET, "origin/server-only")
    assert git.call_args_list[-1].args == ("merge-base", "--is-ancestor", OLD, TARGET)
    with patch.object(update_fixture, "git", side_effect=[b"", b""]):
        with pytest.raises(Blocked, match="strictly older"):
            update_fixture.baseline(TARGET)


def test_selection_group_and_rate():
    for path in ("worker.lua", "install.lua", "so-server.lua"):
        assert "C16" in run.select_checks([path])
    from checks import GROUPS
    assert sum(group.count("C16") for group in GROUPS.values()) == 1
    with patch.object(run, "resolve", return_value=TARGET), patch("builtins.print") as output:
        assert run.main(["--checks", "C16", "--tick-rate", "80", "--plan"]) == 0
    assert json.loads(output.call_args.args[0])["tick_rates"] == {"C16": 20}


@pytest.mark.skipif(not shutil.which("lua5.2"), reason="Lua 5.2 unavailable")
def test_hook_passes_real_calls_and_logs_native_reboot_without_replacing_worker():
    hook = Path(c16.__file__).resolve().parents[1] / "c16-hook.lua"
    source = r'''
local files={};local saved;local actual=0;local rebooted=0;local ran=0
local env=setmetatable({}, {__index=_G});env._G=env
local function serialize(v)
 if type(v)=='table' then local p={} for k,x in pairs(v) do p[#p+1]='['..serialize(k)..']='..serialize(x) end
 return '{'..table.concat(p,',')..'}' end
 return type(v)=='string' and string.format('%q',v) or tostring(v)
end
local function decode(s) return assert(load('return '..s))() end
env.textutils={serializeJSON=serialize,unserializeJSON=decode}
env.fs={open=function(path,mode)
 if mode=='r' and not files[path] then return nil end
 return {readAll=function() return files[path] end,write=function(v) files[path]=v end,close=function() end}
end}
env.os={epoch=function() return 42 end,reboot=function() rebooted=rebooted+1 end}
env.term={getSize=function() return 51,2 end,current=function() return {getLine=function() return 'Update API refused' end} end}
env.rednet={send=function() return true end}
env.dofile=function() return {decode=function(wire) return wire end} end
env.http={get=function(url) actual=actual+1;return 'real' end}
env.loadfile=function(path,mode,e)
 assert(e==env);return function(...) ran=ran+1;assert((...)=='worker-update');return true end
end
assert(loadfile(HOOK,'t',env))()
assert(env.http.get({url='https://api.github.com/real'})=='real' and actual==1)
files['/.gateb/c16-fake-remaining']='2'
local r=env.http.get({url='https://api.github.com/fake'})
assert(r.getResponseCode()==403 and r.getResponseHeaders()['x-ratelimit-remaining']=='2' and actual==1)
assert(env.http.get('https://raw.githubusercontent.com/payload')=='real' and actual==2)
env.rednet.send(1,{t='ack',rid='rid',body={command='worker.update',revision='target',state='accepted'}},'so')
assert(env.loadfile('/install.lua')('worker-update','target','old') and ran==1)
env.os.reboot();assert(rebooted==1)
assert(files['/startup.lua']:find('gateb%-bridge'))
local trace=decode(files['/.gateb/c16-trace.json'])
assert(trace.boots==1 and trace.events[1].kind=='api' and trace.events[2].kind=='fake_budget')
assert(trace.events[3].kind=='ack' and trace.events[4].kind=='handoff' and trace.events[5].kind=='reboot')
assert(trace.events[5].terminal.lines[1].text=='Update API refused')
assert(loadfile(HOOK,'t',env))()
assert(decode(files['/.gateb/c16-trace.json']).boots==2)
'''.replace("HOOK", json.dumps(str(hook)))
    result = subprocess.run(["lua5.2", "-"], input=source, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr


def test_provisions_ten_actual_worker_disks_and_native_blocks(tmp_path):
    import world
    from checks.lua_data import parse
    ctx = context()
    ctx.run = 'driver-c16-unit'
    ctx.runtime = world.Runtime(home=tmp_path)
    ctx.manifest = {'version': 1, 'computers': {
        '1': {'name': 'server', 'role': 'server', 'kind': 'computer', 'pos': [0, 64, 0]},
        '4': {'name': 'miner1', 'role': 'worker', 'kind': 'turtle', 'pos': [-5, 64, 3]}}}
    ctx.runtime.computer_disk = Mock(return_value=tmp_path / 'server-disk')
    (tmp_path / 'server-disk/.gateb').mkdir(parents=True)
    ctx.command.side_effect = lambda text: {'output': 'has the following block data: ' + str(100 + int(text.split()[3]) // 2 - 6)}
    ctx.lua.return_value = True
    installer = b'local ROLES={common={"install.lua","so-proto.lua"},worker={program="worker.lua","worker.lua"}}'
    def source(*args):
        if args[0] == 'ls-tree':
            return b'\0'.join(b'100644 blob ' + b'd' * 40 + b'\t' + name for name in (b'install.lua', b'so-proto.lua', b'worker.lua'))
        assert args[0] == 'show' and args[1].startswith(OLD + ':')
        return installer if args[1].endswith(':install.lua') else b'real ancestor bytes'
    with patch.object(update_fixture, 'git', side_effect=source):
        assert update_fixture.prepare(ctx, OLD) == NAMES
    assert not (tmp_path / 'server-disk/.gateb/c16-pair-seed').exists()
    assert len([call for call in ctx.command.call_args_list if 'computercraft:turtle_advanced' in call.args[0]]) == 10
    for ident in range(100, 110):
        disk = tmp_path / f'runs/driver-c16-unit/world/computercraft/computer/{ident}'
        assert (disk / '.so-revision').read_text() == OLD
        assert (disk / 'worker.lua').read_bytes() == b'real ancestor bytes'
        assert parse((disk / 'so-worker.cfg').read_text())['remoteUpdates'] is True
        assert len(parse((disk / 'so-keys').read_text())['value']['keys']['1']) == 64
        assert (disk / '.gateb/c16-hook.lua').is_file()
    assert len(ctx.power.call_args_list) == 11
    assert all('key' not in str(call.args) for call in ctx.record.call_args_list)


def test_load_wait_precedes_c16_preparation(tmp_path):
    from checks.context import Context
    from checks.model import Verdict
    ctx = Context(None, 'driver-unit', {}, tmp_path, TARGET)
    order = []
    def load_admission(**kwargs):
        order.append('load')
        kwargs['on_wait'](15)
    def cli(*args, **kwargs):
        order.append(args[0])
        return {'sha': TARGET, 'errors': []} if args[0] == 'install' else {}
    def check(ctx):
        order.append('C16')
        return Verdict('pass')
    with patch.object(run, 'admit', side_effect=load_admission), patch.object(ctx, 'cli', side_effect=cli), \
         patch.object(ctx, 'request', return_value={}), patch.object(ctx, 'wait', return_value=True), \
         patch.object(ctx, 'command'), patch.object(run, 'load', return_value=SimpleNamespace(run=check)):
        result = run.execute(ctx, 'C16', tmp_path)
    assert order == ['load', 'reset', 'serve', 'install', 'C16']
    assert result.metrics['load_wait_seconds'] == 15


def test_low_admission_records_before_after_without_fixture_work():
    ctx = context()
    with patch.object(c16, 'rate_limit', return_value={'remaining': 39}) as quota, \
         patch.object(update_fixture, 'prepare') as prepare:
        with pytest.raises(Blocked, match='at least 40'):
            c16.run(ctx)
    prepare.assert_not_called()
    assert [call.args[1] for call in quota.call_args_list] == ['before', 'after']


def ancestry_events(*, skipped=False, early=False):
    if early:
        return [{"kind": "err", "text": "invalid revision"}]
    terminal = {"lines": [{"text": "Installed worker" if skipped else "Pinned revision ancestry refused"}]}
    observed = [{"kind": "ack", "revision": OUTSIDE, "state": "accepted"},
                {"kind": "handoff", "revision": OUTSIDE, "running": OLD}]
    if not skipped:
        observed.append({"kind": "api", "url": f"https://api.github.com/repos/140er/computercraft-scripts/compare/{OUTSIDE}...{TARGET}"})
    return observed + [{"kind": "reboot", "terminal": terminal},
                       {"kind": "hello", "boot": 2, "revision": OLD}]


@pytest.mark.parametrize("broken", [None, "skipped_installer_ancestry", "early_worker_refusal"])
def test_installer_that_skips_ancestry_validation_fails_c16(broken):
    ctx = context()
    observed = ancestry_events(skipped=broken == "skipped_installer_ancestry", early=broken == "early_worker_refusal")
    with patch.object(c16, "fingerprint", return_value=fingerprint()), \
         patch.object(c16, "trace", side_effect=[{"events": [], "boots": 1},
                      {"events": observed}, {"boots": 2, "events": observed}]):
        ancestry = c16.refusal(ctx, NAMES[0], OUTSIDE)
    data = {"worker_count": 10, "tick_rate": 20, **dict.fromkeys(c16.CRITERIA, True)}
    data["ancestry_refused_unchanged"] = ancestry
    assert c16.evaluate(data).status == ("pass" if broken is None else "fail")
    assert OUTSIDE in ctx.lua.call_args.args[1]


@pytest.mark.parametrize("budget", [False, True])
@pytest.mark.parametrize("field,value", [("settingsSeq", 8), ("autoToolSwap", True), ("remoteUpdates", False)])
def test_refusal_rejects_changed_recovered_config(budget, field, value):
    ctx = context()
    before = fingerprint()
    after = copy.deepcopy(before)
    after["config"][field] = value
    observed = ancestry_events()
    if budget:
        observed = [{"kind": "fake_budget", "remaining": 0},
                    {"kind": "reboot", "terminal": {"lines": [{"text": "Update API refused"}]}},
                    {"kind": "hello", "boot": 2, "revision": OLD}]
    with patch.object(c16, "fingerprint", side_effect=[before, after]), patch.object(c16, "dispatch"), \
         patch.object(c16, "trace", side_effect=[{"events": [], "boots": 1},
                      {"events": observed}, {"boots": 2, "events": observed}]):
        assert not c16.refusal(ctx, NAMES[0], OUTSIDE, budget)


def test_only_budget_probe_can_change_only_saved_cooldown():
    before = fingerprint()
    after = copy.deepcopy(before)
    after["config"]["updateApiRetryAt"] = 1234567890
    assert c16.unchanged(before, after, budget=True)
    assert not c16.unchanged(before, after)
    assert "updateApiRetryAt" in after["config"]
    after["config"]["autoToolSwap"] = True
    assert not c16.unchanged(before, after, budget=True)


def test_fingerprint_reads_recovered_config():
    ctx = context()
    expected = fingerprint()
    ctx.request.return_value = {"content": OLD}
    ctx.integrity.return_value = {"files": expected["files"], "pairing": expected["pairing"]}
    ctx.read_store.return_value = expected["journal"]
    ctx.lua.return_value = expected["config"]
    assert c16.fingerprint(ctx, NAMES[0]) == expected
    assert "readConfig('so-worker.cfg')" in ctx.lua.call_args.args[1]


@pytest.mark.parametrize("bad_manifest", [None, "missing", "extra", "changed_bytes"])
def test_complete_target_manifest_required_even_when_worker_omits_missing_file(bad_manifest):
    ctx = context()
    after = fingerprint(TARGET)
    after["files"]["update.lua"] = hashlib.sha256(b"updater").hexdigest()
    if bad_manifest == "missing":
        # The defective updater deletes update.lua and omits it from .so-files.
        del after["files"]["update.lua"]
    elif bad_manifest == "extra":
        after["files"]["unexpected.lua"] = hashlib.sha256(b"extra").hexdigest()
    elif bad_manifest == "changed_bytes":
        after["files"]["update.lua"] = hashlib.sha256(b"wrong updater").hexdigest()
    with patch.object(c16, "fingerprint", return_value=after), \
         patch.object(c16, "trace", return_value={"events": events()}), \
         patch.object(update_fixture, "worker_files", return_value={"worker.lua": b"source", "update.lua": b"updater"}) as manifest:
        assert c16.updated(ctx, NAMES[0], OLD, {"fingerprint": fingerprint(), "events": 0}) == (bad_manifest is None)
    manifest.assert_called_once_with(TARGET)


@pytest.mark.parametrize("missing_tree_file", [False, True])
def test_expected_worker_manifest_comes_from_target_installer_and_tree(missing_tree_file):
    installer = b'local ROLES={common={"install.lua","update.lua"},worker={program="worker.lua","worker.lua"}}'
    selected = {"install.lua": installer, "update.lua": b"updater", "worker.lua": b"worker"}
    def git(*args):
        if args[0] == "ls-tree":
            assert args == ("ls-tree", "-r", "-z", TARGET)
            paths = ["install.lua", "worker.lua"] if missing_tree_file else list(selected)
            return b"\0".join(b"100644 blob " + b"d" * 40 + b"\t" + p.encode() for p in [*paths, "display.lua"])
        assert args[0] == "show" and args[1].startswith(TARGET + ":")
        return selected[args[1].split(":", 1)[1]]
    with patch.object(update_fixture, "git", side_effect=git):
        if missing_tree_file:
            with pytest.raises(Blocked, match="target tree lacks"):
                update_fixture.worker_files(TARGET)
        else:
            assert update_fixture.worker_files(TARGET) == selected


@pytest.mark.skipif(not shutil.which("git"), reason="Git unavailable")
def test_probe_selects_real_remote_commit_verified_outside_server_only(tmp_path):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(tmp_path), "-c", "user.name=C16 test",
                                       "-c", "user.email=c16@example.invalid", "-c", "commit.gpgsign=false", *args], stderr=subprocess.DEVNULL).decode().strip()
    git("init", "--initial-branch=fixture")
    git("commit", "--allow-empty", "-m", "shared base")
    common = git("rev-parse", "HEAD")
    git("commit", "--allow-empty", "-m", "server-only commit")
    tip = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/server-only", tip)
    git("checkout", "--detach", common)
    git("commit", "--allow-empty", "-m", "outside commit")
    outside = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/fixture-outside", outside)
    ctx = context()
    with patch.object(update_fixture, "ROOT", tmp_path):
        assert update_fixture.outside_revision(ctx) == outside
        proof = ctx.record.call_args.args[1]
        assert proof["exit_code"] == 1 and proof["server_only_tip"] == tip
        assert proof["ref"] == "refs/remotes/origin/fixture-outside"
        git("update-ref", "-d", "refs/remotes/origin/fixture-outside")
        with pytest.raises(Blocked, match="outside server-only ancestry"):
            update_fixture.outside_revision(ctx)
