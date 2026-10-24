#!/usr/bin/env python3
"""Exercise shard coverage, failures, skip accounting and the lint gate."""
from pathlib import Path
import subprocess
import tempfile
import shutil
import contextlib
import io
import json
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_suite import dispatch, timings

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    staged = Path(directory)
    (staged / 'tests').mkdir()
    for name in ('suite.lua', 'suite-costs.lua', 'skips.lua'):
        shutil.copy2(root / 'tests' / name, staged / 'tests' / name)
    fixture = '''local function test(name, fn) fn() end
local function equal(actual, expected, message) assert(actual == expected, message) end
test("works", function() equal(1, 1) end)
test("skips", function() return dofile("tests/skips.lua").record("skips", "fixture") end)
'''
    (staged / 'tests/full.lua').write_text(fixture)
    outputs = []
    for shard in range(1, 5):
        result = subprocess.run(['lua5.2', 'tests/suite.lua', '--shard=%d/4' % shard],
                                cwd=staged, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        outputs.append(result.stdout)
    assert sum(text.count('PASS works\n') for text in outputs) == 1
    assert sum(text.count('SKIPPED skips: fixture\n') for text in outputs) == 1
    assert any('1 tests passed, 0 FAILED, 1 skipped checks' in text for text in outputs)
    (staged / 'tests/full.lua').write_text(fixture + '\ntest("broken", function() error("scratch") end)\n')
    result = subprocess.run(['lua5.2', 'tests/suite.lua'], cwd=staged, capture_output=True, text=True)
    assert result.returncode == 1 and 'FAIL broken' in result.stdout, result.stdout
    assert '1 tests passed, 1 FAILED, 1 skipped checks' in result.stdout
    (staged / 'tests/run.lua').write_text(fixture)
    subprocess.run(['git', 'init', '-q'], cwd=staged, check=True)
    with tempfile.TemporaryDirectory() as logs, contextlib.redirect_stdout(io.StringIO()):
        assert dispatch(staged, 4, output=logs) == 0
        combined = json.loads((Path(logs) / 'result.json').read_text())
        assert (combined['passed'], combined['failed'], combined['skipped']) == (1, 0, 1), combined
        assert combined['skipped_checks'] == ['skips: fixture'], combined
        assert 'tests/run.lua' in combined['part_cpu_seconds']
        assert (Path(logs) / 'suite-costs.lua').is_file()
    (staged / 'tests/run.lua').write_text(fixture + '\ntest("broken", function() error("scratch") end)\n')
    with tempfile.TemporaryDirectory() as logs, contextlib.redirect_stdout(io.StringIO()):
        assert dispatch(staged, 2, output=logs) == 1
        assert not (Path(logs) / 'suite-costs.lua').exists()
    (staged / 'tests/so').mkdir()
    shutil.copy2(root / 'tests/so/clock-so11.lua', staged / 'tests/so/clock-so11.lua')
    (staged / 'tests/so/so11.lua').write_text('''return function(test)
  test("SO11 integration", function() end)
  test("SO11 B integration", function() end)
end
''')
    (staged / 'tests/full.lua').write_text(fixture + '''
dofile("tests/so/so11.lua")(test, equal)
dofile("tests/so/clock-so11.lua")(test, equal)
''')
    outputs = []
    for shard in range(1, 5):
        result = subprocess.run(['lua5.2', 'tests/suite.lua', '--shard=%d/4' % shard],
                                cwd=staged, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        outputs.append(result.stdout)
    for name in ('SO11 integration', 'SO11 B integration'):
        for suffix in ('', ' at 4x'):
            assert sum(text.count('PASS ' + name + suffix + '\n') for text in outputs) == 1
    (staged / 'scratch.lua').write_text('accidental = absent\nlocal unused = 1\n')
    result = subprocess.run(['lua5.2', 'tools/luacheck.lua', str(staged / 'scratch.lua')],
                            cwd=root, capture_output=True, text=True)
    assert result.returncode == 1, result.stdout + result.stderr
    assert 'W111' in result.stdout and 'accidental' in result.stdout and 'W113' in result.stdout and 'absent' in result.stdout, result.stdout
    assert 'W211' in result.stdout and 'unused' in result.stdout, result.stdout
with tempfile.TemporaryDirectory() as directory:
    scratch = Path(directory) / 'warning.lua'
    scratch.write_text('local unused = 1\n')
    result = subprocess.run(['lua5.2', 'tools/luacheck.lua', str(scratch)], cwd=root,
                            capture_output=True, text=True)
    assert result.returncode == 1 and '0 errors, 1 warnings' in result.stdout, result.stdout
assert timings('CHECK-TIME 1.25 tests/so/so11.lua | SO11 A example\n'
               'CHECK-TIME 2.5 tests/so/so11.lua | SO11 B example\n') == {
                   'tests/so/so11.lua': 1.25, 'tests/so/so11.lua:B': 2.5}
probe = r"""
io.popen = function()
  return { read = function() return [[C:\fixture]] end, close = function() end }
end
local selected = 0
dofile("tests/ui/ui0.lua")(function(name, fn)
  if name == "UI0 generator preserves section 7.1 and reproduces every fixture" then
    selected = selected + 1
    local ok, status, reason = pcall(fn)
    assert(ok and status == "skip" and reason:match("POSIX"))
  end
end)
assert(selected == 1)
dofile("tests/skips.lua").summary(1, 0)
"""
result = subprocess.run(['lua5.2', '-'], input=probe, cwd=root, capture_output=True, text=True)
assert result.returncode == 0, result.stdout + result.stderr
assert '0 tests passed, 0 FAILED, 1 skipped checks' in result.stdout, result.stdout
assert 'SKIPPED UI0 generator preserves section 7.1 and reproduces every fixture' in result.stdout
print('PASS shard coverage including SO11 A/B at both rates, skip counts including non-POSIX UI0, failure propagation and global/unused lint checks')
