#!/usr/bin/env python3
"""Check changed-file selection and scheduler forwarding without reserving slots."""
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

from test_changed import changed_paths, plan, run

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'tests/parts').mkdir(parents=True)
    (root / 'tests/so').mkdir()
    (root / 'so-example.lua').write_text('return 1')
    (root / 'tests/parts/so-example.lua').write_text('return dofile("so-example.lua")')
    (root / 'tests/so/helper-fixture.lua').write_text('return {}')
    assert plan(root, ['so-example.lua']) == ['so-example.lua']
    assert plan(root, ['tests/parts/so-example.lua']) == ['tests/parts/so-example.lua']
    assert plan(root, ['docs/ui/BIG-TILES-SPEC.md']) is None
    assert plan(root, ['README.md']) == []
    for name in ('so-deleted.lua', 'tests/mocks.lua', 'tools/new.py', '.github/workflows/check.yml',
                 'tests/so/helper-fixture.lua', 'lib/shared.lua', 'unknown.lua'):
        assert plan(root, [name]) is None, name
    assert plan(root, []) == []
    subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
    subprocess.run(['git', 'add', '.'], cwd=root, check=True)
    subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
                    'commit', '-qm', 'fixture'], cwd=root, check=True)
    (root / 'so-example.lua').write_text('return 2')
    (root / 'untracked.lua').write_text('return 3')
    assert changed_paths(root, 'HEAD') == ['so-example.lua', 'untracked.lua']
    (root / 'untracked.lua').unlink()
    with patch('test_changed.subprocess.call', return_value=1) as call, contextlib.redirect_stdout(io.StringIO()):
        assert run(root, 'cc-test', 'HEAD', lua_only=True, timeout=12, slot='win') == 1
        assert call.call_args.args[0] == ['cc-test', '--part', 'so-example.lua', '--part-timeout', '12', '--lua-only', '--slot', 'win']
    with patch('test_changed.changed_paths', return_value=['tools/tool.py']), patch('test_changed.subprocess.call', return_value=2) as call, contextlib.redirect_stdout(io.StringIO()):
        assert run(root, 'cc-test', 'HEAD', shards=4, args=['--fixture']) == 2
        assert call.call_args.args[0] == ['cc-test', '--shards', '4', '--', '--fixture']
    (root / 'so-example.lua').unlink()
    assert 'so-example.lua' in changed_paths(root, 'HEAD')
    assert plan(root, changed_paths(root, 'HEAD')) is None
print('PASS changed paths, dirty/untracked/deleted files, conservative fallback and scheduler status/argument forwarding')
