"""Stage the full suite and dispatch independent shards through the slot scheduler."""
from pathlib import Path
import concurrent.futures
import json
import re
import shutil
import subprocess
import tempfile
import time


def timings(text):
    totals = {}
    for seconds, path, name in re.findall(r'^CHECK-TIME ([0-9.]+) (\S+) \| (.+)$', text, re.M):
        if path == 'tests/so/so11.lua' and name.startswith('SO11 B'):
            path += ':B'
        totals[path] = totals.get(path, 0) + float(seconds)
    return totals


def save_costs(costs, path):
    Path(path).write_text('-- Lua CPU seconds from CI shard logs.\nreturn {\n' + ''.join(
        '  [%s] = %.6f,\n' % (json.dumps(name), seconds) for name, seconds in sorted(costs.items())) + '}\n')


def prepare_full(root):
    temporary = tempfile.TemporaryDirectory(prefix='cc-full-')
    staged = Path(temporary.name)
    names = subprocess.check_output(
        ['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=root).split(b'\0')
    for name in set(names) - {b''}:
        relative = Path(name.decode())
        source = root / relative
        if source.is_file():
            target = staged / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    gitdir = subprocess.check_output(['git', 'rev-parse', '--absolute-git-dir'], cwd=root).decode().strip()
    (staged / '.git').write_text('gitdir: ' + gitdir + '\n')
    shutil.copy2(root / 'tests/run.lua', staged / 'tests/full.lua')
    shutil.copy2(root / 'tests/suite.lua', staged / 'tests/run.lua')
    return temporary, staged


def dispatch(root, shards, scheduler=None, slot=None, args=(), output=None):
    began = time.monotonic()
    output = Path(output or tempfile.mkdtemp(prefix='cc-shards-'))
    output.mkdir(parents=True, exist_ok=True)
    (output / 'suite-costs.lua').unlink(missing_ok=True)
    print('Full gate: starting %d shards; logs %s' % (shards, output), flush=True)
    def run(index):
        selector = '--shard=%d/%d' % (index, shards)
        if scheduler:
            command = [scheduler] + (['--slot', slot] if slot else []) + ['--', selector, *args]
            temporary, cwd = None, root
        else:
            temporary, cwd = prepare_full(root)
            command = ['timeout', '20m', 'lua5.2', 'tests/run.lua', selector, *args]
        try:
            with (output / ('shard-%d.log' % index)).open('w') as log:
                result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
            text = (output / ('shard-%d.log' % index)).read_text(errors='replace')
            print(text, end='', flush=True)
            summaries = re.findall(r'^(\d+) tests passed, (\d+) FAILED, (\d+) skipped checks, shard (\d+)/(\d+)$', text, re.M)
            valid = len(summaries) == 1 and summaries[0][3:] == (str(index), str(shards))
            counts = [int(n) for n in summaries[0][:3]] if valid else [0, 1, 0]
            skips = re.findall(r'^SKIPPED (.+)$', text, re.M)
            valid = valid and counts[1] == 0 and len(skips) == counts[2]
            return {'code': result.returncode or (0 if valid else 1), 'counts': counts, 'skips': skips,
                    'timings': timings(text)}
        finally:
            if temporary:
                temporary.cleanup()
    with concurrent.futures.ThreadPoolExecutor(max_workers=shards) as pool:
        results = list(pool.map(run, range(1, shards + 1)))
    codes = [result['code'] for result in results]
    counts = [sum(result['counts'][i] for result in results) for i in range(3)]
    elapsed = time.monotonic() - began
    costs = {}
    for shard in results:
        for name, seconds in shard['timings'].items():
            costs[name] = costs.get(name, 0) + seconds
    if not any(codes):
        save_costs(costs, output / 'suite-costs.lua')
    result = {'shards': shards, 'exit_codes': codes, 'wall_seconds': elapsed, 'passed': counts[0],
              'failed': counts[1], 'skipped': counts[2],
              'skipped_checks': [name for result in results for name in result['skips']],
              'part_cpu_seconds': costs}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    for name in result['skipped_checks']:
        print('SKIPPED ' + name)
    for name in sorted(costs, key=costs.get, reverse=True)[:10]:
        print('SLOW-PART %.3f %s' % (costs[name], name))
    print('Full gate: %d tests passed, %d FAILED, %d skipped checks; %d shards, %.3fs wall, %s; logs %s' % (
        *counts, shards, elapsed, 'PASS' if not any(codes) else 'FAIL', output), flush=True)
    return 1 if any(codes) else 0
