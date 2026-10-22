"""Generate a closed Lua test input set from source literals and loader edges."""
import json
import re
import shutil
import tempfile
from pathlib import Path

# Keep long-string bodies: harness tests embed executable ComputerCraft programs.
TOKEN = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|([\"\'])(?:\\.|(?!\2).)*?\2', re.S)


def literals(code):
    values = []
    for token in TOKEN.finditer(code):
        text = token.group()
        if text.startswith('--'):
            continue
        value = text[1:-1]
        value = re.sub(r'\\([\\\"\'])', r'\1', value)
        values.append(value)
    return values


def graph(root):
    files = {p.relative_to(root).as_posix() for directory in ('tests', 'lib')
             for p in (root / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    files.update(p.name for p in root.glob('*.lua'))
    edges = {}
    for name in files:
        if not name.endswith('.lua'):
            edges[name] = set()
            continue
        code = (root / name).read_text()
        values = literals(code)
        deps = {v.removeprefix('./') for v in values if v.removeprefix('./') in files}
        # require strings and computed crypto paths share the same finite source
        # vocabulary (e.g. "lib/ccryptolib/" .. name .. ".lua").
        for value in values:
            module = 'lib/' + value.replace('.', '/') + '.lua'
            if module in files:
                deps.add(module)
        for prefix in values:
            if prefix.endswith('/') and not prefix.startswith('/'):
                for value in values:
                    path = prefix + value + '.lua'
                    if path in files:
                        deps.add(path)
        edges[name] = deps - {name}
    return files, edges


def closure(edges, starts):
    found, pending = set(), list(starts)
    while pending:
        name = pending.pop()
        if name not in found:
            found.add(name)
            pending.extend(edges.get(name, ()))
    return found


def select(root, part, files, edges):
    candidates = sorted(p for p in files if re.fullmatch(r'tests/(so|ui|parts)/[^/]+\.lua', p)
                        and p not in {'tests/so/harness.lua', 'tests/ui/render.lua'}
                        and not p.endswith('-fixture.lua'))
    explicit = part.removeprefix('./')
    if explicit in candidates:
        return [explicit]
    exact = [p for p in candidates if Path(p).stem == part.removesuffix('.lua')]
    if exact and not (root / part).is_file():
        return exact
    module = part.removesuffix('.lua')
    module = {'server': 'so-server', 'miner': 'so-mod-mine'}.get(module, module)
    if module + '.lua' not in files:
        raise ValueError('unknown part: ' + part + '; use a root module or tests/so/<suite>.lua')
    dedicated = 'tests/parts/' + module + '.lua'
    if dedicated in candidates:
        return [dedicated]
    key = re.sub(r'^so-(?:mod-)?', '', module)
    module_deps = closure(edges, [module + '.lua'])
    narrow = [p for p in candidates
              if module + '.lua' in closure(edges, [p])
              and {d for d in closure(edges, [p]) if '/' not in d}.issubset(module_deps)]
    if narrow:
        return narrow
    focused = [p for p in candidates if re.search(r'(^|-)' + re.escape(key) + r'(-|$)', Path(p).stem)
               and module_deps.intersection(closure(edges, [p]))]
    if focused:
        return focused
    related = [p for p in candidates if module + '.lua' in closure(edges, [p])
               and not re.fullmatch(r'(so\d+|w40|ui\w+)', Path(p).stem)]
    if not related:
        raise ValueError('no regression suite for ' + module + '; add a focused suite')
    return related


def lua_string(value):
    return json.dumps(value, ensure_ascii=True)


def prepare(root, part, timeout=60):
    files, edges = graph(root)
    suites = select(root, part, files, edges)
    allowed = closure(edges, [*suites, 'tests/mocks.lua'])
    temporary = tempfile.TemporaryDirectory(prefix='cc-part-')
    stage = Path(temporary.name)
    for name in sorted(allowed):
        dest = stage / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, dest)
    shutil.copyfile(root / 'tests/part.lua', stage / 'tests/run.lua')
    manifest = 'return { timeout = ' + str(timeout) + ', suites = {' + ','.join(map(lua_string, suites)) + '}, allowed = {'
    manifest += ','.join('[' + lua_string(p) + ']=true' for p in sorted(allowed)) + '} }\n'
    (stage / 'tests/part-manifest.lua').write_text(manifest)
    print('part: ' + part + '; suites: ' + ', '.join(suites), flush=True)
    print('part: generated ' + str(len(allowed)) + ' input files; private cwd ' + str(stage), flush=True)
    return temporary, stage, suites, sorted(allowed)

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group(required=True)
    options.add_argument('--list', action='store_true')
    options.add_argument('--dependencies', metavar='PART')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    files, edges = graph(root)
    if args.dependencies:
        suites = select(root, args.dependencies, files, edges)
        print(json.dumps({'suites': suites, 'inputs': sorted(closure(edges, [*suites, 'tests/mocks.lua']))}, indent=2))
    else:
        for name in sorted(p for p in files if '/' not in p and p.endswith('.lua')
                           and (p.startswith('so-') or p in {'worker.lua', 'display.lua'})):
            try:
                suites = select(root, name, files, edges)
                print(name + ': ' + ', '.join(suites))
            except ValueError:
                print(name + ': no regression suite')
