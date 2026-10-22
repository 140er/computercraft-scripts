#!/usr/bin/env python3
"""Reject UTC reads outside the reviewed date and compatibility boundaries."""
import re
from pathlib import Path

UTC = re.compile(r'''os\s*\.\s*epoch\s*\(\s*["']utc["']\s*\)''')



def check(root):
    errors = []
    allowed = {}
    for line in (root / "tests/so/clock-utc.tsv").read_text().splitlines():
        name, expression = line.split("\t", 1)
        allowed.setdefault(name, []).append(expression)
    for path in sorted([*root.glob('so-*.lua'), root / 'worker.lua', root / 'display.lua']):
        expected = list(allowed.get(path.name, []))
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if UTC.search(line):
                if line.strip() in expected:
                    expected.remove(line.strip())
                else:
                    errors.append(f'{path.name}:{number}: unreviewed UTC read')
        errors.extend(f'{path.name}: stale UTC allowance: {line}' for line in expected)
    return errors


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[1])
    print('\n'.join(errors) if errors else 'PASS clock UTC allow-list')
    raise SystemExit(bool(errors))
