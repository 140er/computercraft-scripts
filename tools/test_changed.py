"""Select focused iteration parts, falling back to the full gate for shared inputs."""
import subprocess
import time

from test_parts import graph, select


def changed_paths(root, base):
    ancestor = subprocess.check_output(['git', 'merge-base', base, 'HEAD'], cwd=root).decode().strip()
    tracked = subprocess.check_output(
        ['git', 'diff', '--name-only', '--no-renames', '-z', ancestor], cwd=root)
    untracked = subprocess.check_output(
        ['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=root)
    return sorted(set(p.decode() for p in (tracked + untracked).split(b'\0') if p))


def plan(root, paths):
    files, edges = graph(root)
    parts = set()
    for path in paths:
        if path.startswith('docs/ui/'):
            return None
        elif path.endswith('.md') or path.startswith('tests/evidence/'):
            continue
        elif path.startswith(('tests/so/', 'tests/ui/', 'tests/parts/')) and path.endswith('.lua'):
            try:
                suites = select(root, path, files, edges)
            except ValueError:
                return None
            if suites != [path]:
                return None
            parts.add(path)
        elif '/' not in path and path.endswith('.lua'):
            if path not in files:
                return None
            try:
                select(root, path, files, edges)
            except ValueError:
                return None
            parts.add(path)
        else:
            return None
    return sorted(parts)


def run(root, scheduler, base, *, lua_only=False, timeout=60, slot=None, shards=1, args=()):
    paths = changed_paths(root, base)
    parts = plan(root, paths)
    print('changed: ' + (', '.join(paths) or 'no changed files'), flush=True)
    common = (['--slot', slot] if slot else [])
    if parts is None:
        print('changed: shared or unmapped input; running full gate', flush=True)
        return subprocess.call([scheduler, '--shards', str(shards), *common, '--', *args], cwd=root)
    if args:
        raise ValueError('suite arguments require the full gate; omit --changed')
    failed = False
    for part in parts:
        began = time.monotonic()
        code = subprocess.call([scheduler, '--part', part, '--part-timeout', str(timeout),
                                *(['--lua-only'] if lua_only else []), *common], cwd=root)
        print('PART-TIME %.3f %s exit=%d' % (time.monotonic() - began, part, code), flush=True)
        failed |= code != 0
    if not parts:
        print('changed: no affected Lua parts', flush=True)
    return int(failed)
