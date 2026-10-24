#!/usr/bin/env python3
"""Require UI0's generator comparison to execute on the Linux CI runner."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
probe = '''
local selected = 0
dofile("tests/ui/ui0.lua")(function(name, fn)
  if name == "UI0 generator preserves section 7.1 and reproduces every fixture" then
    selected = selected + 1
    local result = fn()
    assert(result ~= "skip", "UI0 generator check skipped in CI")
  end
end, function(actual, expected) assert(actual == expected, "UI0 generator output differs") end)
assert(selected == 1, "UI0 generator check missing")
print("PASS required Linux UI0 generator comparison")
'''
sys.exit(subprocess.call(['lua5.2', '-e', probe], cwd=root))
