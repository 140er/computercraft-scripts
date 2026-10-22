#!/usr/bin/env python3
"""Exercise staging and loader enforcement using disposable Lua fixtures."""
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from test_parts import prepare

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='parts-selftest-') as directory:
    root = Path(directory)
    (root / 'tests/so').mkdir(parents=True)
    (root / 'lib/example').mkdir(parents=True)
    (root / 'tests/part.lua').write_text((repo / 'tests/part.lua').read_text())
    (root / 'tests/mocks.lua').write_text('return {encode=tostring}')
    (root / 'example.lua').write_text('return require("child") + require("example.child")')
    (root / 'child.lua').write_text('return 3')
    (root / 'lib/example/child.lua').write_text('return 7')
    (root / 'unrelated.lua').write_text('error("must never load")')
    suite = root / 'tests/so/example.lua'
    suite.write_text('local path="example.lua"\nreturn function(test) test("load",function() '
                     'assert(dofile(path)==10) end) end')

    def run():
        temporary, stage, _, allowed = prepare(root, 'example.lua')
        try:
            assert 'lib/example/child.lua' in allowed and 'child.lua' in allowed
            assert not (stage / 'unrelated.lua').exists()
            result = subprocess.run(['lua5.2', '-e', 'package.path="lib/?.lua;"..package.path; '
                                     'dofile("tests/run.lua")'], cwd=stage, capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
            return str(stage)
        finally:
            temporary.cleanup()

    with ThreadPoolExecutor(max_workers=2) as pool:
        dirs = list(pool.map(lambda _: run(), range(2)))
    assert dirs[0] != dirs[1]
    # A computed undeclared read is caught even when the test swallows its error.
    suite.write_text('return function(test) test("escape",function() '
                     'pcall(dofile, "unrelated" .. ".lua") end) end')
    temporary, stage, _, _ = prepare(root, 'tests/so/example.lua')
    try:
        result = subprocess.run(['lua5.2', 'tests/run.lua'], cwd=stage, capture_output=True, text=True)
        assert result.returncode == 1 and '1 undeclared reads' in result.stdout, result.stdout + result.stderr
    finally:
        temporary.cleanup()
    for call in ['require("unlisted")', 'io.lines("unrelated" .. ".lua")', 'io.input("unrelated" .. ".lua")']:
        suite.write_text('return function(test) test("escape",function() pcall(function() ' + call + ' end) end) end')
        temporary, stage, _, _ = prepare(root, 'tests/so/example.lua')
        try:
            result = subprocess.run(['lua5.2', 'tests/run.lua'], cwd=stage, capture_output=True, text=True)
            assert result.returncode == 1 and '1 undeclared reads' in result.stdout, result.stdout + result.stderr
        finally:
            temporary.cleanup()
    suite.write_text('local path="example.lua";return function(test) test("static only",function() local f=assert(io.open(path));f:close() end) end')
    temporary, stage, _, _ = prepare(root, 'example.lua')
    try:
        result = subprocess.run(['lua5.2','tests/run.lua'],cwd=stage,capture_output=True,text=True)
        assert result.returncode != 0 and 'PART COVERAGE VIOLATION' in result.stderr, result.stdout + result.stderr
    finally:
        temporary.cleanup()
print('PASS graph closure, excluded source, concurrent private directories, swallowed load/require/lines/input violations')
